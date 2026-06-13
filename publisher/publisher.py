import argparse
import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode

import psycopg
import pystac
import requests
import yaml
from psycopg import sql
from psycopg.types.json import Jsonb


WEB_MAP_LINKS_SCHEMA = "https://stac-extensions.github.io/web-map-links/v1.3.0/schema.json"
DATA_ROOT = Path(os.getenv("DATA_ROOT", "/data"))
ASSET_ROOT = DATA_ROOT / "assets"
RECEIPT_ROOT = DATA_ROOT / "publishing" / "receipts"
TOMBSTONE_ROOT = DATA_ROOT / "publishing" / "tombstones"


def required_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"Required environment variable is not set: {name}")
    return value.rstrip("/") if name.endswith("URL") else value


def slug(value: str, maximum: int = 48) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")
    if not normalized:
        raise ValueError(f"Value cannot be converted to an identifier: {value!r}")
    if len(normalized) <= maximum:
        return normalized
    digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:8]
    return f"{normalized[: maximum - 9]}_{digest}"


def version_slug(value: str) -> str:
    return slug(value, 24)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(*arguments: str) -> None:
    print("+", " ".join(arguments), flush=True)
    subprocess.run(arguments, check=True)


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def load_manifest(path: Path) -> dict[str, Any]:
    manifest = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("Manifest must contain a YAML object")
    if manifest.get("apiVersion") != "airgap.geoserver/v1" or manifest.get("kind") != "DatasetRelease":
        raise ValueError("Manifest must use apiVersion airgap.geoserver/v1 and kind DatasetRelease")
    spec = manifest.get("spec")
    if not isinstance(spec, dict):
        raise ValueError("Manifest is missing spec")
    for field in ("collection", "release", "source", "publication"):
        if not isinstance(spec.get(field), dict):
            raise ValueError(f"Manifest is missing spec.{field}")
    collection = spec["collection"]
    release = spec["release"]
    source = spec["source"]
    publication = spec["publication"]
    for field in ("id", "title", "description", "license"):
        if not collection.get(field):
            raise ValueError(f"Manifest is missing spec.collection.{field}")
    for field in ("version", "datetime"):
        if not release.get(field):
            raise ValueError(f"Manifest is missing spec.release.{field}")
    if source.get("type") not in {"vector", "raster"}:
        raise ValueError("spec.source.type must be vector or raster")
    if not publication.get("workspace"):
        raise ValueError("Manifest is missing spec.publication.workspace")
    datetime.fromisoformat(str(release["datetime"]).replace("Z", "+00:00"))
    return manifest


class Publisher:
    def __init__(self) -> None:
        self.geoserver_url = required_env("GEOSERVER_URL")
        self.geoserver_user = required_env("GEOSERVER_USER")
        self.geoserver_password = required_env("GEOSERVER_PASSWORD")
        self.public_base_url = required_env("PUBLIC_BASE_URL")
        self.postgis = {
            "host": required_env("POSTGIS_HOST"),
            "port": os.getenv("POSTGIS_PORT", "5432"),
            "dbname": required_env("POSTGIS_DATABASE"),
            "user": required_env("POSTGIS_USER"),
            "password": required_env("POSTGIS_PASSWORD"),
        }
        self.pgstac = {
            "host": required_env("PGSTAC_HOST"),
            "port": os.getenv("PGSTAC_PORT", "5432"),
            "dbname": required_env("PGSTAC_DATABASE"),
            "user": required_env("PGSTAC_USER"),
            "password": required_env("PGSTAC_PASSWORD"),
            "options": "-c search_path=pgstac,public",
        }
        self.http = requests.Session()
        self.http.auth = (self.geoserver_user, self.geoserver_password)

    def wait_ready(self, timeout: int = 300) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                response = self.http.get(f"{self.geoserver_url}/rest/about/version.json", timeout=10)
                response.raise_for_status()
                with psycopg.connect(**self.pgstac, connect_timeout=5) as connection:
                    with connection.cursor() as cursor:
                        cursor.execute("SELECT to_regprocedure('pgstac.upsert_collection(jsonb)') IS NOT NULL")
                        if cursor.fetchone()[0]:
                            return
            except (requests.RequestException, psycopg.Error):
                pass
            time.sleep(3)
        raise RuntimeError("GeoServer or PgSTAC did not become ready")

    @contextmanager
    def collection_lock(self, collection_id: str):
        connection = psycopg.connect(**self.pgstac)
        try:
            with connection.cursor() as cursor:
                cursor.execute("SELECT pg_advisory_lock(hashtext(%s))", (collection_id,))
            yield connection
        finally:
            try:
                connection.rollback()
                with connection.cursor() as cursor:
                    cursor.execute("SELECT pg_advisory_unlock(hashtext(%s))", (collection_id,))
                connection.commit()
            finally:
                connection.close()

    def geoserver(self, method: str, path: str, **kwargs: Any) -> requests.Response:
        response = self.http.request(method, f"{self.geoserver_url}{path}", timeout=90, **kwargs)
        if not response.ok:
            raise RuntimeError(f"GeoServer {method} {path} failed: {response.status_code} {response.text[:500]}")
        return response

    def exists(self, path: str) -> bool:
        response = self.http.get(f"{self.geoserver_url}{path}", timeout=30)
        if response.status_code == 404:
            return False
        response.raise_for_status()
        return True

    def ensure_workspace(self, workspace: str) -> None:
        encoded = quote(workspace, safe="")
        if not self.exists(f"/rest/workspaces/{encoded}.json"):
            self.geoserver("POST", "/rest/workspaces", json={"workspace": {"name": workspace}})

    def validate_style(self, workspace: str, style: str) -> None:
        if self.exists(f"/rest/workspaces/{quote(workspace, safe='')}/styles/{quote(style, safe='')}.json"):
            return
        if self.exists(f"/rest/styles/{quote(style, safe='')}.json"):
            return
        raise ValueError(f"GeoServer style does not exist: {workspace}:{style} or global {style}")

    def publish_vector(self, source: Path, manifest: dict[str, Any], names: dict[str, str]) -> None:
        source_spec = manifest["spec"]["source"]
        connection = (
            f"PG:host={self.postgis['host']} port={self.postgis['port']} dbname={self.postgis['dbname']} "
            f"user={self.postgis['user']} password={self.postgis['password']}"
        )
        command = [
            "ogr2ogr", "-f", "PostgreSQL", connection, str(source),
            "-nln", f"public.{names['table']}", "-nlt", "PROMOTE_TO_MULTI",
            "-lco", "GEOMETRY_NAME=geom", "-lco", "FID=gid", "-overwrite",
        ]
        if source_spec.get("layer"):
            command.append(str(source_spec["layer"]))
        run(*command)

        workspace = names["workspace"]
        self.ensure_workspace(workspace)
        store_path = f"/rest/workspaces/{quote(workspace, safe='')}/datastores/{quote(names['store'], safe='')}"
        if not self.exists(store_path + ".json"):
            entries = [
                {"@key": "dbtype", "$": "postgis"},
                {"@key": "host", "$": self.postgis["host"]},
                {"@key": "port", "$": self.postgis["port"]},
                {"@key": "database", "$": self.postgis["dbname"]},
                {"@key": "schema", "$": "public"},
                {"@key": "user", "$": self.postgis["user"]},
                {"@key": "passwd", "$": self.postgis["password"]},
                {"@key": "Expose primary keys", "$": "true"},
            ]
            self.geoserver("POST", f"/rest/workspaces/{quote(workspace, safe='')}/datastores", json={"dataStore": {"name": names["store"], "connectionParameters": {"entry": entries}}})
        feature_path = store_path + f"/featuretypes/{quote(names['layer'], safe='')}"
        if not self.exists(feature_path + ".json"):
            self.geoserver("POST", store_path + "/featuretypes", json={"featureType": {
                "name": names["layer"], "nativeName": names["table"],
                "title": manifest["spec"]["collection"]["title"], "enabled": True,
            }})

    def publish_raster(self, source: Path, manifest: dict[str, Any], names: dict[str, str], asset_path: Path) -> None:
        run("gdal_translate", str(source), str(asset_path), "-of", "COG", "-co", "COMPRESS=DEFLATE", "-co", "BIGTIFF=IF_SAFER")
        workspace = names["workspace"]
        self.ensure_workspace(workspace)
        store_path = f"/rest/workspaces/{quote(workspace, safe='')}/coveragestores/{quote(names['store'], safe='')}"
        if not self.exists(store_path + ".json"):
            relative = asset_path.relative_to(DATA_ROOT).as_posix()
            self.geoserver(
                "POST",
                f"/rest/workspaces/{quote(workspace, safe='')}/coveragestores",
                json={"coverageStore": {
                    "name": names["store"],
                    "type": "GeoTIFF",
                    "enabled": True,
                    "url": f"file:///data/{relative}",
                    "workspace": {"name": workspace},
                }},
            )
        coverage_path = store_path + f"/coverages/{quote(names['layer'], safe='')}"
        if not self.exists(coverage_path + ".json"):
            self.geoserver("POST", store_path + "/coverages", json={"coverage": {
                "name": names["layer"],
                "nativeName": asset_path.stem,
                "title": manifest["spec"]["collection"]["title"],
                "enabled": True,
            }})

    def apply_style_and_cache(self, names: dict[str, str], style: str | None) -> None:
        layer_name = f"{names['workspace']}:{names['layer']}"
        if style:
            self.validate_style(names["workspace"], style)
            self.geoserver("PUT", f"/rest/layers/{quote(layer_name, safe=':')}", json={"layer": {"defaultStyle": {"name": style}}})
        self.geoserver("PUT", f"/gwc/rest/layers/{quote(layer_name, safe=':')}.json", json={"GeoServerLayer": {"name": layer_name, "enabled": True}})

    def resource_metadata(self, kind: str, names: dict[str, str]) -> tuple[dict[str, Any], str]:
        workspace = quote(names["workspace"], safe="")
        store = quote(names["store"], safe="")
        layer = quote(names["layer"], safe="")
        if kind == "vector":
            metadata = self.geoserver("GET", f"/rest/workspaces/{workspace}/datastores/{store}/featuretypes/{layer}.json").json()["featureType"]
        else:
            metadata = self.geoserver("GET", f"/rest/workspaces/{workspace}/coveragestores/{store}/coverages/{layer}.json").json()["coverage"]
        layer_name = f"{names['workspace']}:{names['layer']}"
        layer_record = self.geoserver("GET", f"/rest/layers/{quote(layer_name, safe=':')}.json").json()["layer"]
        return metadata, layer_record.get("defaultStyle", {}).get("name", "")

    def build_records(self, manifest: dict[str, Any], names: dict[str, str], asset_name: str, checksum: str, existing_items: list[dict[str, Any]]) -> tuple[dict[str, Any], dict[str, Any]]:
        spec = manifest["spec"]
        collection_spec = spec["collection"]
        release = spec["release"]
        kind = spec["source"]["type"]
        metadata, style = self.resource_metadata(kind, names)
        extent = metadata.get("latLonBoundingBox")
        if not extent:
            raise ValueError("Published GeoServer resource has no WGS84 extent")
        bbox = [float(extent[key]) for key in ("minx", "miny", "maxx", "maxy")]
        geometry = {"type": "Polygon", "coordinates": [[
            [bbox[0], bbox[1]], [bbox[2], bbox[1]], [bbox[2], bbox[3]],
            [bbox[0], bbox[3]], [bbox[0], bbox[1]],
        ]]}
        workspace = names["workspace"]
        layer_name = f"{workspace}:{names['layer']}"
        geoserver_public = f"{self.public_base_url}/geoserver-cloud"
        stac_public = f"{self.public_base_url}/api/stac"
        wms_href = f"{geoserver_public}/wms"
        wmts_href = f"{geoserver_public}/gwc/service/wmts"
        wms_query = urlencode({
            "service": "WMS", "version": "1.1.1", "request": "GetMap",
            "layers": layer_name, "styles": style, "srs": "EPSG:4326",
            "bbox": ",".join(str(value) for value in bbox), "width": 800,
            "height": 500, "format": "image/png", "transparent": "true",
        })
        links = [
            {"rel": "wms", "href": wms_href, "type": "image/png", "title": "GeoServer WMS", "wms:layers": [layer_name], "wms:styles": [style], "wms:transparent": True},
            {"rel": "wmts", "href": wmts_href, "type": "image/png", "title": "GeoServer WMTS", "wmts:layer": layer_name, "wmts:encoding": "kvp"},
        ]
        if kind == "vector":
            service = ("WFS", "2.0.0")
        else:
            service = ("WCS", "2.0.1")
        links.append({"rel": "service", "href": f"{geoserver_public}/ows?" + urlencode({"service": service[0], "version": service[1], "request": "GetCapabilities"}), "type": "application/xml", "title": f"GeoServer {service[0]} capabilities"})
        media_type = "application/geopackage+sqlite3" if asset_name.endswith(".gpkg") else "application/geo+json"
        if kind == "raster":
            media_type = "image/tiff; application=geotiff; profile=cloud-optimized"
        assets = {
            "data": {"href": f"{self.public_base_url}/stac-assets/{names['collection']}/{names['version']}/{asset_name}", "type": media_type, "title": "Immutable published data", "roles": ["data"], "file:checksum": f"sha256:{checksum}"},
            "thumbnail": {"href": f"{wms_href}?{wms_query}", "type": "image/png", "title": "GeoServer map preview", "roles": ["thumbnail"]},
        }
        search_parts = [collection_spec["id"], collection_spec["title"], collection_spec["description"], str(release["version"])] + list(collection_spec.get("keywords", []))
        item = {
            "type": "Feature", "stac_version": "1.1.0", "stac_extensions": [WEB_MAP_LINKS_SCHEMA],
            "id": names["item"], "collection": names["collection"], "bbox": bbox, "geometry": geometry,
            "properties": {
                "datetime": release["datetime"], "version": str(release["version"]),
                "gscloud:search_text": " ".join(search_parts).lower(),
                "gscloud:geoserver_layer": layer_name, "gscloud:data_type": kind,
            },
            "links": [{"rel": "collection", "href": f"{stac_public}/collections/{names['collection']}", "type": "application/json"}] + links,
            "assets": assets,
        }
        all_items = existing_items + [item]
        bboxes = [record["bbox"] for record in all_items]
        datetimes = [record["properties"]["datetime"] for record in all_items]
        aggregate_bbox = [min(value[0] for value in bboxes), min(value[1] for value in bboxes), max(value[2] for value in bboxes), max(value[3] for value in bboxes)]
        collection = {
            "type": "Collection", "stac_version": "1.1.0", "stac_extensions": [WEB_MAP_LINKS_SCHEMA],
            "id": names["collection"], "title": collection_spec["title"], "description": collection_spec["description"],
            "license": collection_spec["license"], "keywords": collection_spec.get("keywords", []),
            "providers": collection_spec.get("providers", []),
            "extent": {"spatial": {"bbox": [aggregate_bbox]}, "temporal": {"interval": [[min(datetimes), max(datetimes)]]}},
            "summaries": {"gscloud:data_type": [kind]},
            "links": links,
        }
        core_collection = copy.deepcopy(collection)
        core_collection["stac_extensions"] = []
        core_item = copy.deepcopy(item)
        core_item["stac_extensions"] = []
        pystac.Collection.from_dict(core_collection).validate()
        pystac.Item.from_dict(core_item).validate()
        return collection, item

    def existing_items(self, connection: psycopg.Connection, collection_id: str, exclude_item: str = "") -> list[dict[str, Any]]:
        with connection.cursor() as cursor:
            cursor.execute("SELECT content FROM pgstac.items WHERE collection = %s", (collection_id,))
            return [row[0] for row in cursor.fetchall() if row[0].get("id") != exclude_item]

    def delete_stac_item(self, collection_id: str, item_id: str) -> None:
        try:
            with psycopg.connect(**self.pgstac) as connection:
                with connection.cursor() as cursor:
                    cursor.execute("DELETE FROM pgstac.items WHERE id = %s AND collection = %s", (item_id, collection_id))
                connection.commit()
        except psycopg.Error:
            pass

    def publish(self, manifest_path: Path, source_path: Path) -> None:
        manifest = load_manifest(manifest_path)
        spec = manifest["spec"]
        collection_id = slug(str(spec["collection"]["id"]), 48).replace("_", "-")
        version = version_slug(str(spec["release"]["version"]))
        item_id = f"{collection_id}-{version}"
        workspace = slug(str(spec["publication"]["workspace"]), 32)
        release_name = slug(f"{collection_id}_{version}", 48)
        names = {
            "collection": collection_id, "version": version, "item": item_id,
            "workspace": workspace, "table": release_name,
            "store": release_name, "layer": release_name,
        }
        source_path = source_path.resolve()
        if not source_path.is_file():
            raise FileNotFoundError(source_path)
        source_checksum = file_sha256(source_path)
        receipt_path = RECEIPT_ROOT / collection_id / f"{version}.json"
        tombstone_path = TOMBSTONE_ROOT / collection_id / f"{version}.json"
        if tombstone_path.exists():
            raise RuntimeError(f"Release version was previously unpublished and cannot be reused: {collection_id}/{version}")
        if receipt_path.exists():
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            if receipt["source_checksum"] != source_checksum:
                raise RuntimeError("Release already exists with different source content")
            print(f"Release already published with matching checksum: {item_id}")
            return

        kind = spec["source"]["type"]
        suffix = source_path.suffix.lower()
        allowed = {"vector": {".gpkg", ".geojson", ".json"}, "raster": {".tif", ".tiff"}}
        if suffix not in allowed[kind]:
            raise ValueError(f"Unsupported {kind} source extension: {suffix}")
        release_dir = ASSET_ROOT / collection_id / version
        if release_dir.exists():
            shutil.rmtree(release_dir)
        release_dir.mkdir(parents=True)
        asset_name = "data.tif" if kind == "raster" else f"data{suffix}"
        asset_path = release_dir / asset_name
        self.wait_ready()
        try:
            with self.collection_lock(collection_id) as stac_connection:
                with stac_connection.cursor() as cursor:
                    cursor.execute("SELECT 1 FROM pgstac.items WHERE id = %s AND collection = %s", (item_id, collection_id))
                    if cursor.fetchone():
                        print(f"Reconciling receipt-less STAC Item: {item_id}")
                        cursor.execute("DELETE FROM pgstac.items WHERE id = %s AND collection = %s", (item_id, collection_id))
                        stac_connection.commit()
                if kind == "vector":
                    shutil.copy2(source_path, asset_path)
                    self.publish_vector(asset_path, manifest, names)
                else:
                    self.publish_raster(source_path, manifest, names, asset_path)
                style = spec["publication"].get("style")
                self.apply_style_and_cache(names, style)
                asset_checksum = file_sha256(asset_path)
                collection, item = self.build_records(manifest, names, asset_name, asset_checksum, self.existing_items(stac_connection, collection_id))
                with stac_connection.cursor() as cursor:
                    cursor.execute("SELECT pgstac.upsert_collection(%s)", (Jsonb(collection),))
                    cursor.execute("SELECT pgstac.upsert_item(%s)", (Jsonb(item),))
                stac_connection.commit()
                receipt = {
                    "schema_version": 1, "published_at": datetime.now(timezone.utc).isoformat(),
                    "source_checksum": source_checksum, "asset_checksum": asset_checksum,
                    "source_type": kind, "asset": str(asset_path), "names": names,
                    "manifest": manifest,
                }
                atomic_json(receipt_path, receipt)
                os.chmod(asset_path, 0o664)
                os.chmod(release_dir, 0o775)
                print(f"Published {item_id}")
        except Exception:
            self.delete_stac_item(collection_id, item_id)
            self.delete_geoserver(names, kind, tolerate=True)
            if kind == "vector":
                self.delete_table(names["table"], tolerate=True)
            shutil.rmtree(release_dir, ignore_errors=True)
            raise

    def delete_table(self, table: str, tolerate: bool = False) -> None:
        try:
            with psycopg.connect(**self.postgis) as connection:
                with connection.cursor() as cursor:
                    cursor.execute(sql.SQL("DROP TABLE IF EXISTS public.{} CASCADE").format(sql.Identifier(table)))
                connection.commit()
        except psycopg.Error:
            if not tolerate:
                raise

    def delete_geoserver(self, names: dict[str, str], kind: str, tolerate: bool = False) -> None:
        layer_name = f"{names['workspace']}:{names['layer']}"
        operations = [
            ("DELETE", f"/gwc/rest/layers/{quote(layer_name, safe=':')}.xml"),
            ("DELETE", f"/rest/workspaces/{quote(names['workspace'], safe='')}/{'datastores' if kind == 'vector' else 'coveragestores'}/{quote(names['store'], safe='')}?recurse=true"),
        ]
        for method, path in operations:
            response = self.http.request(method, f"{self.geoserver_url}{path}", timeout=60)
            if response.status_code not in {200, 202, 204, 404} and not tolerate:
                raise RuntimeError(f"GeoServer cleanup failed: {response.status_code} {path} {response.text[:300]}")

    def unpublish(self, collection_id: str, version: str, remove_collection: bool) -> None:
        collection_id = slug(collection_id, 48).replace("_", "-")
        version = version_slug(version)
        receipt_path = RECEIPT_ROOT / collection_id / f"{version}.json"
        if not receipt_path.exists():
            raise RuntimeError(f"Publication receipt does not exist: {collection_id}/{version}")
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        names = receipt["names"]
        kind = receipt["source_type"]
        self.wait_ready()
        with self.collection_lock(collection_id) as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT content FROM pgstac.collections WHERE id = %s", (collection_id,))
                row = cursor.fetchone()
                collection_record = row[0] if row else None
            current_items = self.existing_items(connection, collection_id)
            if remove_collection and len(current_items) > 1:
                raise RuntimeError("Collection still has other published Items and cannot be removed")
            with connection.cursor() as cursor:
                cursor.execute("DELETE FROM pgstac.items WHERE id = %s AND collection = %s", (names["item"], collection_id))
            connection.commit()
            self.delete_geoserver(names, kind, tolerate=False)
            if kind == "vector":
                self.delete_table(names["table"])
            asset_path = Path(receipt["asset"])
            release_dir = asset_path.parent
            if release_dir.is_relative_to(ASSET_ROOT) and release_dir != ASSET_ROOT:
                shutil.rmtree(release_dir, ignore_errors=True)
            remaining = self.existing_items(connection, collection_id)
            with connection.cursor() as cursor:
                if remove_collection:
                    cursor.execute("DELETE FROM pgstac.collections WHERE id = %s", (collection_id,))
                elif remaining and collection_record:
                    collection_record["extent"] = {
                        "spatial": {"bbox": [[min(i["bbox"][0] for i in remaining), min(i["bbox"][1] for i in remaining), max(i["bbox"][2] for i in remaining), max(i["bbox"][3] for i in remaining)]]},
                        "temporal": {"interval": [[min(i["properties"]["datetime"] for i in remaining), max(i["properties"]["datetime"] for i in remaining)]]},
                    }
                    cursor.execute("SELECT pgstac.upsert_collection(%s)", (Jsonb(collection_record),))
            connection.commit()
        tombstone = {"unpublished_at": datetime.now(timezone.utc).isoformat(), "receipt": receipt}
        atomic_json(TOMBSTONE_ROOT / collection_id / f"{version}.json", tombstone)
        receipt_path.unlink()
        print(f"Unpublished {names['item']}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Publish immutable GeoServer and STAC dataset releases")
    subparsers = parser.add_subparsers(dest="command", required=True)
    publish = subparsers.add_parser("publish")
    publish.add_argument("--manifest", required=True, type=Path)
    publish.add_argument("--source", required=True, type=Path)
    unpublish = subparsers.add_parser("unpublish")
    unpublish.add_argument("--collection", required=True)
    unpublish.add_argument("--version", required=True)
    unpublish.add_argument("--remove-collection", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    publisher = Publisher()
    if args.command == "publish":
        publisher.publish(args.manifest, args.source)
    else:
        publisher.unpublish(args.collection, args.version, args.remove_collection)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"Publisher failed: {error}", file=sys.stderr)
        raise

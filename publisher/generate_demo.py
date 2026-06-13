import json
import sys
from pathlib import Path

from osgeo import gdal, osr


def write_vector(path: Path) -> None:
    feature_collection = {
        "type": "FeatureCollection",
        "features": [
            {"type": "Feature", "properties": {"name": "Jerusalem", "category": "city"}, "geometry": {"type": "Point", "coordinates": [35.2137, 31.7683]}},
            {"type": "Feature", "properties": {"name": "Tel Aviv", "category": "city"}, "geometry": {"type": "Point", "coordinates": [34.7818, 32.0853]}},
            {"type": "Feature", "properties": {"name": "Haifa", "category": "city"}, "geometry": {"type": "Point", "coordinates": [34.9896, 32.7940]}},
        ],
    }
    path.write_text(json.dumps(feature_collection) + "\n", encoding="utf-8")


def write_raster(path: Path) -> None:
    driver = gdal.GetDriverByName("GTiff")
    dataset = driver.Create(str(path), 128, 128, 1, gdal.GDT_Byte)
    dataset.SetGeoTransform((34.0, 2.0 / 128, 0, 33.0, 0, -2.0 / 128))
    spatial_reference = osr.SpatialReference()
    spatial_reference.ImportFromEPSG(4326)
    dataset.SetProjection(spatial_reference.ExportToWkt())
    band = dataset.GetRasterBand(1)
    rows = bytes((40 + ((x + y) % 180) for y in range(128) for x in range(128)))
    band.WriteRaster(0, 0, 128, 128, rows)
    band.SetNoDataValue(0)
    dataset.FlushCache()
    dataset = None


def main() -> int:
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    write_vector(output / "demo-places.geojson")
    write_raster(output / "demo-elevation.tif")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

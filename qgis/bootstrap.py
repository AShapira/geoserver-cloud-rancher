import os

from qgis.core import QgsDataSourceUri, QgsSettings


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


settings = QgsSettings()

connection = "/PostgreSQL/connections/GeoServer PostGIS"
settings.setValue(f"{connection}/host", required("POSTGIS_HOST"))
settings.setValue(f"{connection}/port", os.environ.get("POSTGIS_PORT", "5432"))
settings.setValue(f"{connection}/database", required("POSTGIS_DATABASE"))
settings.setValue(f"{connection}/username", required("POSTGIS_USERNAME"))
settings.setValue(f"{connection}/password", required("POSTGIS_PASSWORD"))
settings.setValue(f"{connection}/saveUsername", "true")
settings.setValue(f"{connection}/savePassword", "true")
settings.setValue(f"{connection}/sslmode", int(QgsDataSourceUri.SslDisable))
settings.setValue("/PostgreSQL/connections/selected", "GeoServer PostGIS")

geoserver = required("GEOSERVER_INTERNAL_URL").rstrip("/")
settings.setValue("/qgis/connections-wms/GeoServer Cloud/url", f"{geoserver}/wms")
settings.setValue("/qgis/connections-wfs/GeoServer Cloud/url", f"{geoserver}/wfs")
settings.setValue("/qgis/connections-wfs/GeoServer Cloud/version", "2.0.0")
settings.sync()

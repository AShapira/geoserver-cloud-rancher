ARG QGIS_BASE_IMAGE=kasmweb/core-ubuntu-noble:1.17.0@sha256:eeaab79e401c3b70977afba2f7ec0d166e95547fdbca1d070905532a1af70f8c
FROM ${QGIS_BASE_IMAGE}

USER root

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/kasm-default-profile \
    STARTUPDIR=/dockerstartup

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gdal-bin \
        jq \
        postgresql-client \
        qgis \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY bootstrap.py /opt/qgis/bootstrap.py
COPY custom_startup.sh /dockerstartup/custom_startup.sh
COPY geoserver-rest /usr/local/bin/geoserver-rest

RUN mkdir -p /data \
    && chmod 0755 /dockerstartup/custom_startup.sh /usr/local/bin/geoserver-rest \
    && chown -R 1000:0 /opt/qgis /home/kasm-default-profile /data \
    && /dockerstartup/set_user_permission.sh /home/kasm-default-profile

ENV HOME=/home/kasm-user
WORKDIR /home/kasm-user

USER 1000

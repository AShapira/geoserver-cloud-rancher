FROM node:20-alpine AS build
ARG STAC_BROWSER_VERSION=4.0.1
WORKDIR /src
RUN wget -qO /tmp/stac-browser.tar.gz "https://github.com/radiantearth/stac-browser/archive/refs/tags/v${STAC_BROWSER_VERSION}.tar.gz" \
    && tar -xzf /tmp/stac-browser.tar.gz --strip-components=1 -C /src \
    && rm /tmp/stac-browser.tar.gz
COPY basemaps.config.js ./basemaps.config.js
COPY deployment.config.js ./deployment.config.js
COPY src.config.js ./src/config.js
ENV SB_CONFIG=/src/deployment.config.js \
    SB_pathPrefix=/stac/ \
    SB_catalogUrl=/api/stac/ \
    SB_catalogTitle="GeoServer Cloud STAC" \
    SB_allowExternalAccess=true \
    SB_useTileLayerAsFallback=false
RUN npm ci && npm run build

FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/dist /usr/share/nginx/html
USER root
RUN find /usr/share/nginx/html -type f \( -name '*.js' -o -name '*.map' \) -exec sed -i \
      -e 's#https://tile.openstreetmap.org/{z}/{x}/{y}.png#/stac/offline-basemap/{z}/{x}/{y}.png#g' \
      -e 's#https://planetarymaps.usgs.gov#/stac/offline-basemap.invalid#g' {} +
USER 101
EXPOSE 8080

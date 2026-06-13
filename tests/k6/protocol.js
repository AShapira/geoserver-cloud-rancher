import http from 'k6/http';
import { check, sleep } from 'k6';

const base = __ENV.BASE_URL || 'http://gscloud-gsc-gateway.gscloud.svc.cluster.local:8080/geoserver-cloud';

export const options = {
  vus: Number(__ENV.VUS || 1),
  duration: __ENV.DURATION || '30s',
  thresholds: {
    http_req_failed: ['rate<0.02'],
    http_req_duration: ['p(95)<2000']
  }
};

export default function () {
  const wms = http.get(`${base}/wms?service=WMS&version=1.3.0&request=GetMap&layers=demo:demo_places_1_0_0&styles=&crs=EPSG:4326&bbox=34,31,36,33&width=512&height=512&format=image/png`);
  const wfs = http.get(`${base}/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=demo:demo_places_1_0_0&outputFormat=application%2Fjson`);
  const wmts = http.get(`${base}/gwc/service/wmts?SERVICE=WMTS&REQUEST=GetCapabilities`);
  check(wms, { 'WMS 200': (response) => response.status === 200 });
  check(wfs, { 'WFS 200': (response) => response.status === 200 });
  check(wmts, { 'WMTS 200': (response) => response.status === 200 });
  sleep(1);
}

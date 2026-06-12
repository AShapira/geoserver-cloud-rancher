import 'ol/ol.css';
import './style.css';
import Map from 'ol/Map.js';
import View from 'ol/View.js';
import TileLayer from 'ol/layer/Tile.js';
import VectorLayer from 'ol/layer/Vector.js';
import TileWMS from 'ol/source/TileWMS.js';
import VectorSource from 'ol/source/Vector.js';
import GeoJSON from 'ol/format/GeoJSON.js';
import WMTSCapabilities from 'ol/format/WMTSCapabilities.js';
import WMTS, { optionsFromCapabilities } from 'ol/source/WMTS.js';
import { Circle as CircleStyle, Fill, Stroke, Style } from 'ol/style.js';
import { fromLonLat } from 'ol/proj.js';

const base = '/geoserver-cloud';
const layerName = 'demo:demo_places';

const wmsLayer = new TileLayer({
  source: new TileWMS({
    url: `${base}/wms`,
    params: { LAYERS: layerName, TILED: false, VERSION: '1.3.0' },
    serverType: 'geoserver',
    crossOrigin: 'anonymous'
  })
});

const wfsSource = new VectorSource();
const wfsLayer = new VectorLayer({
  source: wfsSource,
  style: new Style({
    image: new CircleStyle({
      radius: 8,
      fill: new Fill({ color: '#38bdf8' }),
      stroke: new Stroke({ color: '#07111f', width: 3 })
    })
  })
});

let wmtsLayer = new TileLayer({ visible: false });
const map = new Map({
  target: 'map',
  layers: [wmsLayer, wmtsLayer, wfsLayer],
  view: new View({ center: fromLonLat([35.1, 32.05]), zoom: 7.2, minZoom: 3, maxZoom: 18 })
});

function setStatus(protocol, ok, detail) {
  const card = document.querySelector(`[data-protocol="${protocol}"]`);
  card.dataset.state = ok ? 'ok' : 'error';
  document.getElementById(`${protocol}-status`).textContent = ok ? 'Ready' : 'Failed';
  document.getElementById(`${protocol}-detail`).textContent = detail;
}

async function fetchChecked(url, options) {
  const response = await fetch(url, options);
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
  return response;
}

async function refreshWms() {
  try {
    await fetchChecked(`${base}/wms?service=WMS&version=1.3.0&request=GetCapabilities`);
    setStatus('wms', true, 'Capabilities and GetMap available');
    wmsLayer.getSource().refresh();
  } catch (error) {
    setStatus('wms', false, error.message);
    throw error;
  }
}

async function refreshWmts() {
  try {
    const response = await fetchChecked(`${base}/gwc/service/wmts?SERVICE=WMTS&REQUEST=GetCapabilities`);
    const capabilities = new WMTSCapabilities().read(await response.text());
    const options = optionsFromCapabilities(capabilities, { layer: layerName, matrixSet: 'EPSG:3857' });
    if (!options) throw new Error('Layer is absent from WMTS capabilities');
    wmtsLayer.setSource(new WMTS(options));
    setStatus('wmts', true, 'Capabilities and cached tiles available');
  } catch (error) {
    setStatus('wmts', false, error.message);
    throw error;
  }
}

async function refreshWfs() {
  try {
    const url = `${base}/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=${encodeURIComponent(layerName)}&outputFormat=application%2Fjson&srsName=EPSG%3A3857`;
    const response = await fetchChecked(url);
    const json = await response.json();
    const features = new GeoJSON().readFeatures(json, { featureProjection: 'EPSG:3857' });
    wfsSource.clear(true);
    wfsSource.addFeatures(features);
    document.getElementById('feature-count').textContent = String(features.length);
    setStatus('wfs', true, `${features.length} GeoJSON features loaded`);
  } catch (error) {
    setStatus('wfs', false, error.message);
    throw error;
  }
}

async function refreshAll() {
  const errorNode = document.getElementById('error');
  errorNode.textContent = '';
  const results = await Promise.allSettled([refreshWms(), refreshWmts(), refreshWfs()]);
  const failures = results.filter((result) => result.status === 'rejected');
  if (failures.length) errorNode.textContent = failures.map((failure) => failure.reason.message).join(' | ');
  document.getElementById('last-refresh').textContent = new Date().toLocaleTimeString();
}

document.getElementById('wms-toggle').addEventListener('change', (event) => wmsLayer.setVisible(event.target.checked));
document.getElementById('wmts-toggle').addEventListener('change', (event) => wmtsLayer.setVisible(event.target.checked));
document.getElementById('wfs-toggle').addEventListener('change', (event) => wfsLayer.setVisible(event.target.checked));
document.getElementById('refresh').addEventListener('click', refreshAll);

refreshAll();

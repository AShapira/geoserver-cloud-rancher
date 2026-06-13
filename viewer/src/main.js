import 'ol/ol.css';
import './style.css';
import Map from 'ol/Map.js';
import View from 'ol/View.js';
import TileLayer from 'ol/layer/Tile.js';
import TileWMS from 'ol/source/TileWMS.js';
import WMTSCapabilities from 'ol/format/WMTSCapabilities.js';
import WMTS, { optionsFromCapabilities } from 'ol/source/WMTS.js';
import { fromLonLat, transformExtent } from 'ol/proj.js';

const stacBase = '/api/stac';
const wmsLayer = new TileLayer({ visible: true });
const wmtsLayer = new TileLayer({ visible: false });
const map = new Map({
  target: 'map',
  layers: [wmsLayer, wmtsLayer],
  view: new View({ center: fromLonLat([35.1, 32.05]), zoom: 7.2, minZoom: 2, maxZoom: 20 })
});

let selectedItem = null;
let nextRequest = null;

function setStatus(protocol, state, detail) {
  const card = document.querySelector(`[data-protocol="${protocol}"]`);
  card.dataset.state = state;
  document.getElementById(`${protocol}-status`).textContent = state === 'ok' ? 'Ready' : state === 'na' ? 'N/A' : 'Failed';
  document.getElementById(`${protocol}-detail`).textContent = detail;
}

async function fetchChecked(url, options) {
  const response = await fetch(url, options);
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
  return response;
}

function linkByRel(item, rel) {
  return (item.links || []).find((link) => link.rel === rel);
}

function serviceLink(item, service) {
  return (item.links || []).find((link) => link.rel === 'service' && (link.title || '').toUpperCase().includes(service));
}

function showError(error) {
  document.getElementById('error').textContent = error?.message || String(error);
}

async function loadCollections() {
  const response = await fetchChecked(`${stacBase}/collections`);
  const payload = await response.json();
  const select = document.getElementById('collection');
  select.replaceChildren(new Option('All collections', ''));
  for (const collection of payload.collections || []) {
    select.add(new Option(collection.title || collection.id, collection.id));
  }
  setStatus('stac', 'ok', `${(payload.collections || []).length} collections available`);
}

function searchBody() {
  const body = { limit: 50 };
  const collection = document.getElementById('collection').value;
  if (collection) body.collections = [collection];
  if (document.getElementById('map-extent').checked) {
    body.bbox = transformExtent(map.getView().calculateExtent(map.getSize()), 'EPSG:3857', 'EPSG:4326');
  }
  const start = document.getElementById('datetime-start').value;
  const end = document.getElementById('datetime-end').value;
  if (start || end) body.datetime = `${start ? `${start}T00:00:00Z` : '..'}/${end ? `${end}T23:59:59Z` : '..'}`;
  const keyword = document.getElementById('keyword').value.trim().toLowerCase();
  if (keyword) {
    body.filter = { op: 'like', args: [{ property: 'gscloud:search_text' }, `%${keyword}%`] };
    body['filter-lang'] = 'cql2-json';
  }
  return body;
}

async function runSearch(request = null) {
  document.getElementById('error').textContent = '';
  const response = request
    ? await fetchChecked(request.href, { method: request.method || 'GET', headers: request.headers, body: request.body })
    : await fetchChecked(`${stacBase}/search`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(searchBody()) });
  const payload = await response.json();
  const results = document.getElementById('results');
  results.replaceChildren();
  for (const item of payload.features || []) {
    const version = item.properties?.version ? ` (${item.properties.version})` : '';
    results.add(new Option(`${item.collection}: ${item.id}${version}`, JSON.stringify(item)));
  }
  nextRequest = null;
  const next = (payload.links || []).find((link) => link.rel === 'next');
  if (next) {
    nextRequest = {
      href: next.href,
      method: next.method || 'GET',
      headers: next.headers || (next.method === 'POST' ? { 'Content-Type': 'application/json' } : undefined),
      body: next.body ? JSON.stringify(next.body) : undefined
    };
  }
  document.getElementById('next').disabled = !nextRequest;
  document.getElementById('result-count').textContent = String((payload.features || []).length);
  if (results.options.length) {
    results.selectedIndex = 0;
    await selectResult();
  } else {
    selectedItem = null;
    wmsLayer.setSource(null);
    wmtsLayer.setSource(null);
    document.getElementById('item-title').textContent = 'No matching release';
  }
}

async function configureWmts(item) {
  const link = linkByRel(item, 'wmts');
  if (!link) {
    wmtsLayer.setSource(null);
    setStatus('wmts', 'na', 'Not advertised by this Item');
    return;
  }
  try {
    const response = await fetchChecked(`${link.href}${link.href.includes('?') ? '&' : '?'}SERVICE=WMTS&REQUEST=GetCapabilities`);
    const capabilities = new WMTSCapabilities().read(await response.text());
    const options = optionsFromCapabilities(capabilities, { layer: link['wmts:layer'], matrixSet: 'EPSG:3857' })
      || optionsFromCapabilities(capabilities, { layer: link['wmts:layer'], matrixSet: 'EPSG:900913' });
    if (!options) throw new Error(`WMTS capabilities do not contain ${link['wmts:layer']}`);
    wmtsLayer.setSource(new WMTS(options));
    setStatus('wmts', 'ok', `Cached layer ${link['wmts:layer']}`);
  } catch (error) {
    setStatus('wmts', 'error', error.message);
    throw error;
  }
}

async function checkService(item, service) {
  const protocol = service.toLowerCase();
  const link = serviceLink(item, service);
  if (!link) {
    setStatus(protocol, 'na', 'Not applicable to this data type');
    return;
  }
  try {
    await fetchChecked(link.href);
    setStatus(protocol, 'ok', `${service} capabilities available`);
  } catch (error) {
    setStatus(protocol, 'error', error.message);
  }
}

async function selectResult() {
  const value = document.getElementById('results').value;
  if (!value) return;
  selectedItem = JSON.parse(value);
  const wms = linkByRel(selectedItem, 'wms');
  if (!wms) throw new Error('Selected STAC Item does not advertise WMS');
  wmsLayer.setSource(new TileWMS({
    url: wms.href,
    params: { LAYERS: wms['wms:layers'].join(','), STYLES: (wms['wms:styles'] || []).join(','), TILED: false, VERSION: '1.3.0' },
    serverType: 'geoserver',
    crossOrigin: 'anonymous'
  }));
  setStatus('wms', 'ok', `Rendered ${wms['wms:layers'].join(', ')}`);
  const bbox = selectedItem.bbox;
  if (bbox) map.getView().fit(transformExtent(bbox, 'EPSG:4326', 'EPSG:3857'), { padding: [40, 40, 40, 40], maxZoom: 14, duration: 300 });
  document.getElementById('item-title').textContent = selectedItem.id;
  document.getElementById('item-type').textContent = selectedItem.properties?.['gscloud:data_type'] || 'unknown';
  document.getElementById('item-version').textContent = selectedItem.properties?.version || 'unversioned';
  const asset = selectedItem.assets?.data;
  const assetLink = document.getElementById('asset-link');
  assetLink.hidden = !asset;
  if (asset) {
    assetLink.href = asset.href;
    assetLink.textContent = `Download ${asset.title || 'data asset'}`;
  }
  await Promise.allSettled([configureWmts(selectedItem), checkService(selectedItem, 'WFS'), checkService(selectedItem, 'WCS')]);
  document.getElementById('last-refresh').textContent = new Date().toLocaleTimeString();
}

async function refreshSelected() {
  try {
    if (!selectedItem) return;
    await selectResult();
    wmsLayer.getSource()?.refresh();
    wmtsLayer.getSource()?.refresh();
  } catch (error) {
    showError(error);
  }
}

document.getElementById('search').addEventListener('click', () => runSearch().catch(showError));
document.getElementById('next').addEventListener('click', () => nextRequest && runSearch(nextRequest).catch(showError));
document.getElementById('results').addEventListener('change', () => selectResult().catch(showError));
document.getElementById('wms-toggle').addEventListener('change', (event) => wmsLayer.setVisible(event.target.checked));
document.getElementById('wmts-toggle').addEventListener('change', (event) => wmtsLayer.setVisible(event.target.checked));
document.getElementById('refresh').addEventListener('click', refreshSelected);

async function initialize() {
  try {
    await loadCollections();
    await runSearch();
  } catch (error) {
    setStatus('stac', 'error', error.message);
    showError(error);
  }
}

initialize();

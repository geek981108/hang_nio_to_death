'use strict';
/* 蔚来 NIO Power · HA 前端核心：工具、图标、接口、导航栈、弹层、下拉刷新。
   交互模型对齐 iOS App：TabView + NavigationStack + sheet / alert / menu。 */

/* ---------- 基础工具 ---------- */
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pad2 = (n) => String(n).padStart(2, '0');
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
/** 强制同步布局，使随后添加的类名能触发过渡动画（不依赖 requestAnimationFrame，后台标签页也可靠）。 */
const reflow = (el) => void el.offsetWidth;
const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const appEl = () => document.getElementById('app');

/** RFC3339（含纳秒小数）或 Unix 秒/毫秒 → Date；无效返回 null。 */
function parseDate(value) {
  if (value == null) return null;
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return null;
    return new Date(Math.abs(value) < 1e10 ? value * 1000 : value);
  }
  const s = String(value).replace(/(\.\d{3})\d+/, '$1');
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
}
const fmtDate = (d) => (d ? `${d.getFullYear()}/${pad2(d.getMonth() + 1)}/${pad2(d.getDate())}` : '--');
const fmtTime = (d) => (d ? `${pad2(d.getHours())}:${pad2(d.getMinutes())}` : '--');
const fmtDateTime = (d) => (d ? `${fmtDate(d)} ${fmtTime(d)}` : '--');
const fmtMDHMS = (d) => (d ? `${pad2(d.getMonth() + 1)}/${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}` : '--');
const startOfDay = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
const isToday = (d) => sameDay(d, new Date());
const WEEKDAYS = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
function relTime(d) {
  if (!d) return '';
  const s = Math.max(0, Math.round((Date.now() - d.getTime()) / 1000));
  if (s < 60) return '刚刚';
  if (s < 3600) return `${Math.floor(s / 60)} 分钟前`;
  if (s < 86400) return `${Math.floor(s / 3600)} 小时前`;
  return `${Math.floor(s / 86400)} 天前`;
}
function distanceLabel(km) {
  if (!isNum(km)) return '--';
  if (km >= 10) return `${km.toFixed(1)} km`;
  if (km >= 0.1) return `${km.toFixed(2)} km`;
  return `${Math.round(km * 1000)} m`;
}
function durationLabel(minutes) {
  if (minutes >= 60) return `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分`;
  return `${minutes} 分钟`;
}
function haversineMeters(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const rad = (deg) => (deg * Math.PI) / 180;
  const dLat = rad(lat2 - lat1);
  const dLon = rad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}
function validCoord(lat, lon) {
  return isNum(lat) && isNum(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && !(Math.abs(lat) < 0.01 && Math.abs(lon) < 0.01);
}

/* ---------- 本地存储 ---------- */
const Store = {
  get(key, fallback = null) {
    try {
      const raw = localStorage.getItem(key);
      return raw == null ? fallback : JSON.parse(raw);
    } catch (e) { return fallback; }
  },
  set(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch (e) { /* 隐私模式下忽略 */ }
  },
  remove(key) {
    try { localStorage.removeItem(key); } catch (e) { /* ignore */ }
  },
  keys(prefix) {
    const out = [];
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k && k.startsWith(prefix)) out.push(k);
      }
    } catch (e) { /* ignore */ }
    return out;
  },
};

/* ---------- 外观 ---------- */
const Theme = {
  key: 'nio.theme',
  mode() { return Store.get(this.key, 'auto'); },
  apply() {
    const mode = this.mode();
    const dark = mode === 'dark' || (mode === 'auto' && window.matchMedia('(prefers-color-scheme: dark)').matches);
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.content = dark ? '#12141a' : '#f5f5f2';
    document.dispatchEvent(new CustomEvent('themechange'));
  },
  set(mode) { Store.set(this.key, mode); this.apply(); },
  init() {
    this.apply();
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => this.apply());
  },
};

/* ---------- 图标（对应 App 里用到的 SF Symbols） ---------- */
const ICONS = {
  car: '<path d="M19 17h2c.6 0 1-.4 1-1v-3c0-.9-.7-1.7-1.5-1.9C18.7 10.6 16 10 16 10s-1.3-1.4-2.2-2.3c-.5-.4-1.1-.7-1.8-.7H5c-.6 0-1.1.4-1.4.9l-1.4 2.9A3.7 3.7 0 0 0 2 12v4c0 .6.4 1 1 1h2"/><circle cx="7" cy="17" r="2"/><path d="M9 17h6"/><circle cx="17" cy="17" r="2"/>',
  boltcar: '<path d="M19 18h2c.6 0 1-.4 1-1v-3c0-.9-.7-1.7-1.5-1.9C18.7 11.6 16 11 16 11s-1.3-1.4-2.2-2.3c-.5-.4-1.1-.7-1.8-.7H5c-.6 0-1.1.4-1.4.9l-1.4 2.9A3.7 3.7 0 0 0 2 13v4c0 .6.4 1 1 1h2"/><circle cx="7" cy="18" r="2"/><path d="M9 18h6"/><circle cx="17" cy="18" r="2"/><path d="m20 1-2.5 3.5h3L18 8"/>',
  bolt: '<path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>',
  chart: '<path d="M3 3v16a2 2 0 0 0 2 2h16"/><path d="M18 17V9"/><path d="M13 17V5"/><path d="M8 17v-3"/>',
  gear: '<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>',
  refresh: '<path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/>',
  swap: '<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>',
  history: '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l4 2"/>',
  lock: '<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  unlock: '<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 9.9-1"/>',
  shield: '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="M12 22V2"/>',
  shieldoff: '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m3 3 18 18"/>',
  shieldcheck: '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/>',
  shieldwarn: '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="M12 8v4"/><path d="M12 16h.01"/>',
  horn: '<path d="m3 11 18-5v12L3 14v-3z"/><path d="M11.6 16.8a3 3 0 1 1-5.8-1.6"/>',
  mute: '<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/><line x1="22" x2="16" y1="9" y2="15"/><line x1="16" x2="22" y1="9" y2="15"/>',
  location: '<polygon points="3 11 22 2 13 21 11 13 3 11"/>',
  more: '<circle cx="12" cy="12" r="1.2"/><circle cx="19" cy="12" r="1.2"/><circle cx="5" cy="12" r="1.2"/>',
  morecircle: '<circle cx="12" cy="12" r="10"/><path d="M17 12h.01"/><path d="M12 12h.01"/><path d="M7 12h.01"/>',
  fan: '<path d="M10.827 16.379a6.082 6.082 0 0 1-8.618-7.002l5.412 1.45a6.082 6.082 0 0 1 7.002-8.618l-1.45 5.412a6.082 6.082 0 0 1 8.618 7.002l-5.412-1.45a6.082 6.082 0 0 1-7.002 8.618l1.45-5.412Z"/><path d="M12 12v.01"/>',
  fanoff: '<path d="M10.827 16.379a6.082 6.082 0 0 1-8.618-7.002l5.412 1.45a6.082 6.082 0 0 1 7.002-8.618l-1.45 5.412a6.082 6.082 0 0 1 8.618 7.002l-5.412-1.45a6.082 6.082 0 0 1-7.002 8.618l1.45-5.412Z"/><path d="m3 3 18 18"/>',
  chevright: '<path d="m9 18 6-6-6-6"/>',
  chevleft: '<path d="m15 18-6-6 6-6"/>',
  x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  battery: '<rect width="16" height="10" x="2" y="7" rx="2" ry="2"/><line x1="22" x2="22" y1="11" y2="13"/><line x1="6" x2="6" y1="11" y2="13"/><line x1="10" x2="10" y1="11" y2="13"/><line x1="14" x2="14" y1="11" y2="13"/>',
  batterylow: '<rect width="16" height="10" x="2" y="7" rx="2" ry="2"/><line x1="22" x2="22" y1="11" y2="13"/>',
  batterybolt: '<path d="M15 7h1a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2h-2"/><path d="M6 7H4a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h1"/><path d="m11 7-3 5h4l-3 5"/><path d="M22 11v2"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>',
  clock: '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
  road: '<path d="M4 19 8 5"/><path d="m16 5 4 14"/><path d="M12 6v2"/><path d="M12 11v2"/><path d="M12 16v2"/>',
  route: '<circle cx="6" cy="19" r="3"/><path d="M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15"/><circle cx="18" cy="5" r="3"/>',
  pin: '<path d="M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0"/><circle cx="12" cy="10" r="3"/>',
  pinoff: '<path d="M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0"/><path d="m3 3 18 18"/>',
  eye: '<path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"/><circle cx="12" cy="12" r="3"/>',
  eyeoff: '<path d="M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49"/><path d="M14.084 14.158a3 3 0 0 1-4.242-4.242"/><path d="M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143"/><path d="m2 2 20 20"/>',
  pause: '<rect x="14" y="4" width="4" height="16" rx="1"/><rect x="6" y="4" width="4" height="16" rx="1"/>',
  play: '<polygon points="6 3 20 12 6 21 6 3"/>',
  flag: '<path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"/><line x1="4" x2="4" y1="22" y2="15"/>',
  calendar: '<path d="M8 2v4"/><path d="M16 2v4"/><rect width="18" height="18" x="3" y="4" rx="2"/><path d="M3 10h18"/>',
  calendarclock: '<path d="M8 2v4"/><path d="M16 2v4"/><path d="M21 8.5V6a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h4"/><path d="M3 10h8"/><circle cx="16" cy="16" r="5.5"/><path d="M16 13.5V16l1.6 1"/>',
  ticket: '<path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z"/><path d="M13 5v2"/><path d="M13 17v2"/><path d="M13 11v2"/>',
  yen: '<circle cx="12" cy="12" r="10"/><path d="M12 12v5.5"/><path d="m8.5 7 3.5 5 3.5-5"/><path d="M9 12h6"/><path d="M9 15h6"/>',
  card: '<rect width="20" height="14" x="2" y="5" rx="2"/><line x1="2" x2="22" y1="10" y2="10"/>',
  checkcircle: '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>',
  circle: '<circle cx="12" cy="12" r="10"/>',
  pluscircle: '<circle cx="12" cy="12" r="10"/><path d="M8 12h8"/><path d="M12 8v8"/>',
  warn: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
  wifioff: '<path d="M12 20h.01"/><path d="M8.5 16.429a5 5 0 0 1 7 0"/><path d="M5 12.859a10 10 0 0 1 5.17-2.69"/><path d="M19 12.859a10 10 0 0 0-2.007-1.523"/><path d="M2 8.82a15 15 0 0 1 4.177-2.643"/><path d="M22 8.82a15 15 0 0 0-11.288-3.764"/><path d="m2 2 20 20"/>',
  bell: '<path d="M10.268 21a2 2 0 0 0 3.464 0"/><path d="M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
  gauge: '<path d="m12 14 4-4"/><path d="M3.34 19a10 10 0 1 1 17.32 0"/>',
  leaf: '<path d="M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.48 19 2c1 2 2 4.18 2 8 0 5.5-4.78 10-10 10Z"/><path d="M2 21c0-3 1.85-5.36 5.08-6C9.5 14.52 12 13 13 12"/>',
  search: '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
  list: '<path d="M3 12h.01"/><path d="M3 18h.01"/><path d="M3 6h.01"/><path d="M8 12h13"/><path d="M8 18h13"/><path d="M8 6h13"/>',
  listrect: '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M7 8h.01"/><path d="M11 8h6"/><path d="M7 12h.01"/><path d="M11 12h6"/><path d="M7 16h.01"/><path d="M11 16h6"/>',
  server: '<rect width="20" height="8" x="2" y="2" rx="2" ry="2"/><rect width="20" height="8" x="2" y="14" rx="2" ry="2"/><line x1="6" x2="6.01" y1="6" y2="6"/><line x1="6" x2="6.01" y1="18" y2="18"/>',
  wave: '<path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2"/>',
  scope: '<circle cx="12" cy="12" r="10"/><line x1="22" x2="18" y1="12" y2="12"/><line x1="6" x2="2" y1="12" y2="12"/><line x1="12" x2="12" y1="6" y2="2"/><line x1="12" x2="12" y1="22" y2="18"/>',
  arrowcircle: '<circle cx="12" cy="12" r="10"/><path d="M8 12h8"/><path d="m12 16 4-4-4-4"/>',
  locate: '<line x1="2" x2="5" y1="12" y2="12"/><line x1="19" x2="22" y1="12" y2="12"/><line x1="12" x2="12" y1="2" y2="5"/><line x1="12" x2="12" y1="19" y2="22"/><circle cx="12" cy="12" r="7"/><circle cx="12" cy="12" r="3"/>',
  hand: '<path d="M22 14a8 8 0 0 1-8 8"/><path d="M18 11v-1a2 2 0 0 0-2-2a2 2 0 0 0-2 2"/><path d="M14 10V9a2 2 0 0 0-2-2a2 2 0 0 0-2 2v1"/><path d="M10 9.5V4a2 2 0 0 0-2-2a2 2 0 0 0-2 2v10"/><path d="M18 11a2 2 0 1 1 4 0v3a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15"/>',
  info: '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>',
  expand: '<path d="m15 15 6 6"/><path d="m15 9 6-6"/><path d="M21 16v5h-5"/><path d="M21 8V3h-5"/><path d="M3 16v5h5"/><path d="m3 21 6-6"/><path d="M3 8V3h5"/><path d="M9 9 3 3"/>',
  minus: '<path d="M5 12h14"/>',
  downline: '<path d="M12 17V3"/><path d="m6 11 6 6 6-6"/><path d="M19 21H5"/>',
  upline: '<path d="M5 3h14"/><path d="m18 13-6-6-6 6"/><path d="M12 7v14"/>',
  forward: '<polygon points="13 19 22 12 13 5 13 19"/><polygon points="2 19 11 12 2 5 2 19"/>',
  gift: '<rect x="3" y="8" width="18" height="4" rx="1"/><path d="M12 8v13"/><path d="M19 12v7a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-7"/><path d="M7.5 8a2.5 2.5 0 0 1 0-5A4.8 8 0 0 1 12 8a4.8 8 0 0 1 4.5-5 2.5 2.5 0 0 1 0 5"/>',
  trash: '<path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/><line x1="10" x2="10" y1="11" y2="17"/><line x1="14" x2="14" y1="11" y2="17"/>',
  key: '<path d="m15.5 7.5 2.3 2.3a1 1 0 0 0 1.4 0l2.1-2.1a1 1 0 0 0 0-1.4L19 4"/><path d="m21 2-9.6 9.6"/><circle cx="7.5" cy="15.5" r="5.5"/>',
};
function icon(name, cls = '') {
  return `<svg class="ic ${cls}" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name] || ''}</svg>`;
}

/* ---------- 接口 ---------- */
class ApiError extends Error {
  constructor(message, extra = {}) {
    super(message);
    this.name = 'ApiError';
    this.status = extra.status ?? 0;
    this.code = extra.code ?? null;
    this.serverMessage = extra.serverMessage ?? null;
  }
}
const SERVER_CODE_TEXT = {
  vehicle_not_configured: '服务端尚未配置车辆信息。',
  station_template_not_configured: '服务端尚未配置换电站查询模板。',
  station_not_configured: '服务端尚未配置换电站轮询。',
  database_error: '后端数据库暂时不可用，请稍后重试。',
};
/**
 * 统一请求。路径相对当前页面（HA Ingress 前缀下也可用），密钥由加载项内的代理注入。
 * kind: 'control' | 'swap-order' 时使用与 App 一致的车控错误文案。
 */
async function api(path, { method = 'GET', body, timeout = 25000, kind = null } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  let resp;
  try {
    resp = await fetch(path, {
      method,
      headers: body === undefined ? { Accept: 'application/json' } : { Accept: 'application/json', 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: 'no-store',
      signal: controller.signal,
    });
  } catch (err) {
    throw new ApiError(err && err.name === 'AbortError' ? '请求超时，后端没有在规定时间内响应。' : '无法连接后端，请检查网络或加载项是否在运行。');
  } finally {
    clearTimeout(timer);
  }
  if (resp.status === 401) {
    if (kind === 'control') throw new ApiError('后端 API Key 或车控 Key 不正确。', { status: 401 });
    if (kind === 'swap-order') throw new ApiError('车控 Key 不正确，无法创建换电订单。', { status: 401 });
    throw new ApiError('HA 登录已过期或后端 API Key 不正确，请刷新页面后重试。', { status: 401 });
  }
  if (!resp.ok) {
    let envelope = null;
    try { envelope = await resp.json(); } catch (e) { envelope = null; }
    if (envelope && typeof envelope.error === 'string') {
      const code = envelope.error;
      const message = envelope.message || '';
      const extra = { status: resp.status, code, serverMessage: message };
      if (kind === 'control') {
        if (code === 'vehicle_control_disabled') throw new ApiError('服务端未启用车控。请在 HA 加载项配置中填写车控 Key 与证书后重启加载项。', extra);
        if (code === 'vehicle_pin_unavailable') throw new ApiError('服务端尚未配置可用的车辆 PIN，指令没有执行。', extra);
        if (code === 'vehicle_state_unsafe') throw new ApiError(`车辆当前状态不允许执行此指令：${message}`, extra);
        throw new ApiError(`HTTP ${resp.status} · ${code}：${message}`, extra);
      }
      if (kind === 'swap-order') throw new ApiError(`HTTP ${resp.status} · ${code}：${message}`, extra);
      throw new ApiError(SERVER_CODE_TEXT[code] || `${message}（HTTP ${resp.status} · ${code}）`, extra);
    }
    throw new ApiError(`后端请求失败（HTTP ${resp.status}）。`, { status: resp.status });
  }
  try {
    return await resp.json();
  } catch (e) {
    throw new ApiError('后端返回了无法识别的响应。', { status: resp.status });
  }
}
const errText = (err) => (err && err.message) || '未知错误';

/* ---------- 失败提示（APIErrorToast：顶部滑入，4 秒后自动消失） ---------- */
const Toast = {
  timer: null,
  el: null,
  show({ title, message, ok = false }) {
    const host = $('#toast-host');
    if (!host) return;
    if (this.el) { this.el.remove(); this.el = null; }
    clearTimeout(this.timer);
    const el = document.createElement('div');
    el.className = `toast${ok ? ' ok' : ''}`;
    el.setAttribute('role', 'status');
    el.innerHTML = `<div class="badge">${icon(ok ? 'check' : 'wifioff')}</div>
      <div class="body"><div class="t">${esc(title)}</div>${message ? `<div class="m lines3">${esc(message)}</div>` : ''}</div>
      <button class="close" aria-label="关闭提示">${icon('x')}</button>`;
    host.append(el);
    this.el = el;
    el.querySelector('.close').addEventListener('click', () => this.hide());
    reflow(el);
    el.classList.add('show');
    this.timer = setTimeout(() => this.hide(), 4000);
  },
  fail(message) {
    const text = String(message || '').trim();
    if (text) this.show({ title: '请求失败', message: text });
  },
  ok(title, message = '') { this.show({ title, message, ok: true }); },
  hide() {
    clearTimeout(this.timer);
    const el = this.el;
    if (!el) return;
    this.el = null;
    el.classList.remove('show');
    setTimeout(() => el.remove(), 260);
  },
};

/* ---------- Sheet（底部弹层，支持拖拽关闭与高度档位） ---------- */
const Overlays = { stack: [] };
/**
 * @param {{height?: number, large?: boolean, canExpand?: boolean, render: Function, onDismiss?: Function, dismissDisabled?: Function}} options
 * render(body, sheet) 负责填充内容；sheet.close() 关闭后回调 onDismiss（对应 SwiftUI 的 onDismiss）。
 */
function openSheet(options) {
  const host = appEl();
  const overlay = document.createElement('div');
  overlay.className = 'overlay';
  overlay.innerHTML = '<div class="backdrop"></div><div class="sheet" role="dialog" aria-modal="true"><div class="grabber-zone" data-drag><div class="grabber"></div></div><div class="sheet-body"></div></div>';
  const sheetEl = overlay.querySelector('.sheet');
  const body = overlay.querySelector('.sheet-body');
  const largeHeight = () => host.clientHeight - 12;
  let isLarge = !!options.large || !options.height;
  const baseHeight = () => (isLarge ? largeHeight() : Math.min(options.height, largeHeight()));
  const applyHeight = () => { sheetEl.style.height = `${baseHeight()}px`; };
  applyHeight();
  let closed = false;
  const sheet = {
    el: sheetEl,
    body,
    close() {
      if (closed) return;
      closed = true;
      overlay.classList.remove('show');
      sheetEl.style.transform = '';
      Overlays.stack = Overlays.stack.filter((item) => item !== sheet);
      window.removeEventListener('resize', applyHeight);
      setTimeout(() => {
        overlay.remove();
        if (options.onDismiss) options.onDismiss();
      }, 380);
    },
    tryDismiss() {
      if (options.dismissDisabled && options.dismissDisabled()) return;
      sheet.close();
    },
  };
  overlay.querySelector('.backdrop').addEventListener('click', () => sheet.tryDismiss());
  window.addEventListener('resize', applyHeight);

  // 拖拽：向下关闭，向上（存在更大档位时）展开为 large。
  let drag = null;
  const onDown = (e) => {
    if (!e.target.closest('[data-drag]')) return;
    if (e.target.closest('button, input, select, a')) return;
    drag = { y: e.clientY, t: performance.now(), dy: 0, h: sheetEl.clientHeight };
    sheetEl.classList.add('dragging');
    sheetEl.setPointerCapture(e.pointerId);
  };
  const onMove = (e) => {
    if (!drag) return;
    drag.dy = e.clientY - drag.y;
    if (drag.dy >= 0) {
      sheetEl.style.transform = `translateY(${drag.dy}px)`;
    } else if (!isLarge && options.canExpand !== false) {
      sheetEl.style.transform = '';
      sheetEl.style.height = `${Math.min(largeHeight(), drag.h - drag.dy)}px`;
    } else {
      sheetEl.style.transform = `translateY(${drag.dy / 6}px)`;
    }
  };
  const onUp = () => {
    if (!drag) return;
    const { dy } = drag;
    const velocity = dy / Math.max(1, performance.now() - drag.t);
    drag = null;
    sheetEl.classList.remove('dragging');
    if ((dy > 110 || velocity > 0.7) && !(options.dismissDisabled && options.dismissDisabled())) {
      sheet.close();
      sheetEl.style.transform = 'translateY(105%)';
      return;
    }
    sheetEl.style.transform = '';
    if (dy < -50 && !isLarge && options.canExpand !== false) isLarge = true;
    applyHeight();
  };
  sheetEl.addEventListener('pointerdown', onDown);
  sheetEl.addEventListener('pointermove', onMove);
  sheetEl.addEventListener('pointerup', onUp);
  sheetEl.addEventListener('pointercancel', onUp);

  host.append(overlay);
  options.render(body, sheet);
  Overlays.stack.push(sheet);
  reflow(overlay);
  overlay.classList.add('show');
  return sheet;
}

/** 系统风格 Alert。buttons: [{label, role?: 'cancel'|'destructive'}]，返回被点按钮的下标。 */
function showAlert({ title, message = '', buttons = [{ label: '知道了' }] }) {
  return new Promise((resolve) => {
    const wrap = document.createElement('div');
    wrap.className = 'alert-wrap';
    wrap.innerHTML = `<div class="backdrop"></div><div class="alert" role="alertdialog" aria-modal="true">
      <div class="at">${esc(title)}</div><div class="am">${esc(message)}</div>
      <div class="ab${buttons.length > 2 ? ' col' : ''}">${buttons.map((b, i) => `<button data-i="${i}" class="${b.role || ''}">${esc(b.label)}</button>`).join('')}</div></div>`;
    appEl().append(wrap);
    const done = (index) => {
      wrap.classList.remove('show');
      setTimeout(() => wrap.remove(), 220);
      resolve(index);
    };
    wrap.querySelectorAll('.ab button').forEach((btn) => btn.addEventListener('click', () => done(Number(btn.dataset.i))));
    reflow(wrap);
    wrap.classList.add('show');
  });
}

/** 工具栏菜单（Menu）。items: {label, icon, action, checked} 或 'divider'。 */
function showMenu(anchor, items) {
  const host = appEl();
  const layer = document.createElement('div');
  layer.className = 'overlay';
  layer.style.zIndex = 150;
  const menu = document.createElement('div');
  menu.className = 'menu';
  menu.setAttribute('role', 'menu');
  menu.innerHTML = items.map((item, i) => (item === 'divider'
    ? '<div class="gap"></div>'
    : `<button role="menuitem" data-i="${i}" class="${item.checked ? 'checked' : ''}"><span>${esc(item.label)}</span>${icon(item.checked ? 'check' : item.icon)}</button>`)).join('');
  layer.append(menu);
  host.append(layer);
  const hostRect = host.getBoundingClientRect();
  const rect = anchor.getBoundingClientRect();
  menu.style.top = `${rect.bottom - hostRect.top + 6}px`;
  menu.style.right = `${Math.max(10, hostRect.right - rect.right)}px`;
  const close = () => {
    menu.classList.remove('show');
    setTimeout(() => layer.remove(), 180);
  };
  layer.addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-i]');
    close();
    if (btn) {
      const item = items[Number(btn.dataset.i)];
      if (item && item.action) item.action();
    }
  });
  reflow(menu);
  menu.classList.add('show');
}

/* ---------- 分段控件 ---------- */
function segmented(el, options, value, onChange) {
  el.classList.add('segmented');
  el.innerHTML = `<div class="thumb"></div>${options.map((o) => `<button data-v="${esc(o.value)}">${esc(o.label)}</button>`).join('')}`;
  const thumb = el.querySelector('.thumb');
  thumb.style.width = `calc((100% - 4px) / ${options.length})`;
  const set = (v) => {
    const index = Math.max(0, options.findIndex((o) => String(o.value) === String(v)));
    thumb.style.transform = `translateX(${index * 100}%)`;
    el.querySelectorAll('button').forEach((b, i) => b.classList.toggle('active', i === index));
  };
  set(value);
  el.addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-v]');
    if (!btn || btn.classList.contains('active')) return;
    set(btn.dataset.v);
    onChange(btn.dataset.v);
  });
  return { set };
}

/* ---------- 导航：TabView + NavigationStack ---------- */
const Nav = {
  tabs: {},
  order: [],
  current: null,
  histDepth: 0,

  init(defs) {
    const host = appEl();
    const bar = $('#tabbar');
    for (const def of defs) {
      const view = document.createElement('div');
      view.className = 'tab-view';
      view.dataset.tab = def.id;
      host.insertBefore(view, bar);
      this.tabs[def.id] = { def, view, stack: [] };
      this.order.push(def.id);
      const btn = document.createElement('button');
      btn.dataset.tab = def.id;
      btn.innerHTML = `${icon(def.icon)}<span>${esc(def.label)}</span>`;
      btn.addEventListener('click', () => this.select(def.id, true));
      bar.append(btn);
      this._mount(def.id, def.root, false);
    }
    window.addEventListener('popstate', () => {
      this.histDepth = Math.max(0, this.histDepth - 1);
      let tab = this.current;
      if (this.tabs[tab].stack.length <= 1) tab = this.order.find((id) => this.tabs[id].stack.length > 1);
      if (tab) this._pop(tab, tab === this.current);
    });
    document.addEventListener('keydown', (e) => {
      if (e.key !== 'Escape') return;
      const top = Overlays.stack[Overlays.stack.length - 1];
      if (top) top.tryDismiss();
    });
  },

  top(tabId = this.current) {
    const stack = this.tabs[tabId].stack;
    return stack[stack.length - 1];
  },

  select(tabId, userTap = false) {
    if (this.current === tabId) {
      if (!userTap) return;
      // 再次点按当前标签：回到根页面，已在根页面则滚到顶部。
      const tab = this.tabs[tabId];
      if (tab.stack.length > 1) this.popToRoot(tabId);
      else tab.stack[0].scroll.scrollTo({ top: 0, behavior: 'smooth' });
      return;
    }
    const prev = this.current;
    if (prev) {
      this.tabs[prev].view.classList.remove('active');
      const page = this.top(prev);
      if (page && page.def.disappear) page.def.disappear(page);
      if (this.tabs[prev].def.onDeselect) this.tabs[prev].def.onDeselect();
    }
    this.current = tabId;
    this.tabs[tabId].view.classList.add('active');
    $$('#tabbar button').forEach((b) => b.classList.toggle('active', b.dataset.tab === tabId));
    if (this.tabs[tabId].def.onSelect) this.tabs[tabId].def.onSelect();
    const page = this.top(tabId);
    if (page && page.def.appear) page.def.appear(page);
    try { history.replaceState(history.state, '', `#${tabId}`); } catch (e) { /* ignore */ }
  },

  _mount(tabId, def, pushed) {
    const tab = this.tabs[tabId];
    const el = document.createElement('section');
    el.className = `nav-page${pushed ? ' pushed offscreen' : ''}`;
    const prevPage = tab.stack[tab.stack.length - 1];
    const backTitle = prevPage ? prevPage.def.title : '';
    el.innerHTML = `<header class="navbar">
        <div class="left">${pushed ? `<button class="nav-btn back" data-nav="back" aria-label="返回">${icon('chevleft')}<span>${esc(backTitle)}</span></button>` : ''}</div>
        <div class="title">${esc(def.title)}</div>
        <div class="right"></div>
      </header>
      <div class="scroll"><div class="ptr"><div class="spinner"></div></div><div class="content ${def.contentClass || ''}"></div></div>`;
    const page = {
      el, def, tabId,
      navbar: el.querySelector('.navbar'),
      scroll: el.querySelector('.scroll'),
      content: el.querySelector('.content'),
      toolbarEl: el.querySelector('.navbar .right'),
      state: {},
      cleanups: [],
      setTitle(text) { el.querySelector('.navbar .title').textContent = text; },
      setToolbar(html) { this.toolbarEl.innerHTML = html; },
      onCleanup(fn) { this.cleanups.push(fn); },
    };
    page.scroll.addEventListener('scroll', () => page.navbar.classList.toggle('scrolled', page.scroll.scrollTop > 2), { passive: true });
    if (pushed) {
      el.querySelector('[data-nav="back"]').addEventListener('click', () => this.pop());
      attachEdgeSwipe(page);
    }
    if (def.refresh) attachPullToRefresh(page);
    tab.view.append(el);
    tab.stack.push(page);
    def.build(page);
    return page;
  },

  push(def, tabId = this.current) {
    const tab = this.tabs[tabId];
    const prev = this.top(tabId);
    const page = this._mount(tabId, def, true);
    if (prev && prev.def.disappear) prev.def.disappear(prev);
    this.histDepth += 1;
    try { history.pushState({ nio: this.histDepth }, '', location.href); } catch (e) { this.histDepth -= 1; }
    reflow(page.el);
    page.el.classList.add('anim');
    page.el.classList.remove('offscreen');
    if (prev) { prev.el.classList.add('anim', 'under'); }
    setTimeout(() => {
      page.el.classList.remove('anim');
      if (prev) {
        prev.el.classList.remove('anim');
        if (tab.stack[tab.stack.length - 1] === page) prev.el.style.visibility = 'hidden';
      }
      if (def.appear && tab.stack.includes(page)) def.appear(page);
    }, 380);
    return page;
  },

  /** 用户触发的返回：有历史记录时交给 history.back()，由 popstate 统一出栈。 */
  pop() {
    if (this.tabs[this.current].stack.length <= 1) return;
    if (this.histDepth > 0) history.back();
    else this._pop(this.current, true);
  },

  popToRoot(tabId) {
    const tab = this.tabs[tabId];
    const depth = tab.stack.length - 1;
    if (depth < 1) return;
    // 中间页直接移除，只保留最上层做一次返回动画。
    while (tab.stack.length > 2) {
      const [page] = tab.stack.splice(1, 1);
      page.cleanups.forEach((fn) => fn());
      page.el.remove();
    }
    tab.stack[0].el.style.visibility = '';
    const steps = Math.min(depth, this.histDepth);
    if (steps > 0) {
      // history.go(-n) 只触发一次 popstate，由它完成最后一次出栈。
      this.histDepth -= steps - 1;
      history.go(-steps);
    } else {
      this._pop(tabId, true);
    }
  },

  _pop(tabId, animated) {
    const tab = this.tabs[tabId];
    if (tab.stack.length <= 1) return;
    const page = tab.stack.pop();
    const prev = tab.stack[tab.stack.length - 1];
    if (page.def.disappear) page.def.disappear(page);
    page.cleanups.forEach((fn) => fn());
    prev.el.style.visibility = '';
    const finish = () => {
      page.el.remove();
      prev.el.classList.remove('anim', 'under');
      prev.el.style.transform = '';
      prev.el.style.opacity = '';
      if (prev.def.appear && this.current === tabId) prev.def.appear(prev);
    };
    if (!animated) { finish(); return; }
    reflow(page.el);
    page.el.classList.add('anim');
    prev.el.classList.add('anim');
    page.el.style.transform = '';
    page.el.classList.add('offscreen');
    prev.el.style.transform = '';
    prev.el.style.opacity = '';
    prev.el.classList.remove('under');
    setTimeout(finish, 380);
  },
};

/** 左缘右滑返回（NavigationStack 的交互式返回手势）。 */
function attachEdgeSwipe(page) {
  let track = null;
  const prevOf = () => {
    const stack = Nav.tabs[page.tabId].stack;
    return stack[stack.indexOf(page) - 1];
  };
  page.el.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 1) return;
    const touch = e.touches[0];
    const left = page.el.getBoundingClientRect().left;
    if (touch.clientX - left > 26) return;
    if (Nav.top(page.tabId) !== page) return;
    track = { x: touch.clientX, y: touch.clientY, t: performance.now(), dx: 0, active: false };
  }, { passive: true });
  page.el.addEventListener('touchmove', (e) => {
    if (!track) return;
    const touch = e.touches[0];
    const dx = touch.clientX - track.x;
    const dy = touch.clientY - track.y;
    if (!track.active) {
      if (Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > 8) { track = null; return; }
      if (dx < 10) return;
      track.active = true;
      const prev = prevOf();
      if (prev) { prev.el.style.visibility = ''; prev.el.classList.remove('anim'); }
      page.el.classList.remove('anim');
    }
    e.preventDefault();
    track.dx = Math.max(0, dx);
    const width = page.el.clientWidth;
    const progress = clamp(track.dx / width, 0, 1);
    page.el.style.transform = `translateX(${track.dx}px)`;
    const prev = prevOf();
    if (prev) {
      prev.el.style.transform = `translateX(${-28 * (1 - progress)}%)`;
      prev.el.style.opacity = String(0.6 + 0.4 * progress);
    }
  }, { passive: false });
  const end = () => {
    if (!track) return;
    const { dx, active, t } = track;
    track = null;
    if (!active) return;
    const width = page.el.clientWidth;
    const velocity = dx / Math.max(1, performance.now() - t);
    if (dx > width * 0.35 || velocity > 0.6) {
      Nav.pop();
    } else {
      const prev = prevOf();
      page.el.classList.add('anim');
      page.el.style.transform = '';
      if (prev) {
        prev.el.classList.add('anim');
        prev.el.style.transform = '';
        prev.el.style.opacity = '';
        setTimeout(() => { if (Nav.top(page.tabId) === page) prev.el.style.visibility = 'hidden'; }, 380);
      }
      setTimeout(() => page.el.classList.remove('anim'), 380);
    }
  };
  page.el.addEventListener('touchend', end);
  page.el.addEventListener('touchcancel', end);
}

/** 下拉刷新（.refreshable）。 */
function attachPullToRefresh(page) {
  const { scroll } = page;
  const ptr = page.el.querySelector('.ptr');
  const spinner = ptr.querySelector('.spinner');
  let start = null;
  let pulling = false;
  let dist = 0;
  let busy = false;
  const settle = (height) => {
    ptr.classList.add('anim');
    ptr.style.height = `${height}px`;
  };
  scroll.addEventListener('touchstart', (e) => {
    if (busy || e.touches.length !== 1 || scroll.scrollTop > 0) { start = null; return; }
    start = { x: e.touches[0].clientX, y: e.touches[0].clientY };
    pulling = false;
    dist = 0;
  }, { passive: true });
  scroll.addEventListener('touchmove', (e) => {
    if (!start || busy) return;
    const dy = e.touches[0].clientY - start.y;
    const dx = e.touches[0].clientX - start.x;
    if (!pulling) {
      if (dy < 8 || Math.abs(dx) > dy || scroll.scrollTop > 0) return;
      pulling = true;
      ptr.classList.remove('anim');
      spinner.style.animationPlayState = 'paused';
    }
    if (e.cancelable) e.preventDefault();
    dist = Math.min(130, Math.max(0, dy) * 0.5);
    ptr.style.height = `${dist}px`;
    spinner.style.opacity = String(clamp(dist / 60, 0.2, 1));
    spinner.style.transform = `rotate(${dist * 5}deg)`;
  }, { passive: false });
  const end = () => {
    if (!pulling) { start = null; return; }
    pulling = false;
    start = null;
    spinner.style.transform = '';
    spinner.style.opacity = '';
    spinner.style.animationPlayState = '';
    if (dist >= 60) {
      busy = true;
      settle(52);
      Promise.resolve()
        .then(() => page.def.refresh(page))
        .catch(() => {})
        .finally(() => { busy = false; settle(0); });
    } else {
      settle(0);
    }
  };
  scroll.addEventListener('touchend', end);
  scroll.addEventListener('touchcancel', end);
}

/* ---------- Leaflet（按需加载，不阻塞首屏） ---------- */
let leafletPromise = null;
function loadLeaflet() {
  if (window.L) return Promise.resolve(window.L);
  if (leafletPromise) return leafletPromise;
  leafletPromise = new Promise((resolve, reject) => {
    const css = document.createElement('link');
    css.rel = 'stylesheet';
    css.href = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css';
    document.head.append(css);
    const script = document.createElement('script');
    script.src = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js';
    script.onload = () => (window.L ? resolve(window.L) : reject(new Error('leaflet')));
    script.onerror = () => { leafletPromise = null; reject(new Error('leaflet')); };
    document.head.append(script);
  });
  return leafletPromise;
}

/** 事件委托：容器内 [data-act] 点击 → handlers[act](el, event)。 */
function delegate(root, handlers) {
  root.addEventListener('click', (e) => {
    const target = e.target.closest('[data-act]');
    if (!target || !root.contains(target) || target.disabled) return;
    const handler = handlers[target.dataset.act];
    if (handler) handler(target, e);
  });
}

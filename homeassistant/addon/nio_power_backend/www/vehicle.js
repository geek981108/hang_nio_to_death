'use strict';
/* 车辆页：对应 App 的 VehicleViewModel / VehicleDetailView / VehiclePathMap / VehiclePathBuilder。 */

/* ---------- 车控动作定义（VehicleAction） ---------- */
const VEHICLE_ACTIONS = {
  'unlock-doors': { confirmation: 'UNLOCK DOORS', title: '仅解锁车门', icon: 'unlock', accent: '--sys-red', fill: '#d92e38', highRisk: true },
  'unlock-start': { confirmation: 'UNLOCK AND START', title: '解锁并启动', icon: 'car', accent: '--sys-red', fill: '#d92e38', highRisk: true },
  lock: { confirmation: 'LOCK VEHICLE', title: '锁定车辆', icon: 'lock', accent: '--green', fill: '#307a57' },
  'guard-on': { confirmation: 'ENABLE GUARD MODE', title: '开启守卫模式', icon: 'shield', accent: '--violet', fill: '#7d6ea6' },
  'guard-off': { confirmation: 'DISABLE GUARD MODE', title: '关闭守卫模式', icon: 'shieldoff', accent: '--violet', fill: '#7d6ea6' },
  find: { confirmation: 'FIND VEHICLE', title: '开始寻车', icon: 'horn', accent: '--amber', fill: '#a6612b' },
  'find-stop': { confirmation: 'STOP FINDING', title: '停止寻车', icon: 'mute', accent: '--amber', fill: '#a6612b' },
  'ac-on': { confirmation: 'START AC', title: '开启空调', icon: 'fan', accent: '--blue', fill: '#476ea8' },
  'ac-off': { confirmation: 'STOP AC', title: '关闭空调', icon: 'fanoff', accent: '--blue', fill: '#476ea8' },
};

/* ---------- 轨迹切段（VehiclePathBuilder，参数与 App 完全一致） ---------- */
const PathBuilder = {
  samePlaceRadius: 80,
  stationarySplit: 15 * 60 * 1000,
  driftRadius: 150,
  driftInterval: 20 * 60 * 1000,
  missingSplit: 30 * 60 * 1000,

  dist(a, b) { return haversineMeters(a.lat, a.lon, b.lat, b.lon); },

  buildDailyPaths(history) {
    const groups = new Map();
    for (const p of history) {
      if (!validCoord(p.lat, p.lon)) continue;
      const day = startOfDay(new Date(p.t)).getTime();
      if (!groups.has(day)) groups.set(day, []);
      groups.get(day).push(p);
    }
    const paths = [];
    for (const [day, raw] of groups) {
      const sorted = raw.slice().sort((a, b) => a.t - b.t);
      if (!sorted.length) continue;
      const segments = this.buildSegments(sorted);
      const points = segments.length ? segments.flatMap((s) => s.points) : this.simplify(sorted);
      paths.push({
        day,
        points,
        segments,
        distanceKm: segments.reduce((sum, s) => sum + s.distanceKm, 0),
        startTime: segments.length ? segments[0].startTime : (this.movementStartTime(sorted) ?? sorted[0].t),
        endTime: segments.length ? segments[segments.length - 1].endTime : sorted[sorted.length - 1].t,
      });
    }
    return paths.sort((a, b) => b.day - a.day);
  },

  buildSegments(sorted) {
    if (!sorted.length) return [];
    // 先按采样缺口分批：缺失数据不能连成一条线。
    const batches = [];
    let batch = [];
    for (const point of sorted) {
      const prev = batch[batch.length - 1];
      if (prev && point.t - prev.t >= this.missingSplit) { batches.push(batch); batch = []; }
      batch.push(point);
    }
    if (batch.length) batches.push(batch);

    const segments = [];
    for (const samples of batches) {
      let start = 0;
      let index = 0;
      while (index < samples.length - 1) {
        const nextParked = this.firstOutside(samples, index, this.samePlaceRadius);
        const nextDrift = this.firstOutside(samples, index, this.driftRadius);
        const parked = samples[nextParked - 1].t - samples[index].t;
        const drift = samples[nextDrift - 1].t - samples[index].t;
        let stopEnd = null;
        if (drift >= this.driftInterval) stopEnd = nextDrift - 1;
        else if (parked >= this.stationarySplit) stopEnd = nextParked - 1;
        if (stopEnd != null) {
          const segment = this.movementSegment(samples.slice(start, index + 1));
          if (segment) segments.push(segment);
          // 最后一个驻车点作为下一段的出发锚点，长时间静止不计入里程。
          start = stopEnd;
          index = stopEnd;
        } else {
          index = nextParked < samples.length ? nextParked : samples.length - 1;
        }
      }
      const segment = this.movementSegment(samples.slice(start));
      if (segment) segments.push(segment);
    }
    return segments;
  },

  firstOutside(samples, start, radius) {
    let index = start + 1;
    while (index < samples.length && this.dist(samples[start], samples[index]) < radius) index += 1;
    return index;
  },

  movementSegment(samples) {
    if (!samples.length) return null;
    const first = samples[0];
    const last = samples[samples.length - 1];
    if (last.t - first.t >= this.driftInterval) {
      let minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon;
      for (const p of samples) {
        minLat = Math.min(minLat, p.lat); maxLat = Math.max(maxLat, p.lat);
        minLon = Math.min(minLon, p.lon); maxLon = Math.max(maxLon, p.lon);
      }
      if (haversineMeters(minLat, minLon, maxLat, maxLon) <= this.driftRadius) return null;
    }
    const points = this.simplify(samples);
    if (points.length <= 1) return null;
    if (points[points.length - 1] !== last) points.push(last);
    let meters = 0;
    for (let i = 1; i < points.length; i++) meters += this.dist(points[i - 1], points[i]);
    const startTime = this.movementStartTime(samples) ?? first.t;
    return { id: `${first.vehicleID}:${startTime / 1000}:${last.t / 1000}`, points, distanceKm: meters / 1000, startTime, endTime: last.t };
  },

  simplify(points) {
    if (points.length <= 1) return points.slice();
    const sorted = points.slice().sort((a, b) => a.t - b.t);
    const result = [sorted[0]];
    for (let i = 1; i < sorted.length; i++) {
      if (this.dist(result[result.length - 1], sorted[i]) >= this.samePlaceRadius) result.push(sorted[i]);
    }
    return result;
  },

  /** 以仍在初始驻车范围内的最后一个采样作为出发时间。 */
  movementStartTime(sorted) {
    if (!sorted.length) return null;
    const origin = sorted[0];
    for (let i = 1; i < sorted.length; i++) {
      if (this.dist(origin, sorted[i]) >= this.samePlaceRadius) return sorted[i - 1].t;
    }
    return origin.t;
  },
};

/* ---------- 数据模型（VehicleViewModel） ---------- */
const Vehicle = {
  cacheKey: 'nio.cachedVehicleDashboard.v1',
  s: {
    dashboard: null, history: [], dailyPaths: [], trips: [], sessions: [], swaps: [], orders: [], samples: [],
    loading: false, loadedOnce: false, cached: false, lastRefreshAt: null, profile: null, defaultBatteryType: null,
    performing: false, controlConfigured: true, creatingOrder: false, lastOrderOutcome: null,
    err: { main: null, history: null, trips: null, charging: null, sessions: null, swaps: null, orders: null },
  },
  subs: new Set(),
  refreshing: null,
  lastArchiveAt: 0,
  monitorToken: 0,
  didInitialLoad: false,

  on(fn) { this.subs.add(fn); return () => this.subs.delete(fn); },
  emit(...keys) { const set = new Set(keys); this.subs.forEach((fn) => { try { fn(set); } catch (e) { console.error(e); } }); },
  /** 设置分区错误；非空时同时弹出失败 Toast（对应 failureNotice）。 */
  setErr(key, message) {
    this.s.err[key] = message || null;
    if (message) Toast.fail(message);
    this.emit('errors');
  },

  prepareInitialDisplay() {
    const entry = Store.get(this.cacheKey);
    if (entry && entry.schemaVersion === 1 && entry.dashboard) {
      this.s.dashboard = entry.dashboard;
      this.s.lastRefreshAt = entry.savedAt;
      this.s.cached = true;
    }
  },

  async loadUIConfig() {
    try {
      const cfg = await api('ui-config', { timeout: 8000 });
      this.s.controlConfigured = cfg.control_configured !== false;
      this.s.defaultBatteryType = cfg.default_battery_type || null;
    } catch (e) {
      this.s.controlConfigured = true; // 旧版代理没有该接口：按已配置处理，由后端返回真实错误。
    }
    this.emit('config');
  },

  /** 车辆资料（昵称 / 车型 / 车色 / 官方车图），来自后端缓存的 switch/cars 数据。 */
  async loadProfile() {
    try {
      this.s.profile = await api('api/v1/vehicle/profile');
    } catch (e) {
      if (!this.s.profile) this.s.profile = { image_available: false };
    }
    this.emit('profile');
  },

  /** 与 App 的 VehicleProfile.displayTitle 一致：昵称 → NIO <车型> → 我的蔚来。 */
  title() {
    const p = this.s.profile || {};
    const name = (p.display_name || '').trim();
    if (name) return name;
    const model = (p.model_type || '').trim();
    return model ? `NIO ${model}` : '我的蔚来';
  },
  /** 与 App 的 VehicleProfile.localizedColorName 一致；未收录的代码原样显示。 */
  colorLabel() {
    const color = ((this.s.profile || {}).color || '').trim();
    if (!color) return null;
    const names = {
      tech_grey: '星灰', tech_gray: '星灰', star_grey: '星灰', star_gray: '星灰',
      white: '云白', cloud_white: '云白', black: '深空黑', deep_black: '深空黑',
      blue: '蓝色', red: '红色', silver: '银色', grey: '灰色', gray: '灰色',
    };
    return names[color.toLowerCase().replace(/-/g, '_')] || color;
  },

  async fetchDashboard() {
    const [status, widget] = await Promise.all([api('api/v1/vehicle/status'), api('api/v1/vehicle/widget-info')]);
    return this.makeDashboard(status, widget);
  },

  makeDashboard(status, widget) {
    if (status.result_code !== 'success') throw new ApiError(`NIO 上游返回失败状态：${status.result_code}。`);
    if (widget.result_code !== 'success') throw new ApiError(`NIO 上游返回失败状态：${widget.result_code}。`);
    const sd = status.data || {};
    const ws = (widget.data && widget.data.status) || {};
    if (sd.vehicle_id !== ws.vehicle_id) throw new ApiError('车辆状态接口返回了不一致的车辆标识。');
    const sSoc = sd.soc_status || {};
    const wSoc = ws.soc_status || {};
    const pos = sd.position_status || {};
    const pick = (key) => (sSoc[key] ?? wSoc[key] ?? null);
    const int = (v) => (v == null ? null : Math.round(Number(v)));
    const ms = (v) => { const d = parseDate(v); return d ? d.getTime() : null; };
    const limit = sSoc.max_soc_enable_on_vehl === true ? sSoc.max_soc
      : (wSoc.max_soc_enable_on_vehl === true ? wSoc.max_soc : null);
    return {
      vehicleID: sd.vehicle_id,
      isConnected: (sd.connection_status || {}).connected ?? (ws.connection_status || {}).connected ?? false,
      stateCode: int((sd.exterior_status || {}).vehicle_state ?? (ws.exterior_status || {}).vehicle_state),
      mileage: (sd.exterior_status || {}).mileage ?? (ws.exterior_status || {}).mileage ?? null,
      isSwapping: Number((sd.special_status || {}).swapping ?? (ws.special_status || {}).swapping ?? 0) !== 0,
      stateOfCharge: pick('soc'),
      remainingRange: pick('remaining_range'),
      remainingActualRange: pick('remaining_actual_range'),
      chargeStateCode: int(pick('charge_state')),
      chargingCurrent: pick('charging_current'),
      chargingPower: pick('charging_power'),
      chargingVoltage: pick('charging_voltage'),
      chargeLimitPercent: limit ?? null,
      batterySampledAt: ms(sSoc.sample_time ?? wSoc.sample_time),
      lockStatusCode: int((ws.door_status || {}).vehicle_lock_status),
      location: validCoord(pos.latitude, pos.longitude) ? { lat: pos.latitude, lon: pos.longitude } : null,
      locationSampledAt: ms(pos.sample_time),
      insideTemperature: (sd.hvac_status || {}).temperature ?? null,
      outsideTemperature: (sd.hvac_status || {}).outside_temperature ?? null,
      checkedIn: (widget.data && widget.data.checked_in) || null,
      updatedAt: Date.now(),
    };
  },

  sameDisplayed(a, b) {
    if (!a || !b) return false;
    const strip = (d) => JSON.stringify({ ...d, updatedAt: 0 });
    return strip(a) === strip(b);
  },

  updateDashboard(next) {
    const s = this.s;
    const wasCached = s.cached;
    s.cached = false;
    s.lastRefreshAt = next.updatedAt;
    Store.set(this.cacheKey, { schemaVersion: 1, savedAt: next.updatedAt, dashboard: next });
    if (s.err.main) { s.err.main = null; this.emit('errors'); }
    if (this.sameDisplayed(s.dashboard, next)) {
      if (wasCached) this.emit('cached');
      return;
    }
    s.dashboard = next;
    this.emit('dashboard', 'cached');
  },

  updateOrders(items) {
    const s = this.s;
    if (s.err.orders) { s.err.orders = null; this.emit('errors'); }
    const strip = (list) => JSON.stringify(list.map((o) => ({ ...o, queue_updated_at: 0, first_seen_at: 0, last_seen_at: 0 })));
    if (strip(s.orders) === strip(items)) return;
    s.orders = items;
    this.emit('orders');
    if (typeof QueueNotify !== 'undefined') QueueNotify.sync(items);
  },

  mapHistory(page) {
    return (page.items || []).map((it) => {
      const d = parseDate(it.sampled_at);
      return d ? { vehicleID: it.vehicle_id, t: d.getTime(), lat: it.latitude, lon: it.longitude } : null;
    }).filter(Boolean);
  },

  /** 一个分区的请求：成功即应用，失败写入对应错误。 */
  async part(errKey, request, apply) {
    try {
      apply(await request());
    } catch (err) {
      this.setErr(errKey, errText(err));
    }
  },

  archiveParts() {
    const s = this.s;
    return [
      this.part('history', () => api('api/v1/vehicle/history?limit=2000', { timeout: 40000 }), (page) => {
        s.history = this.mapHistory(page);
        s.dailyPaths = PathBuilder.buildDailyPaths(s.history);
        this.emit('history');
      }),
      this.part('trips', () => api('api/v1/vehicle/trips?count=20'), (page) => { s.trips = page.items || []; this.emit('trips'); }),
      this.part('sessions', () => api('api/v1/vehicle/charging/sessions?limit=50'), (page) => { s.sessions = page.items || []; this.emit('sessions'); }),
      this.part('swaps', () => api('api/v1/swaps?limit=100'), (page) => { s.swaps = page.items || []; this.emit('swaps'); }),
    ];
  },

  /** 完整刷新（下拉刷新 / 工具栏刷新 / 首次进入）。 */
  refresh() {
    if (this.refreshing) return this.refreshing;
    const s = this.s;
    s.loading = true;
    Object.assign(s.err, { main: null, history: null, trips: null, sessions: null, swaps: null, orders: null });
    this.emit('loading', 'errors');
    const tasks = [
      this.part('main', () => this.fetchDashboard(), (d) => this.updateDashboard(d)),
      this.part('orders', () => api('api/v1/orders/active'), (page) => this.updateOrders(page.items || [])),
      ...this.archiveParts(),
    ];
    this.refreshing = Promise.all(tasks).finally(() => {
      this.refreshing = null;
      s.loading = false;
      s.loadedOnce = true;
      this.lastArchiveAt = Date.now();
      this.emit('loading');
    });
    return this.refreshing;
  },

  async refreshLiveData() {
    if (this.refreshing) return this.refreshing;
    await Promise.all([
      this.part('main', () => this.fetchDashboard(), (d) => this.updateDashboard(d)),
      this.part('orders', () => api('api/v1/orders/active'), (page) => this.updateOrders(page.items || [])),
    ]);
    return undefined;
  },

  async refreshArchiveData() {
    if (this.refreshing) return this.refreshing;
    await Promise.all(this.archiveParts());
    return undefined;
  },

  async refreshDashboardOnly() {
    await this.part('main', () => this.fetchDashboard(), (d) => this.updateDashboard(d));
  },

  async refreshSwapEvents() {
    const s = this.s;
    s.err.swaps = null; s.err.orders = null;
    await Promise.all([
      this.part('swaps', () => api('api/v1/swaps?limit=100'), (page) => { s.swaps = page.items || []; this.emit('swaps'); }),
      this.part('orders', () => api('api/v1/orders/active'), (page) => this.updateOrders(page.items || [])),
    ]);
  },

  async refreshChargingSessions() {
    const s = this.s;
    s.err.sessions = null;
    await this.part('sessions', () => api('api/v1/vehicle/charging/sessions?limit=50'), (page) => { s.sessions = page.items || []; this.emit('sessions'); });
  },

  async refreshChargingData() {
    const s = this.s;
    s.err.charging = null;
    await this.part('charging', () => api('api/v1/vehicle/charging/current'), (page) => { s.samples = page.items || []; this.emit('samples'); });
  },

  /** VehicleAutoRefreshPolicy：有进行中订单 / 充电 / 换电时 15 秒，否则 60 秒；归档数据每 10 分钟。 */
  liveInterval() {
    const d = this.s.dashboard;
    return (this.s.orders.length || (d && d.chargeStateCode === 1) || (d && d.isSwapping)) ? 15000 : 60000;
  },

  startMonitor() {
    const token = ++this.monitorToken;
    const loop = async () => {
      while (token === this.monitorToken) {
        await sleep(this.liveInterval());
        if (token !== this.monitorToken || document.hidden) return;
        await this.refreshLiveData();
        if (token !== this.monitorToken) return;
        if (Date.now() - this.lastArchiveAt >= 10 * 60 * 1000) {
          await this.refreshArchiveData();
          this.lastArchiveAt = Date.now();
        }
      }
    };
    loop();
  },
  stopMonitor() { this.monitorToken += 1; },

  /** 页面进入前台（scenePhase == .active）。 */
  async activate() {
    if (document.hidden) return;
    if (!this.didInitialLoad) {
      this.didInitialLoad = true;
      this.prepareInitialDisplay();
      this.emit('dashboard', 'cached');
      this.loadUIConfig();
      this.loadProfile();
      await this.refresh();
    } else {
      await this.refreshLiveData();
    }
    this.startMonitor();
  },

  currentCoordinate() {
    const d = this.s.dashboard;
    if (d && d.location) return d.location;
    const first = this.s.history.find((p) => validCoord(p.lat, p.lon));
    return first ? { lat: first.lat, lon: first.lon } : null;
  },

  /** 发送一条车控指令：不自动重试；返回后只做一次只读刷新。 */
  async performAction(pending) {
    if (this.s.performing) throw new ApiError('已有一条车控指令正在执行，请稍候。');
    const def = VEHICLE_ACTIONS[pending.action];
    const body = { action: pending.action, confirmation: def.confirmation, expand_mirrors: !!pending.expandMirrors };
    if (pending.action === 'ac-on' && isNum(pending.temperature)) body.temperature = pending.temperature;
    if (pending.expandMirrors) body.mirror_confirmation = 'EXPAND MIRRORS';
    this.s.performing = true;
    this.emit('performing');
    try {
      const outcome = await api('api/v1/vehicle/action', { method: 'POST', body, timeout: 90000, kind: 'control' });
      await sleep(1000);
      await this.refreshDashboardOnly();
      return outcome;
    } finally {
      this.s.performing = false;
      this.emit('performing');
    }
  },

  async createSwapOrder(stationID) {
    if (this.s.creatingOrder) throw new ApiError('换电订单正在创建，请勿重复提交。');
    this.s.creatingOrder = true;
    this.emit('order');
    try {
      const outcome = await api('api/v1/swap-orders', {
        method: 'POST', body: { station_id: stationID, confirmation: 'CREATE SWAP ORDER' }, timeout: 90000, kind: 'swap-order',
      });
      this.s.lastOrderOutcome = outcome;
      this.refresh();
      return outcome;
    } catch (err) {
      Toast.fail(errText(err));
      throw err;
    } finally {
      this.s.creatingOrder = false;
      this.emit('order');
    }
  },
};

/* ---------- 地图（VehiclePathMap） ---------- */
const SEGMENT_COLORS = ['--blue', '--amber', '--violet', '--green', '--sys-pink', '--sys-teal'];
const segmentColorVar = (index) => SEGMENT_COLORS[index % SEGMENT_COLORS.length];

function createPathMap(holder) {
  const lf = holder.querySelector('.lf');
  let map = null;
  let group = null;
  let state = { segments: [], visibleIDs: new Set(), samplePoint: null, current: null, key: '' };
  let fitKey = null;
  let pendingFit = false;

  const allCoords = () => {
    const out = [];
    state.segments.forEach((seg) => { if (state.visibleIDs.has(seg.id)) seg.points.forEach((p) => out.push([p.lat, p.lon])); });
    if (state.samplePoint) out.push([state.samplePoint.lat, state.samplePoint.lon]);
    if (state.current) out.push([state.current.lat, state.current.lon]);
    return out;
  };
  // 与 App 相同的取景：包围盒居中，跨度至少 0.008°，再放大 1.35 倍。
  const fullBounds = () => {
    const coords = allCoords();
    if (!coords.length) return [[31.2304 - 0.05, 121.4737 - 0.05], [31.2304 + 0.05, 121.4737 + 0.05]];
    let minLat = coords[0][0], maxLat = coords[0][0], minLon = coords[0][1], maxLon = coords[0][1];
    for (const [lat, lon] of coords) {
      minLat = Math.min(minLat, lat); maxLat = Math.max(maxLat, lat);
      minLon = Math.min(minLon, lon); maxLon = Math.max(maxLon, lon);
    }
    const cLat = (minLat + maxLat) / 2;
    const cLon = (minLon + maxLon) / 2;
    const dLat = Math.max(maxLat - minLat, 0.008) * 1.35;
    const dLon = Math.max(maxLon - minLon, 0.008) * 1.35;
    return [[cLat - dLat / 2, cLon - dLon / 2], [cLat + dLat / 2, cLon + dLon / 2]];
  };
  const recenterBounds = () => {
    const c = state.current;
    if (!c) return fullBounds();
    return [[c.lat - 0.004, c.lon - 0.004], [c.lat + 0.004, c.lon + 0.004]];
  };
  const fit = (bounds, animate) => {
    if (!map) return;
    if (!lf.clientWidth || !lf.clientHeight) { pendingFit = true; return; }
    pendingFit = false;
    map.invalidateSize(false);
    map.fitBounds(bounds, { animate, duration: 0.3, padding: [0, 0] });
  };
  const dot = (L, latlng, colorVar, iconName, title) => L.marker(latlng, {
    title,
    keyboard: false,
    icon: L.divIcon({
      className: 'map-dot-wrap',
      html: `<div class="map-dot" style="background:${cssVar(colorVar)}">${icon(iconName, iconName === 'play' || iconName === 'flag' ? 'fill' : '')}</div>`,
      iconSize: [28, 28],
      iconAnchor: [14, 14],
    }),
  });
  const draw = (L) => {
    group.clearLayers();
    state.segments.forEach((seg, index) => {
      if (!state.visibleIDs.has(seg.id)) return;
      const colorVar = segmentColorVar(index);
      const latlngs = seg.points.map((p) => [p.lat, p.lon]);
      if (latlngs.length >= 2) L.polyline(latlngs, { color: cssVar(colorVar), weight: 4, opacity: 1, lineJoin: 'round', lineCap: 'round' }).addTo(group);
      if (latlngs.length) {
        dot(L, latlngs[0], colorVar, 'play', `第${index + 1}段起点`).addTo(group);
        dot(L, latlngs[latlngs.length - 1], colorVar, 'flag', `第${index + 1}段终点`).addTo(group);
      }
    });
    if (state.samplePoint) dot(L, [state.samplePoint.lat, state.samplePoint.lon], '--violet', 'pin', '采样点').addTo(group);
    if (state.current) dot(L, [state.current.lat, state.current.lon], '--violet', 'car', '当前位置').addTo(group);
  };
  const ensure = (L) => {
    if (map) return;
    map = L.map(lf, { zoomControl: false, attributionControl: true, zoomSnap: 0.25, scrollWheelZoom: false });
    map.attributionControl.setPrefix(false);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map);
    group = L.layerGroup().addTo(map);
    if (window.ResizeObserver) {
      new ResizeObserver(() => {
        if (!lf.clientWidth) return;
        map.invalidateSize(false);
        if (pendingFit) fit(fullBounds(), false);
      }).observe(lf);
    }
    const recenter = holder.querySelector('.recenter');
    if (recenter) recenter.addEventListener('click', () => fit(recenterBounds(), true));
    document.addEventListener('themechange', () => draw(L));
  };

  return {
    update(next) {
      state = { ...state, ...next };
      loadLeaflet().then((L) => {
        ensure(L);
        draw(L);
        const key = `${state.key}|${Array.from(state.visibleIDs).sort().join(',')}`;
        if (key !== fitKey) { fitKey = key; fit(fullBounds(), false); }
      }).catch(() => {
        if (!holder.querySelector('.fallback')) {
          const div = document.createElement('div');
          div.className = 'fallback';
          div.textContent = '地图组件加载失败（网络无法访问地图资源）。';
          holder.append(div);
        }
      });
    },
    relayout() {
      if (map && lf.clientWidth) { map.invalidateSize(false); if (pendingFit) fit(fullBounds(), false); }
    },
  };
}

/* ---------- 电量图标与配色（与 App 的 BatteryIndicator 一致） ---------- */
const BatteryIndicator = {
  /** 按 SF Symbols 电池图标的填充档位分 5 档：0 / 25 / 50 / 75 / 100%。 */
  fraction(soc) {
    if (!isNum(soc)) return 1;
    if (soc < 12.5) return 0;
    if (soc < 37.5) return 0.25;
    if (soc < 62.5) return 0.5;
    if (soc < 87.5) return 0.75;
    return 1;
  },
  /** 低于 20% 红、20–50% 琥珀、其余绿；电量未知时用中性的石墨色。 */
  colorVar(soc) {
    if (!isNum(soc)) return '--graphite';
    if (soc < 20) return '--battery-low';
    if (soc < 50) return '--amber';
    return '--green';
  },
  icon(soc) {
    const width = (12 * this.fraction(soc)).toFixed(2);
    return `<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><rect width="16" height="10" x="2" y="7" rx="2" ry="2"/><line x1="22" x2="22" y1="11" y2="13"/>${Number(width) > 0 ? `<rect x="4" y="9" width="${width}" height="6" rx="0.6" fill="currentColor" stroke="none"/>` : ''}</svg>`;
  },
};

/* ---------- 显示格式 ---------- */
const VFmt = {
  km: (v) => (isNum(v) ? `${v.toFixed(0)} km` : '--'),
  temp: (v) => (isNum(v) ? `${v.toFixed(1)}℃` : '--'),
  pct: (v) => (isNum(v) ? `${Math.round(v)}%` : '--'),
  measure: (v, unit) => (isNum(v) && v > 0 ? `${v.toFixed(1)} ${unit}` : '--'),
  power: (w) => (isNum(w) && w > 0 ? `${(w / 1000).toFixed(1)} kW` : '--'),
  vehicleState(d) {
    if (d.isSwapping) return '正在换电';
    switch (d.stateCode) {
      case 1: return '行驶中';
      case 2: return '已驻车';
      case 3: return '充电中';
      case 4: return '换电中';
      default: return d.isConnected ? '车辆在线' : '车辆离线';
    }
  },
  lockState(code) { return code === 1 ? '已锁车' : code === 0 ? '未锁车' : '状态未知'; },
  chargeState(code) {
    switch (code) {
      case 1: return '充电中';
      case 2: return '充电完成';
      case 3: return '充电故障';
      case 0: return '未充电';
      default: return '--';
    }
  },
};
const sectionErrorHTML = (message) => `<div class="section-error">${icon('warn')}<span>${esc(message)}</span></div>`;

/* ---------- 车辆页（VehicleDetailView） ---------- */
const VehiclePage = {
  title: '车辆',
  page: null,
  ui: { standardRange: false, selectedDay: null, hiddenSegments: new Set(), showAllSegments: false, batteryTaps: 0 },
  maps: { current: null, track: null },

  build(page) {
    this.page = page;
    page.content.innerHTML = `
      <div data-sec="cached" hidden></div>
      <div data-sec="hero" hidden></div>
      <div data-sec="climate" hidden></div>
      <div data-sec="battery" hidden></div>
      <div data-sec="location" class="card stack" style="gap:12px" hidden>
        <div class="row"><span class="label headline">${icon('location', 'fill')}车辆位置</span><span class="spacer"></span>
          <button class="link-btn" data-act="openmap" data-el="openmap">地图打开</button></div>
        <div data-el="loc-map" class="stack" style="gap:12px">
          <div class="map" style="height:210px"><div class="lf" style="height:100%"></div>
            <button class="recenter" aria-label="归中车辆位置">${icon('locate')}</button></div>
          <div class="row caption num secondary"><span data-el="loc-coord"></span><span class="spacer"></span><span data-el="loc-time"></span></div>
        </div>
        <div data-el="loc-empty" class="unavailable" style="min-height:150px" hidden>${icon('pinoff')}
          <div class="t">暂无有效位置</div><div class="d">车辆上报有效 GPS 后会在这里显示。</div></div>
      </div>
      <div data-sec="unavailable" hidden></div>
      <div data-sec="trips" class="stack" style="gap:14px;padding-top:6px"></div>
      <div data-sec="track" class="card r24 p20 stack" style="gap:18px">
        <div class="row track-head" style="gap:12px">
          <span class="icon-box">${icon('route')}</span>
          <div class="stack" style="gap:3px"><span class="headline">位置轨迹</span><span class="caption secondary">车辆定位采样</span></div>
          <span class="spacer"></span><span class="pill violet num" data-el="days-pill" hidden></span>
        </div>
        <div data-el="track-error" hidden></div>
        <div data-el="track-empty" class="empty-track">${icon('pinoff')}
          <div class="stack" style="gap:4px"><span class="subhead semi">暂无采样轨迹</span><span class="caption secondary">收到有效车辆定位后，这里会按天显示采样路径。</span></div></div>
        <div data-el="track-body" class="stack" style="gap:18px" hidden>
          <div class="day-chips" data-el="chips" hidden></div>
          <div class="map" style="height:224px"><div class="lf" style="height:100%"></div>
            <div class="tag"><i class="g"></i><span data-el="tag-day"></span><span class="secondary" data-el="tag-count"></span></div>
            <button class="recenter" aria-label="归中车辆位置">${icon('locate')}</button></div>
          <div data-el="track-stats"></div>
          <div data-el="track-timeline"></div>
          <div class="caption2 secondary">静止 15 分钟或采样中断 30 分钟切段；过滤长时小范围定位漂移。采样距离并非官方行程里程。</div>
        </div>
      </div>
      <div data-sec="error" hidden></div>`;
    this.sec = (name) => page.content.querySelector(`[data-sec="${name}"]`);
    this.el = (name) => page.content.querySelector(`[data-el="${name}"]`);
    this.maps.current = createPathMap(this.sec('location').querySelector('.map'));
    this.maps.track = createPathMap(this.sec('track').querySelector('.map'));

    delegate(page.content, {
      range: () => this.toggleRange(),
      battery: (el) => this.batteryTap(el),
      'quick-lock': () => this.quickLock(),
      'quick-guard': () => this.openPanel('guard-mode'),
      'quick-find': () => this.openPanel('finding'),
      'quick-location': () => this.openInMaps(),
      'quick-more': () => this.openPanel('all'),
      climate: () => this.openPanel('climate'),
      'config-control': () => openSettings(),
      records: () => Nav.push(EnergyRecordsPage),
      openmap: () => this.openInMaps(),
      'all-trips': () => Nav.push(tripsListPage(Vehicle.s.trips)),
      day: (el) => { this.ui.selectedDay = Number(el.dataset.day); this.renderTrack(); },
      eye: (el) => {
        const id = el.dataset.id;
        if (this.ui.hiddenSegments.has(id)) this.ui.hiddenSegments.delete(id); else this.ui.hiddenSegments.add(id);
        this.renderTrack();
      },
      'toggle-segments': () => { this.ui.showAllSegments = !this.ui.showAllSegments; this.renderTrack(); },
    });

    this.renderToolbar();
    this.renderAll();
    Vehicle.on((keys) => {
      if (keys.has('loading')) { this.renderToolbar(); this.renderMain(); }
      if (keys.has('dashboard') || keys.has('config') || keys.has('performing') || keys.has('profile')) { this.renderMain(); this.renderLocation(); this.renderTrack(); }
      if (keys.has('cached')) this.renderCached();
      if (keys.has('history')) { this.renderLocation(); this.renderTrack(); }
      if (keys.has('trips')) this.renderTrips();
      if (keys.has('errors')) { this.renderTrips(); this.renderTrack(); this.renderError(); }
    });
    setInterval(() => { if (Vehicle.s.cached) this.renderCached(); }, 30000);
  },

  appear() {
    this.maps.current.relayout();
    this.maps.track.relayout();
  },
  refresh() { return Vehicle.refresh(); },

  renderToolbar() {
    const loading = Vehicle.s.loading;
    this.page.setToolbar(`<button class="nav-btn" data-tb="settings" aria-label="设置">${icon('gear')}</button>
      ${loading ? '<span class="nav-btn"><span class="spinner"></span></span>' : `<button class="nav-btn" data-tb="refresh" aria-label="刷新">${icon('refresh')}</button>`}`);
    const settings = this.page.toolbarEl.querySelector('[data-tb="settings"]');
    settings.addEventListener('click', () => openSettings());
    const refresh = this.page.toolbarEl.querySelector('[data-tb="refresh"]');
    if (refresh) refresh.addEventListener('click', () => Vehicle.refresh());
  },

  renderAll() {
    this.renderCached(); this.renderMain(); this.renderLocation(); this.renderTrips(); this.renderTrack(); this.renderError();
  },

  renderCached() {
    const s = Vehicle.s;
    const el = this.sec('cached');
    el.hidden = !s.cached;
    if (!s.cached) return;
    const when = s.lastRefreshAt ? ` · ${relTime(new Date(s.lastRefreshAt))}` : '';
    el.innerHTML = `<div class="cached-banner">${icon('history')}<span>先显示上次数据，正在刷新${esc(when)}</span></div>`;
  },

  renderMain() {
    const s = Vehicle.s;
    const d = s.dashboard;
    const hero = this.sec('hero');
    const climate = this.sec('climate');
    const battery = this.sec('battery');
    const unavailable = this.sec('unavailable');
    hero.hidden = climate.hidden = battery.hidden = !d;
    unavailable.hidden = !!d;
    if (!d) {
      unavailable.innerHTML = s.loadedOnce || !s.loading
        ? `<div class="unavailable pt80">${icon('car')}<div class="t">暂无车辆状态</div><div class="d">刷新后即可查看车辆详情、当前位置和历史行程。</div></div>`
        : '<div class="center-loading" style="padding-top:110px"><div class="spinner"></div><span>正在获取车辆状态…</span></div>';
      return;
    }
    this.renderHero(d);
    this.renderClimate(d);
    this.renderBattery(d);
  },

  /**
   * 车图优先用后端缓存的官方车图；没有时尝试加载项目录里可选的 vehicle-fallback.png
   * （按 1080×675 官方侧视图裁切），都没有则显示中性占位图标。
   */
  heroImageHTML() {
    const profile = Vehicle.s.profile;
    if (!profile) return '';
    const fallback = `this.onerror=null;this.className='crop';this.src='vehicle-fallback.png';this.addEventListener('error',()=>{this.parentNode.classList.add('placeholder');this.remove();},{once:true})`;
    if (profile.image_available) {
      const version = encodeURIComponent(profile.image_sha256 || '');
      return `<img class="fit" src="api/v1/vehicle/image?v=${version}" alt="" draggable="false" onerror="${fallback}">`;
    }
    return `<img class="crop" src="vehicle-fallback.png" alt="" draggable="false" onerror="this.parentNode.classList.add('placeholder');this.remove();">`;
  },

  usesStandardRange(d) {
    return d.remainingActualRange == null || (this.ui.standardRange && d.remainingRange != null);
  },

  rangeHTML(d, animate) {
    const standard = this.usesStandardRange(d);
    const value = standard ? d.remainingRange : d.remainingActualRange;
    const canSwitch = d.remainingRange != null && d.remainingActualRange != null;
    const label = standard ? '标准续航' : '预计可行驶';
    return `<button class="readout" data-act="range" aria-label="${label} ${VFmt.km(value)}" title="${canSwitch ? '轻点切换续航类型' : '当前只有一种续航数据'}">
        <span class="big rounded num"><span class="${animate ? 'numroll' : ''}">${isNum(value) ? value.toFixed(0) : '--'}</span><small>km</small></span>
        <span class="cap"><span>${label}</span>${canSwitch ? icon('swap') : ''}</span></button>`;
  },

  heroSubHTML(d) {
    const both = d.remainingRange != null && d.remainingActualRange != null;
    const other = both
      ? (this.usesStandardRange(d) ? `预计可行驶 ${VFmt.km(d.remainingActualRange)}` : `标准续航 ${VFmt.km(d.remainingRange)}`)
      : '';
    return `<span>${other}</span><span>总里程 ${VFmt.km(d.mileage)}</span>`;
  },

  renderHero(d) {
    const locked = d.lockStatusCode === 1;
    this.sec('hero').innerHTML = `<div class="hero">
      <div class="hero-head">
        <div class="hero-title"><div class="name rounded${Vehicle.title().length > 10 ? ' long' : ''}">${esc(Vehicle.title())}</div>
          <div class="state"><i class="dot${d.isConnected ? ' on' : ''}"></i><span>${VFmt.vehicleState(d)}</span>${Vehicle.colorLabel() ? `<span>· ${esc(Vehicle.colorLabel())}</span>` : ''}</div></div>
        <span class="spacer"></span>
        <span class="lock-pill ${locked ? 'c-green' : 'c-amber'}">${icon(locked ? 'lock' : 'unlock')}${VFmt.lockState(d.lockStatusCode)}</span>
      </div>
      <div class="hero-art" role="img" aria-label="${esc([Vehicle.colorLabel(), Vehicle.title()].filter(Boolean).join(' '))}">${this.heroImageHTML()}</div>
      <div class="hero-panel">
        <div class="row base"><span data-el="range">${this.rangeHTML(d, false)}</span><span class="spacer"></span>
          <button class="batt-readout" data-act="battery" aria-label="剩余电量 ${VFmt.pct(d.stateOfCharge)}" title="轻点播放电量动画">
            <span class="val rounded num" style="color:var(${BatteryIndicator.colorVar(d.stateOfCharge)})"><span class="icon-wrap">${BatteryIndicator.icon(d.stateOfCharge)}</span><span>${VFmt.pct(d.stateOfCharge)}</span></span>
            <span class="caption secondary">剩余电量</span></button></div>
        <div class="hero-sub num" data-el="hero-sub">${this.heroSubHTML(d)}</div>
        <hr class="divider" style="opacity:.65">
        <div data-el="quick" class="stack" style="gap:13px">${this.quickHTML(d)}</div>
      </div></div>`;
  },

  quickHTML(d) {
    const s = Vehicle.s;
    const busy = s.performing;
    const ctl = s.controlConfigured;
    const coord = Vehicle.currentCoordinate();
    const locked = d.lockStatusCode === 1;
    const button = (act, title, iconName, colorVar, enabled = true, needsKey = true) => {
      const usable = enabled && !busy && (!needsKey || ctl);
      return `<button data-act="${act}" ${usable ? '' : 'disabled'}><span class="box" style="color:var(${colorVar})">${icon(iconName, iconName === 'more' || iconName === 'location' ? 'fill' : '')}</span><span class="t">${title}</span></button>`;
    };
    let head = '';
    if (busy || !ctl) {
      head = `<div class="quick-head"><span>车辆控制</span><span class="spacer"></span>${busy
        ? '<span class="spinner sm"></span><span class="caption secondary" style="font-weight:400">指令执行中</span>'
        : '<button class="link-btn caption" data-act="config-control">配置车控 Key</button>'}</div>`;
    }
    return `${head}<div class="quick">
      ${button('quick-lock', locked ? '解锁' : '落锁', locked ? 'unlock' : 'lock', '--graphite', d.lockStatusCode === 0 || d.lockStatusCode === 1)}
      ${button('quick-guard', '守卫', 'shield', '--violet')}
      ${button('quick-find', '寻车', 'horn', '--amber')}
      ${button('quick-location', '位置', 'location', '--violet', !!coord, false)}
      ${button('quick-more', '更多', 'more', '--graphite')}
    </div>`;
  },

  renderClimate(d) {
    const s = Vehicle.s;
    this.sec('climate').innerHTML = `<div class="climate">
      <div class="stack" style="gap:12px">
        <span class="label subhead medium c-amber">${icon('sun')}座舱温度</span>
        <span class="temp rounded num">${VFmt.temp(d.insideTemperature)}</span>
        <span class="caption secondary">车外 ${VFmt.temp(d.outsideTemperature)}</span>
      </div><span class="spacer"></span>
      <span class="fan">${icon('fan', 'thin')}</span>
      ${s.controlConfigured ? `<button class="go" data-act="climate" aria-label="空调控制" ${s.performing ? 'disabled' : ''}>${icon('chevright')}</button>` : ''}
    </div>`;
  },

  renderBattery(d) {
    const charging = d.chargeStateCode === 1;
    const soc = d.stateOfCharge ?? 0;
    const cells = Array.from({ length: 20 }, (_, i) => `<i class="${i * 5 < soc ? 'on' : ''}"></i>`).join('');
    const value = (title, text) => `<div><div class="v num">${text}</div><div class="k">${title}</div></div>`;
    this.sec('battery').innerHTML = `<div class="card r24 p22 stack tappable" style="gap:18px" data-act="records" role="button" tabindex="0" aria-label="电池与充电，查看充换电记录">
      <div class="row"><span class="label headline ${charging ? 'c-green' : ''}">${charging ? icon('batterybolt') : BatteryIndicator.icon(d.stateOfCharge)}电池与充电</span><span class="spacer"></span>
        <span class="label caption semi c-green">充换电记录${icon('chevright')}</span></div>
      <div class="row base"><span class="rounded num" style="font-size:30px;font-weight:500">${VFmt.pct(d.stateOfCharge)}</span><span class="spacer"></span>
        <span class="caption secondary">充电上限 ${VFmt.pct(d.chargeLimitPercent)}</span></div>
      <div class="cells20" aria-hidden="true">${cells}</div>
      ${charging ? `<div class="chg-values">${value('功率', VFmt.power(d.chargingPower))}${value('电压', VFmt.measure(d.chargingVoltage, 'V'))}${value('电流', VFmt.measure(d.chargingCurrent, 'A'))}</div>` : ''}
      <div class="row"><span class="caption ${charging ? 'c-green' : 'secondary'}">${VFmt.chargeState(d.chargeStateCode)}</span><span class="spacer"></span>
        ${d.batterySampledAt ? `<span class="caption2 tertiary num">更新于 ${fmtDateTime(new Date(d.batterySampledAt))}</span>` : ''}</div>
    </div>`;
  },

  renderLocation() {
    const d = Vehicle.s.dashboard;
    const sec = this.sec('location');
    sec.hidden = !d;
    if (!d) return;
    const coord = Vehicle.currentCoordinate();
    this.el('openmap').hidden = !coord;
    this.el('loc-map').hidden = !coord;
    this.el('loc-empty').hidden = !!coord;
    if (!coord) return;
    this.el('loc-coord').textContent = `${coord.lat.toFixed(5)}, ${coord.lon.toFixed(5)}`;
    this.el('loc-time').textContent = d.locationSampledAt ? fmtDateTime(new Date(d.locationSampledAt)) : '';
    this.maps.current.update({ segments: [], visibleIDs: new Set(), samplePoint: null, current: coord, key: `current-${coord.lat}-${coord.lon}` });
  },

  renderTrips() {
    const s = Vehicle.s;
    const trips = s.trips;
    let body;
    if (!trips.length) body = '<div class="subhead secondary" style="min-height:90px;display:flex;align-items:center;justify-content:center;text-align:center">暂无行程记录，完成出行后可在这里查看。</div>';
    else body = trips.slice(0, 3).map((trip) => tripCardHTML(trip, true)).join('');
    this.sec('trips').innerHTML = `<div class="row"><span class="label headline">${icon('road')}最近行程</span><span class="spacer"></span>
        ${trips.length ? `<button class="link-btn" data-act="all-trips">全部${icon('chevright')}</button>` : ''}</div>
      ${s.err.trips ? sectionErrorHTML(s.err.trips) : ''}${body}`;
  },

  selectedPath() {
    const paths = Vehicle.s.dailyPaths;
    return paths.find((p) => p.day === this.ui.selectedDay) || paths[0] || null;
  },

  renderTrack() {
    const s = Vehicle.s;
    const paths = s.dailyPaths;
    if (this.ui.selectedDay == null || !paths.some((p) => p.day === this.ui.selectedDay)) {
      this.ui.selectedDay = paths.length ? paths[0].day : null;
    }
    const pill = this.el('days-pill');
    pill.hidden = !paths.length;
    pill.textContent = `${paths.length} 天记录`;
    const errEl = this.el('track-error');
    errEl.hidden = !s.err.history;
    errEl.innerHTML = s.err.history ? sectionErrorHTML(s.err.history) : '';
    this.el('track-empty').hidden = !!paths.length;
    this.el('track-body').hidden = !paths.length;
    const path = this.selectedPath();
    if (!path) return;

    const chips = this.el('chips');
    chips.hidden = paths.length <= 1;
    chips.innerHTML = paths.map((p) => `<button class="num${p.day === path.day ? ' active' : ''}" data-act="day" data-day="${p.day}" aria-label="查看 ${fmtDate(new Date(p.day))} 的采样轨迹">${fmtDate(new Date(p.day))}</button>`).join('');

    const day = new Date(path.day);
    const today = isToday(day);
    const visible = new Set(path.segments.map((seg) => seg.id).filter((id) => !this.ui.hiddenSegments.has(id)));
    this.el('tag-day').textContent = today ? '今日采样' : fmtDate(day);
    this.el('tag-count').textContent = `· ${path.segments.length} 段`;
    this.maps.track.update({
      segments: path.segments,
      visibleIDs: visible,
      samplePoint: path.segments.length ? null : path.points[path.points.length - 1] || null,
      current: today ? Vehicle.currentCoordinate() : null,
      key: String(path.day),
    });

    this.el('track-stats').innerHTML = `<div class="row base">
      <div class="stack" style="gap:4px"><span class="rounded num c-graphite" style="font-size:28px;font-weight:500">${distanceLabel(path.distanceKm)}</span>
        <span class="caption secondary">采样路径距离</span></div><span class="spacer"></span>
      <span class="label subhead medium"><span class="c-violet">${icon('pin')}</span>${path.segments.length} 段 · ${path.points.length} 点</span></div>`;

    const timeline = this.el('track-timeline');
    if (!path.segments.length) {
      timeline.innerHTML = '<div class="subhead secondary">当天暂无可辨认的行驶段</div>';
      return;
    }
    const shown = this.ui.showAllSegments ? path.segments.length : Math.min(4, path.segments.length);
    let rows = '';
    for (let i = 0; i < shown; i++) {
      const seg = path.segments[i];
      if (i > 0) {
        const gap = Math.max(0, Math.floor((seg.startTime - path.segments[i - 1].endTime) / 60000));
        rows += `<div class="gap">${icon('pause', 'fill')}<span>间隔 ${gap} 分钟</span></div>`;
      }
      const hidden = this.ui.hiddenSegments.has(seg.id);
      const color = `var(${segmentColorVar(i)})`;
      rows += `<div class="seg"><span class="bar" style="background:${color}"></span>
        <div class="stack" style="gap:3px"><span class="subhead semi num">第${i + 1}段 · ${fmtTime(new Date(seg.startTime))}–${fmtTime(new Date(seg.endTime))}</span>
          <span class="caption secondary">${distanceLabel(seg.distanceKm)}</span></div><span class="spacer"></span>
        <button class="eye-btn" data-act="eye" data-id="${esc(seg.id)}" style="color:${hidden ? 'var(--text2)' : color}" aria-label="${hidden ? '显示' : '隐藏'}第${i + 1}段轨迹">${icon(hidden ? 'eyeoff' : 'eye')}</button></div>`;
    }
    timeline.innerHTML = `<div class="timeline">
      <div class="row"><span class="subhead semi">采样时间轴</span><span class="spacer"></span><span class="caption2 secondary">点按眼睛显示/隐藏</span></div>
      ${rows}
      ${path.segments.length > 4 ? `<button class="link-btn caption" data-act="toggle-segments">${this.ui.showAllSegments ? '收起其余路段' : `查看全部 ${path.segments.length} 段`}</button>` : ''}
    </div>`;
  },

  renderError() {
    const message = Vehicle.s.err.main;
    const el = this.sec('error');
    el.hidden = !message;
    el.innerHTML = message ? `<div class="footnote c-red" style="padding:14px;border-radius:16px;background:color-mix(in srgb, var(--sys-red) 8%, transparent)">${esc(message)}</div>` : '';
  },

  /* ----- 交互 ----- */
  toggleRange() {
    const d = Vehicle.s.dashboard;
    if (!d || d.remainingRange == null || d.remainingActualRange == null) return;
    this.ui.standardRange = !this.ui.standardRange;
    this.el('range').innerHTML = this.rangeHTML(d, true);
    this.el('hero-sub').innerHTML = this.heroSubHTML(d);
  },

  batteryTap(el) {
    if (navigator.vibrate) { try { navigator.vibrate(8); } catch (e) { /* ignore */ } }
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const token = ++this.ui.batteryTaps;
    el.classList.remove('bounce');
    void el.offsetWidth; // 重新触发动画
    el.classList.add('bounce', 'pulse');
    const wrap = el.querySelector('.icon-wrap');
    wrap.querySelectorAll('.pulse-ring').forEach((ring) => ring.remove());
    const ring = document.createElement('span');
    ring.className = 'pulse-ring';
    wrap.append(ring);
    setTimeout(() => {
      if (token !== this.ui.batteryTaps) return;
      el.classList.remove('pulse', 'bounce');
      ring.remove();
    }, 800);
  },

  quickLock() {
    const d = Vehicle.s.dashboard;
    if (!d) return;
    if (d.lockStatusCode === 1) this.openPanel('unlock');
    else this.openConfirmation({ action: 'lock' });
  },

  openInMaps() {
    const coord = Vehicle.currentCoordinate();
    if (!coord) return;
    const url = `https://maps.apple.com/?ll=${coord.lat},${coord.lon}&q=${encodeURIComponent('车辆位置')}`;
    window.open(url, '_blank', 'noopener');
  },

  /* ----- 车控面板（VehicleControlPanel） ----- */
  openPanel(scope) {
    const scopes = {
      all: { title: '远程车控', height: null },
      unlock: { title: '解锁车辆', height: 470 },
      climate: { title: '空调控制', height: 470 },
      finding: { title: '寻车控制', height: 390 },
      'guard-mode': { title: '守卫模式', height: 500 },
    };
    const meta = scopes[scope];
    const d = Vehicle.s.dashboard;
    const lockLabel = d && d.lockStatusCode === 1 ? '上报状态：已锁车' : d && d.lockStatusCode === 0 ? '上报状态：未锁车' : '门锁状态未知';
    let queued = null;
    const heading = (title, subtitle) => `<div class="stack" style="gap:5px"><span class="headline">${title}</span><span class="caption secondary">${subtitle}</span></div>`;
    const button = (action, iconName, colorVar, { title = null, mirrors = false } = {}) => `<button class="ctl-btn" style="color:var(${colorVar})" data-action="${action}" ${mirrors ? 'data-mirrors="1"' : ''}>${icon(iconName)}<span>${title || VEHICLE_ACTIONS[action].title}</span></button>`;
    const show = (name) => scope === 'all' || scope === name;
    openSheet({
      height: meta.height,
      large: meta.height == null,
      onDismiss: () => { if (queued) this.openConfirmation(queued); },
      render: (body, sheet) => {
        body.innerHTML = `<div class="row top" data-drag style="gap:12px;padding:14px 22px 20px">
            <div class="stack" style="gap:5px"><span class="title2 semi">${meta.title}</span>
              <span class="caption secondary">${esc(Vehicle.title())} · ${lockLabel}</span></div><span class="spacer"></span>
            <button class="round-close bg" data-close aria-label="关闭远程车控">${icon('x')}</button></div>
          <div class="sheet-scroll"><div class="stack" style="gap:16px;padding:8px 18px 0">
            ${show('unlock') ? `<div class="ctl-card">${heading('门锁与启动', '两种解锁权限不同，请按实际用途选择')}
              ${button('unlock-doors', 'unlock', '--graphite')}${button('unlock-start', 'car', '--sys-red')}${scope === 'all' ? button('lock', 'lock', '--green') : ''}</div>` : ''}
            ${show('climate') ? `<div class="ctl-card"><div class="row">${heading('空调', '开启时使用下方设定温度')}<span class="spacer"></span>
                <span class="rounded num c-blue" style="font-size:34px;font-weight:500" data-temp aria-live="polite">22°</span></div>
              <div class="slider-row"><span class="num">16°</span><input class="slider" type="range" min="16" max="30" step="1" value="22" aria-label="空调设定温度"><span class="num">30°</span></div>
              <div class="ctl-row">${button('ac-on', 'fan', '--blue')}${button('ac-off', 'fanoff', '--graphite')}</div></div>` : ''}
            ${show('finding') ? `<div class="ctl-card">${heading('寻车', '车辆可能鸣笛或闪灯，请留意周围环境')}
              <div class="ctl-row">${button('find', 'horn', '--amber')}${button('find-stop', 'mute', '--graphite')}</div></div>` : ''}
            ${show('guard-mode') ? `<div class="ctl-card">${heading('守卫模式', '开启时明确选择后视镜状态')}
              ${button('guard-on', 'shield', '--violet', { title: '开启守卫 · 不展开后视镜' })}
              ${button('guard-on', 'expand', '--violet', { title: '开启守卫 · 展开后视镜', mirrors: true })}
              ${button('guard-off', 'shieldoff', '--graphite')}</div>` : ''}
            <div class="label caption secondary" style="padding:0 4px 24px">${icon('shieldcheck')}选择操作后还需确认。每项指令均不自动重试。</div>
          </div></div>`;
        const slider = body.querySelector('.slider');
        const tempLabel = body.querySelector('[data-temp]');
        const syncSlider = () => {
          const value = Number(slider.value);
          slider.style.setProperty('--p', `${((value - 16) / 14) * 100}%`);
          tempLabel.textContent = `${value}°`;
        };
        if (slider) { slider.addEventListener('input', syncSlider); syncSlider(); }
        body.querySelector('[data-close]').addEventListener('click', () => sheet.close());
        body.addEventListener('click', (e) => {
          const btn = e.target.closest('[data-action]');
          if (!btn) return;
          const action = btn.dataset.action;
          queued = {
            action,
            temperature: action === 'ac-on' && slider ? Number(slider.value) : null,
            expandMirrors: action === 'guard-on' && btn.dataset.mirrors === '1',
          };
          sheet.close();
        });
      },
    });
  },

  actionWarning(pending) {
    switch (pending.action) {
      case 'unlock-doors': return '只解锁车门，不授予启动权限。\n请先确认车辆已挂 P 挡、四门关闭且周围安全。执行后请现场核对门锁状态。';
      case 'unlock-start': return '将解锁车辆并授予启动权限。后端会检查车辆已驻车且车门关闭。请确认车辆周围安全，并在执行后现场核对。';
      case 'lock': return '后端会先检查车辆已驻车且车门关闭，再发送一次落锁指令。';
      case 'ac-on': return `将以 ${isNum(pending.temperature) ? pending.temperature.toFixed(0) : '22'}℃ 发送一次空调开启指令。`;
      case 'ac-off': return '将发送一次空调关闭指令。';
      case 'find': return '将发送一次寻车指令，车辆可能鸣笛或闪灯。';
      case 'find-stop': return '将发送一次停止寻车指令。';
      case 'guard-on': return pending.expandMirrors
        ? '后端检查驻车状态后开启守卫模式，再单独发送展开后视镜指令。后视镜结果需另外核对。'
        : '后端检查驻车状态后开启守卫模式；后视镜保持原状。';
      case 'guard-off': return '将发送一次守卫模式关闭指令，后端会检查车辆驻车状态。';
      default: return '';
    }
  },

  /* ----- 执行前确认（VehicleActionConfirmation） ----- */
  openConfirmation(pending) {
    const def = VEHICLE_ACTIONS[pending.action];
    const title = pending.expandMirrors ? '开启守卫并展开后视镜' : def.title;
    let confirmed = false;
    let execute = false;
    openSheet({
      height: 530,
      dismissDisabled: () => confirmed,
      onDismiss: () => { if (execute) this.execute(pending); },
      render: (body, sheet) => {
        body.innerHTML = `<div class="sheet-scroll"><div class="stack" style="gap:22px;padding:14px 22px 18px">
            <div class="row" data-drag style="gap:14px">
              <span class="confirm-icon" style="color:var(${def.accent})">${icon(def.icon)}</span>
              <div class="stack" style="gap:5px;min-width:0"><span class="caption secondary">执行前确认</span><span class="title2 semi">${title}</span></div>
              <span class="spacer"></span><button class="round-close" data-cancel aria-label="取消车控操作">${icon('x')}</button></div>
            <div class="card row" style="border-radius:20px;gap:12px"><span class="title2 c-graphite">${icon('car')}</span>
              <div class="stack" style="gap:4px"><span class="subhead semi">${esc(Vehicle.title())}</span><span class="caption secondary">本次操作的车辆</span></div><span class="spacer"></span>
              ${pending.action === 'ac-on' && isNum(pending.temperature) ? `<span class="title3 semi num c-blue">${Math.round(pending.temperature)}℃</span>` : ''}</div>
            ${pending.action === 'guard-on' ? `<div class="label subhead medium c-violet" style="padding:14px;border-radius:16px;background:color-mix(in srgb, var(--violet) 8%, transparent)">${icon(pending.expandMirrors ? 'expand' : 'minus')}${pending.expandMirrors ? '守卫开启后展开后视镜' : '后视镜保持原状'}</div>` : ''}
            <div class="tint-box" style="background:color-mix(in srgb, var(--amber) 7%, transparent)">
              <span class="label subhead semi c-amber">${icon('shieldwarn')}${def.highRisk ? '请确认车辆安全' : '操作说明'}</span>
              <span class="subhead" style="line-height:1.6;white-space:pre-line">${esc(this.actionWarning(pending))}</span></div>
            <div class="caption secondary">${pending.expandMirrors
    ? '守卫与后视镜分别发送，均不自动重试。两步可能部分成功，请分别核对结果。'
    : '每次确认仅发送一次指令，不自动重试。提交不等于生效，请查看执行结果并核对车辆状态。'}</div>
          </div></div>
          <div class="confirm-foot"><button class="cancel" data-cancel>取消</button>
            <button class="go" data-go style="background:${def.fill}">确认${title}</button></div>`;
        body.querySelectorAll('[data-cancel]').forEach((btn) => btn.addEventListener('click', () => { if (!confirmed) sheet.close(); }));
        body.querySelector('[data-go]').addEventListener('click', () => {
          if (confirmed) return;
          confirmed = true;
          execute = true;
          body.querySelectorAll('button').forEach((btn) => { btn.disabled = true; });
          sheet.close();
        });
      },
    });
  },

  async execute(pending) {
    try {
      const outcome = await Vehicle.performAction(pending);
      let message;
      switch (outcome.status) {
        case 'verified': message = '后端已轮询确认车辆达到目标状态。'; break;
        case 'already_desired': message = '车辆原本已经处于目标状态，没有重复发送指令。'; break;
        case 'accepted_unverified': message = '上游已接受指令，但后端未确认最终车辆状态。请查看车辆现场或刷新状态后再判断；页面不会自动重试。'; break;
        default: message = `后端返回状态：${outcome.status}。请结合车辆现场确认。`;
      }
      let mirror = '';
      if (outcome.mirrors === 'already_expanded') mirror = '后视镜原本已展开。';
      else if (outcome.mirrors === 'accepted_unverified') mirror = '后视镜展开指令已接受，但未确认最终状态；请现场核对。';
      else if (outcome.mirrors != null) mirror = `后视镜结果：${outcome.mirrors}；请现场核对。`;
      const ok = outcome.verified && (outcome.mirrors == null || outcome.mirrors === 'already_expanded');
      showAlert({ title: ok ? '已确认' : '请核对车辆', message: message + (mirror ? `\n${mirror}` : '') });
    } catch (err) {
      const detail = errText(err);
      showAlert({
        title: '指令未完成',
        message: pending.expandMirrors ? `${detail}\n守卫模式可能已开启，后视镜状态也可能已变化；请现场核对，页面不会重发指令。` : detail,
      });
    }
  },
};

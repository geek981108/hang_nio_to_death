'use strict';
/* 换电站页：对应 App 的 StationViewModel / ContentView.stationContent / CardView / StationFeeViews / StationManagementViews。
   App 里站点来自 cURL 请求；在 HA 里由后端代查，所以「已保存的站点」只保存站点 ID，
   默认使用「自动：离车最近换电站」。 */

const BATTERY_FILTERS = ['全部', '75 kWh', '70 kWh', '100 kWh', '102 kWh', '150 kWh'];

/* ---------- 费率模型（FeeItem / FeePeriod / FeeInfo） ---------- */
function makeFeeItem(entry) {
  const name = entry.name || '';
  const type = entry.fee_type || null;
  const normalized = name.trim().replace(/ /g, '').toLowerCase();
  const isTotal = entry.is_total === true
    || (type && type.toLowerCase().includes('total_fee'))
    || normalized === '合计' || normalized === '总计' || normalized.includes('总费用') || normalized === 'total' || normalized === 'totalfee';
  return { type, name, fee: entry.fee || '', unit: entry.unit || '', currency: entry.currency || '¥', isTotal: !!isTotal };
}
function feeTotal(fees) {
  const total = fees.find((item) => item.isTotal);
  if (total && Number.isFinite(parseFloat(total.fee))) return parseFloat(total.fee);
  const values = fees.filter((item) => !item.isTotal).map((item) => parseFloat(item.fee)).filter(Number.isFinite);
  return values.length ? values.reduce((a, b) => a + b, 0) : null;
}
function periodMinute(text, index) {
  const parts = String(text).split('-');
  if (parts.length < 2) return null;
  const match = /^(\d{1,2}):(\d{2})$/.exec(parts[index].trim());
  if (!match) return null;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (hour > 24 || minute > 59 || (hour === 24 && minute !== 0)) return null;
  return hour * 60 + minute;
}
function makeFeeInfo(data) {
  const currentFees = (data.current_fees || []).map(makeFeeItem);
  const notices = data.fee_notices || [];
  const periods = (data.fee_periods || []).map((period) => {
    const fees = (period.fees || []).map(makeFeeItem);
    const total = fees.find((item) => item.isTotal);
    const components = fees.filter((item) => !item.isTotal);
    return {
      id: period.time_period,
      timePeriod: period.time_period,
      fees,
      components,
      start: periodMinute(period.time_period, 0),
      end: periodMinute(period.time_period, 1),
      total: feeTotal(fees),
      currency: (total || components[0] || {}).currency || '¥',
      unit: (total || components[0] || {}).unit || '',
    };
  }).sort((a, b) => (a.start ?? Infinity) - (b.start ?? Infinity));
  if (!currentFees.length && !notices.length && !periods.length) return null;
  const total = currentFees.find((item) => item.isTotal);
  const components = currentFees.filter((item) => !item.isTotal);
  return {
    currentFees, components, periods, notices,
    total: feeTotal(currentFees),
    totalCurrency: (total || components[0] || {}).currency || '¥',
    totalUnit: (total || components[0] || {}).unit || '',
  };
}
function periodContains(period, minute) {
  if (period.start == null || period.end == null) return false;
  if (period.end > period.start) return minute >= period.start && minute < period.end;
  return minute >= period.start || minute < period.end;
}

/* ---------- 电池模型（BatteryModel） ---------- */
function makeBattery(entry) {
  const capacity = entry.capacity_kwh;
  const known = { 102: '102 kWh', 100: '100 kWh', 75: '75 kWh', 70: '70 kWh', 150: '150 kWh' }[capacity];
  // 上游只给了类型编码、尚未确认容量的电池，按编码单独分组，而不是混进「其他电池」。
  const type = known || (entry.battery_cap_series != null ? `未识别类型 ${entry.battery_cap_series}` : '其他电池');
  const progress = clamp(entry.progress_percent ?? 0, 0, 100);
  const occupied = entry.battery_occupied === true;
  return {
    id: entry.battery_id || `slot-${entry.slot_id ?? 0}`,
    progress,
    type,
    group: type,
    remainingMinutes: (entry.charging_remaining_minutes ?? 0) > 0 ? entry.charging_remaining_minutes : null,
    occupied,
    date: entry.production_date || null,
    slot: entry.slot_id ?? 0,
    status: occupied ? 'occupied' : (progress >= 92 ? 'ready' : 'charging'),
  };
}
const BATTERY_STATUS = {
  occupied: { label: '使用中', colorVar: '--text2', icon: 'car' },
  ready: { label: '可换电', colorVar: '--green', icon: 'bolt' },
  charging: { label: '充电中', colorVar: '--amber', icon: 'battery' },
};

/* ---------- 数据模型（StationViewModel） ---------- */
const Station = {
  savedKey: 'nio.savedStations.v1',
  selectedKey: 'nio.selectedStation',
  filterKey: 'nio.stationPreferredBatteryType',
  s: { batteries: [], feeInfo: null, queue: null, loading: false, name: null, stationID: null, lastUpdated: null, error: null, loadedKey: null },
  subs: new Set(),
  token: 0,
  autoToken: 0,

  on(fn) { this.subs.add(fn); return () => this.subs.delete(fn); },
  emit() { this.subs.forEach((fn) => { try { fn(); } catch (e) { console.error(e); } }); },

  saved() { return Store.get(this.savedKey, []) || []; },
  setSaved(list) { Store.set(this.savedKey, list); },
  selection() {
    const value = Store.get(this.selectedKey, 'auto');
    return value !== 'auto' && this.saved().some((item) => item.id === value) ? value : 'auto';
  },
  /** 用户在设置里选过就用用户的；否则按加载项的换电目标档位推断（8 = 102 kWh），再否则显示全部。 */
  preferredType() { return Store.get(this.filterKey, null) || Vehicle.s.defaultBatteryType || '全部'; },
  setPreferredType(value) { Store.set(this.filterKey, value); this.emit(); },

  visible() {
    const preferred = this.preferredType();
    if (preferred === '全部') return this.s.batteries;
    return this.s.batteries.filter((battery) => battery.group === preferred);
  },
  count(status) { return this.visible().filter((battery) => battery.status === status).length; },
  grouped() {
    const priority = { '75 kWh': 0, '70 kWh': 1, '100 kWh': 2, '102 kWh': 3, '150 kWh': 4 };
    const groups = new Map();
    for (const battery of this.visible()) {
      if (!groups.has(battery.group)) groups.set(battery.group, []);
      groups.get(battery.group).push(battery);
    }
    return Array.from(groups, ([name, batteries]) => ({ name, batteries }))
      .sort((a, b) => ((priority[a.name] ?? 99) - (priority[b.name] ?? 99)) || a.name.localeCompare(b.name));
  },

  select(id) {
    Store.set(this.selectedKey, id);
    return this.load();
  },
  addSaved(station) {
    const list = this.saved().filter((item) => item.id !== station.id);
    list.push(station);
    this.setSaved(list);
  },
  removeSaved(id) {
    const wasSelected = this.selection() === id;
    const list = this.saved().filter((item) => item.id !== id);
    this.setSaved(list);
    if (wasSelected) this.select(list.length ? list[0].id : 'auto');
    else this.emit();
  },

  dismissError() { this.s.error = null; this.emit(); },

  async load() {
    const s = this.s;
    const selection = this.selection();
    const token = ++this.token;
    if (s.loadedKey !== selection) {
      s.batteries = []; s.feeInfo = null; s.queue = null; s.lastUpdated = null; s.stationID = null;
      s.name = selection === 'auto' ? null : (this.saved().find((item) => item.id === selection) || {}).name || null;
      s.loadedKey = selection;
    }
    s.loading = true;
    s.error = null;
    this.emit();
    try {
      let data;
      let name;
      if (selection === 'auto') {
        data = await api('api/v1/stations/nearest', { timeout: 40000 });
        name = `${data.station_name} · 距车 ${Number(data.straight_line_distance_km).toFixed(1)} km`;
      } else {
        data = await api(`api/v1/stations/${encodeURIComponent(selection)}/live`, { timeout: 40000 });
        name = (this.saved().find((item) => item.id === selection) || {}).name || data.station_name;
      }
      if (token !== this.token) return;
      s.batteries = (data.battery_readiness || []).map(makeBattery).sort((a, b) => a.slot - b.slot);
      s.feeInfo = makeFeeInfo(data);
      s.queue = data.queue || null;
      s.stationID = data.station_id || (selection === 'auto' ? null : selection);
      s.name = name;
      s.lastUpdated = Date.now();
    } catch (err) {
      if (token !== this.token) return;
      s.error = selection === 'auto' ? `最近换电站获取失败：${errText(err)}` : errText(err);
      Toast.fail(s.error);
    } finally {
      if (token === this.token) { s.loading = false; this.emit(); }
    }
  },

  /** 仅当换电站标签页在前台时，每 60 秒自动刷新。 */
  startAuto() {
    const token = ++this.autoToken;
    (async () => {
      await this.load();
      while (token === this.autoToken) {
        await sleep(60000);
        if (token !== this.autoToken || document.hidden) return;
        await this.load();
      }
    })();
  },
  stopAuto() { this.autoToken += 1; },
};

/* ---------- 页面 ---------- */
function batteryCardHTML(battery) {
  const status = BATTERY_STATUS[battery.status];
  const color = `var(${status.colorVar})`;
  return `<div class="bat-card" aria-label="${battery.slot} 号仓，${battery.type}，${status.label}，电量 ${Math.round(battery.progress)}%">
    <span class="slot rounded" style="color:${color}">${battery.slot}</span>
    <div class="body">
      <div class="row" style="gap:8px"><span class="headline ellip">${esc(battery.type || '未知电池')}</span><span class="spacer"></span>
        <span class="status" style="color:${color}">${icon(status.icon, battery.status === 'charging' ? '' : 'fill')}${status.label}</span></div>
      <div class="progress" style="color:${color}"><i style="width:${battery.progress}%"></i></div>
      <div class="foot">${battery.date ? `<span class="label">${icon('calendar')}${esc(battery.date)}</span>` : ''}
        ${battery.status === 'charging' && battery.remainingMinutes ? `<span class="label">${icon('clock')}约 ${battery.remainingMinutes} 分钟</span>` : ''}
        <span class="spacer"></span><span class="semi" style="color:${color}">${Math.round(battery.progress)}%</span></div>
    </div></div>`;
}

const StationPage = {
  title: '换电站',
  contentClass: 'g22',
  page: null,

  build(page) {
    this.page = page;
    page.setToolbar(`<button class="nav-btn" data-tb="menu" aria-label="站点操作">${icon('morecircle')}</button>`);
    page.toolbarEl.querySelector('[data-tb="menu"]').addEventListener('click', (e) => this.openMenu(e.currentTarget));
    delegate(page.content, {
      refresh: () => Station.load(),
      order: () => this.startOrder(),
      retry: () => Station.load(),
      'dismiss-error': () => Station.dismissError(),
      'fee-detail': () => { if (Station.s.feeInfo) openFeeDetail(Station.s.feeInfo); },
    });
    Station.on(() => this.render());
    Vehicle.on((keys) => { if (keys.has('order') || keys.has('config')) this.render(); });
    this.render();
  },
  refresh() { return Station.load(); },

  render() {
    const s = Station.s;
    const v = Vehicle.s;
    const hasBatteries = s.batteries.length > 0;
    const preferred = Station.preferredType();
    const queue = s.queue;
    const queueLine = queue && (queue.vehicles_ahead != null || queue.navigation_count != null)
      ? `<div class="cap num" style="margin-top:6px">排队 ${queue.vehicles_ahead ?? '--'} 辆 · 前往 ${queue.navigation_count ?? '--'} 辆</div>` : '';
    const outcome = v.lastOrderOutcome;
    const metric = (title, value, colorVar) => `<div class="m"><span class="n rounded num">${value}</span><span class="l" ><i style="color:var(${colorVar})"></i>${title}</span></div>`;
    const fee = s.feeInfo;

    let html = `<div class="st-header">
      <div class="row top" style="gap:16px">
        <div style="min-width:0"><div class="cap">换电站实况</div><div class="name lines2">${esc(s.name || (s.loading ? '正在查找换电站…' : '选择你的换电站'))}</div>${queueLine}</div>
        <span class="spacer"></span>
        <button class="circle" data-act="refresh" aria-label="刷新换电站状态" ${s.loading ? 'disabled' : ''}>${s.loading ? '<span class="spinner sm white"></span>' : icon('refresh')}</button>
      </div>
      ${hasBatteries ? `<div class="row end"><div class="row base" style="gap:8px"><span class="ready rounded num">${Station.count('ready')}</span>
          <span class="ready-l">${preferred === '全部' ? '块电池可换' : `块可换 · ${esc(preferred)}`}</span></div><span class="spacer"></span>
          <span class="bigicon">${icon('boltcar', 'thin')}</span></div>` : ''}
      ${s.lastUpdated ? `<div class="upd num">更新于 ${fmtTime(new Date(s.lastUpdated))}</div>` : '<div class="cap" style="font-weight:400">选择站点，查看电池与实时费率</div>'}
      <button class="order-btn" data-act="order" ${(!s.stationID && v.controlConfigured) || v.creatingOrder ? 'disabled' : ''}>
        ${v.creatingOrder ? '<span class="spinner sm white"></span>' : icon('bolt', 'fill')}<span>${v.controlConfigured ? '发起换电' : '配置车控 Key'}</span></button>
    </div>`;

    if (outcome) {
      html += `<div class="order-ok"><span class="label headline" style="color:var(--sys-green)">${icon('checkcircle')}换电订单已创建</span>
        <span class="caption mono sel">订单号：${esc(outcome.order_id)}</span>
        <span class="caption secondary">目标电池档位：${esc(outcome.target_battery_cap_level ?? outcome.requested_battery_cap_level)}</span></div>`;
    }
    if (s.error) {
      html += `<div class="error-banner">${icon('warn', 'fill')}<span class="msg">${esc(s.error)}</span>
        <button class="retry" data-act="retry">重试</button><button class="close" data-act="dismiss-error" aria-label="关闭错误提示">${icon('x')}</button></div>`;
    }
    if (hasBatteries) {
      html += `<div class="st-metrics">${metric('充电中', Station.count('charging'), '--amber')}<span class="vd"></span>${metric('使用中', Station.count('occupied'), '--blue')}<span class="vd"></span>${metric('电池总数', s.batteries.length, '--text2')}</div>`;
      if (fee) {
        html += `<div class="card p22 stack" style="border-radius:20px;gap:14px">
          <div class="row"><span class="label headline">${icon('yen')}当前费率</span><span class="spacer"></span>
            ${fee.periods.length ? `<button class="link-btn" data-act="fee-detail">${icon('chart')}详情</button>` : ''}</div>
          ${fee.total != null ? `<div class="row base" style="gap:4px"><span class="fee-total rounded num">${esc(fee.totalCurrency)}${fee.total.toFixed(2)}</span>${fee.totalUnit ? `<span class="caption secondary">/${esc(fee.totalUnit)}</span>` : ''}</div>` : ''}
          ${fee.components.map((item) => `<div class="row subhead"><span class="secondary">${esc(item.name)}</span><span class="spacer"></span><span class="semi num">${esc(item.currency)}${esc(item.fee)}/${esc(item.unit)}</span></div>`).join('')}
        </div>`;
      }
      html += Station.grouped().map((group) => `<div class="stack" style="gap:10px">
        <div class="row"><span class="title3 bold">${esc(group.name)}</span><span class="spacer"></span><span class="caption secondary">${group.batteries.length} 块</span></div>
        ${group.batteries.map(batteryCardHTML).join('')}</div>`).join('');
    } else if (!s.loading && !s.error) {
      html += `<div class="unavailable pt40">${icon('batterylow')}<div class="t">暂无电池信息</div><div class="d">该站点当前没有返回可展示的电池。</div></div>`;
    }
    if (s.loading && !hasBatteries) html += '<div class="floating-progress"><div class="spinner"></div><span>正在获取换电站状态…</span></div>';
    this.page.content.innerHTML = html;
  },

  openMenu(anchor) {
    const selection = Station.selection();
    showMenu(anchor, [
      { label: '自动：离车最近换电站', icon: 'locate', checked: selection === 'auto', action: () => Station.select('auto') },
      { label: '已保存的站点', icon: 'list', action: () => openSavedStations() },
      { label: '从后端搜索', icon: 'search', action: () => openStationPicker() },
      'divider',
      { label: '设置', icon: 'server', action: () => openSettings() },
    ]);
  },

  async startOrder() {
    if (!Vehicle.s.controlConfigured) { openSettings(); return; }
    const s = Station.s;
    if (!s.stationID) return;
    const choice = await showAlert({
      title: '创建真实换电订单',
      message: `将为当前站点“${s.name || '未命名换电站'}”创建真实换电订单。请求只发送一次，不会自动重试。`,
      buttons: [{ label: '取消', role: 'cancel' }, { label: '确认下单', role: 'destructive' }],
    });
    if (choice !== 1) return;
    try { await Vehicle.createSwapOrder(s.stationID); } catch (err) { /* 失败已通过 Toast 提示 */ }
  },
};

/* ---------- 分时费率详情（FeeDetailView） ---------- */
function openFeeDetail(feeInfo) {
  let timer = null;
  openSheet({
    large: true,
    onDismiss: () => clearInterval(timer),
    render: (body, sheet) => {
      body.innerHTML = `<div class="sheet-nav" data-drag><span class="l"></span><span class="title">分时费率详情</span>
          <span class="r"><button class="nav-btn strong" data-done>完成</button></span></div>
        <div class="sheet-scroll"><div class="stack" style="gap:20px;padding:16px" data-el="detail"></div></div>`;
      body.querySelector('[data-done]').addEventListener('click', () => sheet.close());
      const holder = body.querySelector('[data-el="detail"]');
      const teal = 'var(--sys-teal)';
      const indigo = 'var(--sys-indigo)';
      const render = () => {
        const now = new Date();
        const minute = now.getHours() * 60 + now.getMinutes();
        const periods = feeInfo.periods;
        const current = periods.find((period) => periodContains(period, minute)) || null;
        const next = current && periods.length > 1 ? periods[(periods.indexOf(current) + 1) % periods.length] : null;
        const colorOf = (period) => (current && period.id === current.id ? teal
          : next && period.id === next.id ? 'color-mix(in srgb, var(--sys-indigo) 72%, transparent)'
            : 'color-mix(in srgb, var(--text2) 45%, transparent)');
        const priceText = (period) => (period.total != null ? `${esc(period.currency)}${period.total.toFixed(2)}${period.unit ? `/${esc(period.unit)}` : ''}` : '');
        const card = (title, period, color, iconName) => `<div class="period-card" style="color:${color}">
          <span class="lab">${icon(iconName, 'fill')}${title}</span><span class="headline num">${period ? esc(period.timePeriod) : '暂无'}</span>
          ${period && period.total != null ? `<span class="title3 bold num">${priceText(period)}</span>` : ''}</div>`;
        holder.innerHTML = `<div class="row" style="gap:12px;align-items:stretch">${card('当前时段', current, teal, 'clock')}${card('下一时段', next, indigo, 'forward')}</div>
          <div class="card stack" style="border-radius:20px;gap:12px"><span class="headline">全天费用趋势</span>
            <div class="chart" style="height:230px" data-el="fee-chart"></div>
            <div class="row" style="gap:16px;flex-wrap:wrap"><span class="legend"><i style="background:${teal}"></i>当前</span><span class="legend"><i style="background:${indigo}"></i>下一时段</span>
              <span class="legend"><i style="background:color-mix(in srgb, var(--text2) 45%, transparent)"></i>其他时段</span><span class="spacer"></span>
              <span class="caption secondary num">现在 ${pad2(Math.floor(minute / 60))}:${pad2(minute % 60)}</span></div></div>
          <div class="card stack" style="border-radius:20px"><span class="headline" style="padding-bottom:10px">全部时段</span>
            ${periods.map((period, index) => `<div class="fee-row"><span class="bar" style="background:${colorOf(period)}"></span>
              <span class="subhead num">${esc(period.timePeriod)}</span><span class="spacer"></span>
              <div class="stack" style="align-items:flex-end;gap:2px">${period.total != null ? `<span class="subhead semi num">${esc(period.currency)}${period.total.toFixed(2)}/${esc(period.unit)}</span>` : ''}
                <span class="caption2 secondary">${period.components.map((item) => `${esc(item.name)} ${esc(item.fee)}`).join(' · ')}</span></div></div>
              ${index < periods.length - 1 ? '<hr class="divider">' : ''}`).join('')}</div>
          ${feeInfo.notices.length ? `<div class="notice-card"><span class="label headline">${icon('info')}计费说明</span>
            ${feeInfo.notices.map((notice) => `<span class="footnote secondary">${esc(notice)}</span>`).join('')}</div>` : ''}`;
        renderFeeChart(holder.querySelector('[data-el="fee-chart"]'), periods, colorOf);
      };
      render();
      timer = setInterval(render, 60000);
    },
  });
}

function renderFeeChart(holder, periods, colorOf) {
  const width = Math.max(240, holder.clientWidth || 320);
  const height = 230;
  const m = { l: 34, r: 8, t: 10, b: 22 };
  const plotW = width - m.l - m.r;
  const plotH = height - m.t - m.b;
  const maxV = periods.reduce((acc, period) => Math.max(acc, period.total || 0), 0) || 1;
  const step = niceStep(maxV / 4);
  const top = Math.max(step, Math.ceil(maxV / step) * step);
  const x = (hour) => m.l + (hour / 24) * plotW;
  const y = (value) => m.t + plotH - (value / top) * plotH;
  let grid = '';
  for (let value = 0; value <= top + 1e-9; value += step) {
    const yy = y(value).toFixed(1);
    grid += `<line class="grid" x1="${m.l}" x2="${width - m.r}" y1="${yy}" y2="${yy}"/><text class="axis" x="${m.l - 6}" y="${yy}" text-anchor="end" dominant-baseline="middle">${Number(value.toFixed(2))}</text>`;
  }
  for (let hour = 0; hour <= 24; hour += 4) {
    const xx = x(hour).toFixed(1);
    grid += `<line class="grid" x1="${xx}" x2="${xx}" y1="${m.t}" y2="${m.t + plotH}"/><text class="axis" x="${xx}" y="${height - 5}" text-anchor="${hour === 0 ? 'start' : hour === 24 ? 'end' : 'middle'}">${pad2(hour)}:00</text>`;
  }
  let bars = '';
  for (const period of periods) {
    if (period.start == null || period.end == null || period.total == null) continue;
    // 跨零点的时段拆成两段绘制。
    const spans = period.end > period.start ? [[period.start, period.end]] : [[period.start, 1440], [0, period.end]];
    for (const [start, end] of spans) {
      if (end <= start) continue;
      const x0 = x(start / 60) + 1;
      const x1 = x(end / 60) - 1;
      const yy = y(period.total);
      bars += `<rect x="${x0.toFixed(1)}" y="${yy.toFixed(1)}" width="${Math.max(1, x1 - x0).toFixed(1)}" height="${Math.max(0, m.t + plotH - yy).toFixed(1)}" rx="4" style="fill:${colorOf(period)}"/>`;
    }
  }
  holder.innerHTML = `<svg viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" role="img" aria-label="全天费用趋势">${grid}${bars}</svg>`;
}

/* ---------- 已保存的站点（SavedRequestsView） ---------- */
function openSavedStations() {
  openSheet({
    large: true,
    render: (body, sheet) => {
      body.innerHTML = `<div class="sheet-nav" data-drag><span class="l"></span><span class="title">换电站</span>
          <span class="r"><button class="nav-btn strong" data-done>完成</button></span></div>
        <div class="sheet-scroll"><div data-el="list" style="padding:8px 16px 28px"></div></div>`;
      body.querySelector('[data-done]').addEventListener('click', () => sheet.close());
      const list = body.querySelector('[data-el="list"]');
      const render = () => {
        const saved = Station.saved();
        const selection = Station.selection();
        if (!saved.length) {
          list.innerHTML = `<div class="unavailable pt40">${icon('boltcar')}<div class="t">还没有保存的站点</div><div class="d">可通过右上角菜单的「从后端搜索」添加常用换电站；未选择时默认显示离车最近的换电站。</div></div>`;
          return;
        }
        list.innerHTML = `<div class="list-group">${saved.map((item) => `<div class="station-row">
            <button class="row" data-pick="${esc(item.id)}" style="flex:1;gap:12px;min-width:0;text-align:left">
              <span style="font-size:22px;color:var(${item.id === selection ? '--sys-teal' : '--text2'})">${icon(item.id === selection ? 'checkcircle' : 'circle')}</span>
              <span class="stack" style="gap:4px;min-width:0"><span class="headline">${esc(item.name || '未命名站点')}</span><span class="caption mono secondary ellip">${esc(item.id)}</span></span></button>
            <button class="del" data-del="${esc(item.id)}" aria-label="删除 ${esc(item.name || item.id)}">${icon('trash')}</button></div>`).join('')}</div>
          <div class="list-footer">当前：${selection === 'auto' ? '自动选择离车最近的换电站' : '使用已选站点'}。删除当前站点后会回到下一个已保存站点或自动模式。</div>`;
      };
      list.addEventListener('click', (e) => {
        const pick = e.target.closest('[data-pick]');
        const del = e.target.closest('[data-del]');
        if (pick) { Station.select(pick.dataset.pick); sheet.close(); }
        else if (del) { Station.removeSaved(del.dataset.del); render(); }
      });
      render();
    },
  });
}

/* ---------- 从后端添加（BackendStationPickerView） ---------- */
function openStationPicker() {
  openSheet({
    large: true,
    render: (body, sheet) => {
      body.innerHTML = `<div class="sheet-nav" data-drag><span class="l"><button class="nav-btn" data-cancel>取消</button></span><span class="title">从后端添加</span><span class="r"></span></div>
        <label class="search-field">${icon('search')}<input type="search" placeholder="名称、站点 ID 或地址" autocomplete="off" autocapitalize="off" spellcheck="false" enterkeyhint="search"></label>
        <div class="sheet-scroll"><div data-el="list" style="padding:0 0 28px"></div></div>`;
      body.querySelector('[data-cancel]').addEventListener('click', () => sheet.close());
      const input = body.querySelector('input');
      const list = body.querySelector('[data-el="list"]');
      let stations = [];
      let loading = false;
      let error = null;
      let token = 0;
      let debounce = null;
      const render = () => {
        const savedIDs = new Set(Station.saved().map((item) => item.id));
        const query = input.value.trim();
        let html = '';
        if (loading && !stations.length) html += '<div class="center-loading"><div class="spinner"></div><span>正在查询后端站点…</span></div>';
        else if (!stations.length && !error) {
          html += `<div class="unavailable pt40">${icon('boltcar')}<div class="t">${query ? '没有匹配的换电站' : '后端暂无换电站'}</div><div class="d">可按站点名称、ID、地址或运营方搜索。</div></div>`;
        }
        if (loading && stations.length) html += '<div class="row footnote secondary" style="justify-content:center;gap:8px;padding:10px"><span class="spinner sm"></span>正在更新结果…</div>';
        html += stations.map((station) => {
          const isSaved = savedIDs.has(station.station_id);
          return `<button class="station-row" data-add="${esc(station.station_id)}" ${isSaved ? 'disabled' : ''}>
            <span style="color:var(${isSaved ? '--sys-green' : '--sys-teal'})">${icon(isSaved ? 'checkcircle' : 'pluscircle')}</span>
            <span class="stack" style="gap:4px;min-width:0;flex:1"><span class="headline">${esc(station.station_name)}</span>
              <span class="caption mono secondary ellip">${esc(station.station_id)}</span>
              ${station.station_address ? `<span class="caption secondary lines2">${esc(station.station_address)}</span>` : ''}</span>
            ${isSaved ? '<span class="caption secondary">已添加</span>' : ''}</button>`;
        }).join('');
        if (error) html += `<div class="footnote c-red" style="padding:12px 16px">${esc(error)}</div>`;
        list.innerHTML = html;
      };
      const load = async (delay) => {
        const mine = ++token;
        const query = input.value.trim();
        if (delay && query) { await sleep(300); if (mine !== token) return; }
        loading = true; error = null; render();
        try {
          const data = await api(`api/v1/stations?limit=200&offset=0${query ? `&q=${encodeURIComponent(query)}` : ''}`);
          if (mine !== token) return;
          stations = data.items || [];
        } catch (err) {
          if (mine !== token) return;
          error = errText(err);
          stations = [];
        } finally {
          if (mine === token) { loading = false; render(); }
        }
      };
      input.addEventListener('input', () => { clearTimeout(debounce); debounce = setTimeout(() => load(true), 0); });
      list.addEventListener('click', (e) => {
        const btn = e.target.closest('[data-add]');
        if (!btn || btn.disabled) return;
        const station = stations.find((item) => item.station_id === btn.dataset.add);
        if (!station) return;
        Station.addSaved({ id: station.station_id, name: station.station_name, address: station.station_address || null });
        Station.select(station.station_id);
        sheet.close();
      });
      load(false);
    },
  });
}

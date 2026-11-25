'use strict';
/* 行程、充电、换电记录相关页面：对应 App 的 VehicleTripViews / VehicleChargingViews / VehicleSwapViews。 */

/* ---------- 行程 ---------- */
function tripLocationName(loc) {
  if (!loc) return null;
  for (const key of ['poi', 'address', 'road_name', 'town', 'district', 'city', 'province']) {
    const value = loc[key];
    if (typeof value === 'string' && value.trim()) return value;
  }
  return null;
}

function tripCardHTML(trip, showsDate) {
  const started = parseDate(trip.started_at);
  const ended = parseDate(trip.ended_at);
  const startName = tripLocationName(trip.start_location);
  const endName = tripLocationName(trip.end_location);
  const stopTime = (date) => {
    if (!date || !started) return '';
    const text = sameDay(started, date) ? fmtTime(date) : `${date.getMonth() + 1}月${date.getDate()}日 ${fmtTime(date)}`;
    return `<span class="caption num secondary" style="white-space:nowrap">${text}</span>`;
  };
  const metrics = [];
  if (trip.is_combined) metrics.push(`<span class="label">${icon('clock')}${durationLabel(trip.duration_minutes)}</span>`);
  if (isNum(trip.average_speed_kph)) metrics.push(`<span class="label">${icon('gauge')}均速 ${trip.average_speed_kph.toFixed(0)} km/h</span>`);
  if (isNum(trip.energy_consumed_kwh)) metrics.push(`<span class="label">${icon('bolt')}耗电 ${trip.energy_consumed_kwh.toFixed(2)} kWh</span>`);
  if (isNum(trip.average_energy_consumption_kwh_per_100km)) metrics.push(`<span class="label">${icon('leaf')}${trip.average_energy_consumption_kwh_per_100km.toFixed(1)} kWh/100km</span>`);
  if (trip.energy_consumed_kwh == null && trip.average_energy_consumption_kwh_per_100km == null) metrics.push('<span class="tertiary">能耗暂无数据</span>');
  return `<div class="card r24 p20 stack trip" style="gap:18px">
    <div class="row">
      <div class="stack" style="gap:6px"><span class="subhead medium num">${showsDate ? fmtDate(started) : `${fmtTime(started)} 出发`}</span>
        ${trip.is_combined
    ? `<span class="label caption2 secondary">${icon('link')}合并行程</span>`
    : `<span class="label caption secondary">${icon('clock')}${durationLabel(trip.duration_minutes)}</span>`}</div>
      <span class="spacer"></span><span class="dist rounded num">${distanceLabel(trip.distance_kilometers)}</span>
    </div>
    <div class="route"><div class="rail"><i class="o"></i><i class="l"></i><i class="s"></i></div>
      <div class="stops">
        <div class="stop"><span class="n lines2">${esc(startName || '起点待更新')}</span>${stopTime(started)}</div>
        <div class="stop"><span class="n lines2">${esc(endName || '终点待更新')}</span>${endName ? stopTime(ended) : ''}</div>
      </div></div>
    <div class="metrics">${metrics.join('')}</div>
  </div>`;
}

function tripsListPage(trips) {
  return {
    title: '全部行程',
    contentClass: 'tight',
    build(page) {
      const groups = new Map();
      for (const trip of trips) {
        const started = parseDate(trip.started_at);
        if (!started) continue;
        const day = startOfDay(started).getTime();
        if (!groups.has(day)) groups.set(day, []);
        groups.get(day).push(trip);
      }
      const days = Array.from(groups.keys()).sort((a, b) => b - a);
      page.content.innerHTML = days.map((day) => {
        const date = new Date(day);
        const list = groups.get(day).sort((a, b) => parseDate(b.started_at) - parseDate(a.started_at));
        return `<div class="subhead semi secondary num" style="padding-top:8px">${fmtDate(date)} · ${WEEKDAYS[date.getDay()]}</div>${list.map((trip) => tripCardHTML(trip, false)).join('')}`;
      }).join('');
    },
  };
}

/* ---------- 充电记录 ---------- */
function sessionDurationLabel(seconds) {
  const minutes = Math.max(1, Math.ceil((seconds || 0) / 60));
  if (minutes >= 60) return `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分`;
  return `${minutes} 分钟`;
}
function chargingSessionRowHTML(session, extraClass = '') {
  const soc = isNum(session.start_soc) && isNum(session.end_soc)
    ? `${session.start_soc.toFixed(0)}% → ${session.end_soc.toFixed(0)}%` : 'SOC --';
  return `<button class="rec-row ${extraClass}" data-act="session" data-id="${esc(session.id)}">
    <span class="rec-icon" style="color:var(--sys-green)">${icon('batterybolt')}</span>
    <div class="mid"><span class="subhead semi num">${fmtDateTime(parseDate(session.started_at))}</span>
      <div class="meta"><span class="label">${icon('battery')}${soc}</span><span class="label">${icon('clock')}${sessionDurationLabel(session.duration_seconds)}</span></div></div>
    <div class="trail">${isNum(session.peak_power_watts) ? `<span class="subhead semi num">${(session.peak_power_watts / 1000).toFixed(1)} kW</span>` : ''}
      <span class="caption2 secondary">${session.sample_count} 点</span></div>
  </button>`;
}

const ChargingRecordsListPage = {
  title: '充电记录',
  build(page) {
    const render = () => {
      const s = Vehicle.s;
      if (!s.sessions.length && !s.err.sessions) {
        page.content.innerHTML = `<div class="unavailable pt80">${icon('batterybolt')}<div class="t">暂无充电记录</div><div class="d">完成一次后端采集的充电会话后会显示在这里。</div></div>`;
        return;
      }
      page.content.innerHTML = `${s.err.sessions ? sectionErrorHTML(s.err.sessions) : ''}
        <div class="list-group">${s.sessions.map((session) => chargingSessionRowHTML(session, 'li')).join('')}</div>`;
    };
    delegate(page.content, {
      session: (el) => {
        const session = Vehicle.s.sessions.find((item) => item.id === el.dataset.id);
        if (session) Nav.push(chargingCurvePage(session));
      },
    });
    render();
    page.onCleanup(Vehicle.on((keys) => { if (keys.has('sessions') || keys.has('errors')) render(); }));
    if (!Vehicle.s.sessions.length) Vehicle.refreshChargingSessions();
  },
  refresh() { return Vehicle.refreshChargingSessions(); },
};

/* ---------- 充电曲线（ChargingCurveView） ---------- */
const CHART_METRICS = {
  soc: { label: 'SOC', colorVar: '--green', icon: 'battery', value: (p) => p.soc, text: (v) => `${v.toFixed(0)}%` },
  power: { label: '功率', colorVar: '--violet', icon: 'bolt', value: (p) => (isNum(p.powerW) ? p.powerW / 1000 : null), text: (v) => `${v.toFixed(1)} kW` },
  voltage: { label: '电压', colorVar: '--blue', icon: 'wave', value: (p) => p.voltage, text: (v) => `${v.toFixed(1)} V` },
  current: { label: '电流', colorVar: '--amber', icon: 'arrowcircle', value: (p) => p.current, text: (v) => `${v.toFixed(1)} A` },
};
const metricText = (key, sample) => {
  const value = CHART_METRICS[key].value(sample);
  return isNum(value) ? CHART_METRICS[key].text(value) : '--';
};
function mapChargingSamples(items) {
  return (items || []).map((it) => {
    const d = parseDate(it.sampled_at);
    return d ? { t: d.getTime(), soc: it.soc ?? null, powerW: it.charging_power ?? null, voltage: it.charging_voltage ?? null, current: it.charging_current ?? null } : null;
  }).filter(Boolean).sort((a, b) => a.t - b.t);
}
/** 二分查找最接近给定时间的采样（ChargingSample.nearest）。 */
function nearestSample(samples, time) {
  if (!samples.length) return null;
  let lower = 0;
  let upper = samples.length;
  while (lower < upper) {
    const middle = lower + Math.floor((upper - lower) / 2);
    if (samples[middle].t < time) lower = middle + 1; else upper = middle;
  }
  if (lower === 0) return samples[0];
  if (lower === samples.length) return samples[samples.length - 1];
  const before = samples[lower - 1];
  const after = samples[lower];
  return time - before.t <= after.t - time ? before : after;
}
function niceStep(raw) {
  if (!(raw > 0)) return 1;
  const power = 10 ** Math.floor(Math.log10(raw));
  const unit = raw / power;
  return (unit <= 1 ? 1 : unit <= 2 ? 2 : unit <= 2.5 ? 2.5 : unit <= 5 ? 5 : 10) * power;
}
/** Catmull-Rom 样条 → 三次贝塞尔路径。 */
function smoothPath(points) {
  if (!points.length) return '';
  if (points.length < 3) return `M${points.map((p) => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join('L')}`;
  let d = `M${points[0][0].toFixed(1)},${points[0][1].toFixed(1)}`;
  for (let i = 0; i < points.length - 1; i++) {
    const p0 = points[i - 1] || points[i];
    const p1 = points[i];
    const p2 = points[i + 1];
    const p3 = points[i + 2] || p2;
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6];
    const c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
    d += `C${c1[0].toFixed(1)},${c1[1].toFixed(1)} ${c2[0].toFixed(1)},${c2[1].toFixed(1)} ${p2[0].toFixed(1)},${p2[1].toFixed(1)}`;
  }
  return d;
}

/**
 * 折线 + 面积图，横向拖动选择点位（chartXSelection）。
 * 返回 {setSelection(sample|null)}；onSelect(time|null) 在拖动中持续回调。
 */
function renderCurveChart(holder, samples, metricKey, onSelect) {
  const metric = CHART_METRICS[metricKey];
  const color = cssVar(metric.colorVar);
  const width = Math.max(240, holder.clientWidth || 320);
  const height = 260;
  const m = { l: 36, r: 10, t: 10, b: 22 };
  const plotW = width - m.l - m.r;
  const plotH = height - m.t - m.b;
  const data = samples.map((s) => ({ t: s.t, v: metric.value(s) })).filter((p) => isNum(p.v));
  let t0 = samples.length ? samples[0].t : 0;
  let t1 = samples.length ? samples[samples.length - 1].t : 1;
  if (t1 - t0 < 1000) { t0 -= 30000; t1 += 30000; }
  const maxV = data.reduce((acc, p) => Math.max(acc, p.v), 0);
  const step = niceStep((maxV || 1) / 4);
  const top = Math.max(step, Math.ceil((maxV || 1) / step) * step);
  const x = (t) => m.l + ((t - t0) / (t1 - t0)) * plotW;
  const y = (v) => m.t + plotH - (v / top) * plotH;
  const pts = data.map((p) => [x(p.t), y(p.v)]);
  const line = smoothPath(pts);
  const area = pts.length ? `${line}L${pts[pts.length - 1][0].toFixed(1)},${(m.t + plotH).toFixed(1)}L${pts[0][0].toFixed(1)},${(m.t + plotH).toFixed(1)}Z` : '';
  let grid = '';
  for (let v = 0; v <= top + 1e-9; v += step) {
    const yy = y(v).toFixed(1);
    grid += `<line class="grid" x1="${m.l}" x2="${width - m.r}" y1="${yy}" y2="${yy}"/><text class="axis" x="${m.l - 6}" y="${yy}" text-anchor="end" dominant-baseline="middle">${Number(v.toFixed(2))}</text>`;
  }
  for (let i = 0; i <= 4; i++) {
    const t = t0 + ((t1 - t0) * i) / 4;
    const xx = x(t).toFixed(1);
    grid += `<line class="grid" x1="${xx}" x2="${xx}" y1="${m.t}" y2="${m.t + plotH}"/><text class="axis" x="${xx}" y="${height - 5}" text-anchor="${i === 0 ? 'start' : i === 4 ? 'end' : 'middle'}">${fmtTime(new Date(t))}</text>`;
  }
  const gid = `g${Math.random().toString(36).slice(2, 8)}`;
  holder.innerHTML = `<svg viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" role="img" aria-label="${metric.label}曲线">
    <defs><linearGradient id="${gid}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${color}" stop-opacity="0.24"/><stop offset="1" stop-color="${color}" stop-opacity="0.02"/></linearGradient></defs>
    ${grid}
    ${area ? `<path d="${area}" fill="url(#${gid})"/>` : ''}
    ${line ? `<path d="${line}" fill="none" stroke="${color}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>` : ''}
    <g class="sel"></g></svg>`;
  const sel = holder.querySelector('.sel');
  const timeAt = (clientX) => {
    const rect = holder.getBoundingClientRect();
    const px = ((clientX - rect.left) / rect.width) * width;
    return t0 + (clamp(px - m.l, 0, plotW) / plotW) * (t1 - t0);
  };
  let dragging = false;
  holder.onpointerdown = (e) => { dragging = true; try { holder.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ } onSelect(timeAt(e.clientX)); };
  holder.onpointermove = (e) => { if (dragging || e.pointerType === 'mouse') onSelect(timeAt(e.clientX)); };
  const release = () => { if (dragging) { dragging = false; onSelect(null); } };
  holder.onpointerup = release;
  holder.onpointercancel = release;
  holder.onpointerleave = (e) => { if (e.pointerType === 'mouse' && !dragging) onSelect(null); };
  return {
    setSelection(sample) {
      const value = sample ? metric.value(sample) : null;
      if (!sample || !isNum(value)) { sel.innerHTML = ''; return; }
      const sx = x(sample.t).toFixed(1);
      sel.innerHTML = `<line class="rule" x1="${sx}" x2="${sx}" y1="${m.t}" y2="${m.t + plotH}"/><circle cx="${sx}" cy="${y(value).toFixed(1)}" r="5.2" fill="${color}"/>`;
    },
  };
}

function chargingCurvePage(session) {
  const live = !session;
  return {
    title: live ? '本次充电' : '充电详情',
    contentClass: 'tight',
    build(page) {
      const st = page.state;
      Object.assign(st, { metric: 'soc', selectedTime: null, samples: live ? mapChargingSamples(Vehicle.s.samples) : [], loading: !live, error: null, chart: null, pollToken: 0 });
      page.content.innerHTML = `<div data-el="head"></div><div data-el="error" hidden></div><div data-el="empty" hidden></div>
        <div data-el="body" class="stack" style="gap:18px" hidden>
          <div data-el="picker"></div>
          <div class="card stack" style="gap:12px">
            <div class="row base"><span class="headline" data-el="chart-title"></span><span class="spacer"></span><span class="title3 bold num" data-el="chart-value"></span></div>
            <div class="chart" data-el="chart"></div>
            <div class="label caption secondary">${icon('hand')}在曲线上左右拖动，可查看对应时间的全部点位数据</div>
          </div>
          <div class="card stack" style="gap:14px" data-el="point"></div>
        </div>`;
      const el = (name) => page.content.querySelector(`[data-el="${name}"]`);
      const isCharging = () => live && Vehicle.s.dashboard && Vehicle.s.dashboard.chargeStateCode === 1;
      const chosen = () => (st.selectedTime == null ? st.samples[st.samples.length - 1] : nearestSample(st.samples, st.selectedTime)) || null;

      const renderHead = () => {
        const first = st.samples[0];
        const last = st.samples[st.samples.length - 1];
        const title = live ? (isCharging() ? '充电进行中' : '本次充电已结束') : '历史充电记录';
        let detail;
        if (first && last) {
          const range = live
            ? `${fmtTime(new Date(first.t))} 开始 · 已采集 ${st.samples.length} 个点`
            : `${fmtMDHMS(new Date(first.t))} – ${fmtMDHMS(new Date(last.t))}`;
          detail = `<span class="subhead secondary num">${range}</span>${isNum(first.soc) && isNum(last.soc) ? `<span class="caption num c-green">SOC ${first.soc.toFixed(0)}% → ${last.soc.toFixed(0)}%</span>` : ''}`;
        } else {
          detail = `<span class="subhead secondary">${live ? '曲线将随车辆采样实时积累' : '正在读取该次充电曲线'}</span>`;
        }
        el('head').innerHTML = `<div class="card p18 row chg-head" style="gap:16px"><span class="icon">${icon('batterybolt')}</span>
          <div class="stack" style="gap:4px;min-width:0"><span class="title3 bold">${title}</span>${detail}</div></div>`;
      };
      const renderSelection = () => {
        const sample = chosen();
        const metric = CHART_METRICS[st.metric];
        el('chart-value').textContent = sample ? metricText(st.metric, sample) : '';
        el('chart-value').style.color = `var(${metric.colorVar})`;
        if (st.chart) st.chart.setSelection(sample);
        el('point').hidden = !sample;
        if (!sample) return;
        const cell = (key) => `<div class="pmetric"><span class="i" style="color:var(${CHART_METRICS[key].colorVar})">${icon(CHART_METRICS[key].icon)}</span>
          <div class="stack" style="gap:2px"><span class="headline num">${metricText(key, sample)}</span><span class="caption secondary">${CHART_METRICS[key].label}</span></div></div>`;
        el('point').innerHTML = `<div class="row"><span class="label headline">${icon('scope')}点位数据</span><span class="spacer"></span>
            <span class="caption num secondary">${fmtMDHMS(new Date(sample.t))}</span></div>
          <div class="grid2">${cell('soc')}${cell('power')}${cell('voltage')}${cell('current')}</div>`;
      };
      const renderChart = () => {
        el('chart-title').textContent = `${CHART_METRICS[st.metric].label}曲线`;
        st.chart = renderCurveChart(el('chart'), st.samples, st.metric, (time) => { st.selectedTime = time; renderSelection(); });
        renderSelection();
      };
      const render = () => {
        renderHead();
        const error = live ? Vehicle.s.err.charging : st.error;
        el('error').hidden = !error;
        el('error').innerHTML = error ? sectionErrorHTML(error) : '';
        const empty = el('empty');
        const has = st.samples.length > 0;
        el('body').hidden = !has;
        empty.hidden = has;
        if (!has) {
          empty.innerHTML = st.loading
            ? '<div class="center-loading" style="min-height:300px"><div class="spinner"></div><span>读取充电曲线…</span></div>'
            : `<div class="unavailable" style="min-height:300px;justify-content:center">${icon('chart')}<div class="t">${live ? '正在等待充电采样' : '暂无曲线采样'}</div>
                <div class="d">${live ? '保持后端运行，新的 SOC、电压、电流和功率点位会自动累积。' : '这条充电记录没有可用的曲线点位。'}</div></div>`;
          return;
        }
        renderChart();
      };
      st.render = render;
      segmented(el('picker'), Object.keys(CHART_METRICS).map((key) => ({ value: key, label: CHART_METRICS[key].label })), st.metric, (value) => {
        st.metric = value;
        st.selectedTime = null;
        renderChart();
      });
      if (window.ResizeObserver) {
        let lastWidth = 0;
        const observer = new ResizeObserver(() => {
          const width = el('chart').clientWidth;
          if (width && Math.abs(width - lastWidth) > 2 && st.samples.length) { lastWidth = width; renderChart(); }
        });
        observer.observe(el('chart'));
        page.onCleanup(() => observer.disconnect());
      }
      const onTheme = () => { if (st.samples.length) renderChart(); };
      document.addEventListener('themechange', onTheme);
      page.onCleanup(() => document.removeEventListener('themechange', onTheme));

      if (live) {
        page.onCleanup(Vehicle.on((keys) => {
          if (keys.has('samples')) { st.samples = mapChargingSamples(Vehicle.s.samples); render(); }
          else if (keys.has('dashboard') || keys.has('errors')) render();
        }));
        st.startPolling = () => {
          const token = ++st.pollToken;
          (async () => {
            while (token === st.pollToken) {
              if (!document.hidden) await Vehicle.refreshChargingData();
              await sleep(isCharging() ? 15000 : 60000);
            }
          })();
        };
        st.stopPolling = () => { st.pollToken += 1; };
        page.onCleanup(() => st.stopPolling());
      } else {
        api(`api/v1/vehicle/charging/sessions/${encodeURIComponent(session.id)}`)
          .then((data) => { st.samples = mapChargingSamples(data.items); })
          .catch((err) => { st.error = errText(err); })
          .finally(() => { st.loading = false; render(); });
      }
      render();
    },
    // 实时曲线只在页面可见时轮询：充电中 15 秒，否则 60 秒。
    appear(page) { if (page.state.startPolling) page.state.startPolling(); },
    disappear(page) { if (page.state.stopPolling) page.state.stopPolling(); },
    refresh: live ? () => Vehicle.refreshChargingData() : undefined,
  };
}

/* ---------- 换电记录 ---------- */
function moneyLabel(amount, currency) {
  const sign = amount < 0 ? '-' : '';
  const magnitude = Math.abs(amount).toFixed(2);
  if (currency == null || currency === 'CNY') return `${sign}¥${magnitude}`;
  return `${sign}${currency} ${magnitude}`;
}
const swapPriceLabel = (event) => (isNum(event.price_amount) ? moneyLabel(event.price_amount, event.price_currency) : (event.price_description || '价格未知'));

function swapEventRowHTML(event, extraClass = '') {
  let energy = '';
  if (isNum(event.exact_energy_kwh)) energy = `<span class="caption secondary">${event.exact_energy_kwh.toFixed(1)} kWh</span>`;
  else if (isNum(event.estimated_energy_kwh)) energy = `<span class="caption c-orange">约 ${event.estimated_energy_kwh.toFixed(1)} kWh</span>`;
  return `<button class="rec-row ${extraClass}" data-act="swap" data-id="${esc(event.id)}">
    <span class="rec-icon" style="color:var(--sys-teal)">${icon('swap')}</span>
    <div class="mid"><span class="subhead semi lines2">${esc(event.station_name || event.station_address || '未知换电站')}</span>
      <span class="caption num secondary">${fmtDateTime(parseDate(event.occurred_at))}</span>
      ${event.outgoing_battery_id && event.incoming_battery_id ? `<span class="caption2 mono secondary ellip">旧 ${esc(event.outgoing_battery_id)} → 新 ${esc(event.incoming_battery_id)}</span>` : ''}</div>
    <div class="trail"><span class="subhead semi num">${esc(swapPriceLabel(event))}</span>${energy}</div>
  </button>`;
}

function activeOrderRowHTML(order) {
  const badges = [];
  if (order.queue_number != null) badges.push(`<span class="qbadge num" style="color:var(--sys-blue)">换电号 ${pad2(order.queue_number)}</span>`);
  if (order.vehicles_ahead != null) {
    badges.push(`<span class="qbadge num" style="color:var(${order.vehicles_ahead <= 1 ? '--sys-green' : '--sys-orange'})">${order.vehicles_ahead === 0 ? '已到你' : `前方 ${order.vehicles_ahead} 辆`}</span>`);
  }
  if (order.estimated_wait_minutes != null) {
    badges.push(`<span class="qbadge num secondary">${order.estimated_wait_source === 'swap_order_status' ? `预计等待 ${order.estimated_wait_minutes} 分钟` : `预计约 ${order.estimated_wait_minutes} 分钟`}</span>`);
  }
  const notify = QueueNotify.enabled();
  return `<div class="stack" style="gap:10px">
    <div class="rec-row"><span class="rec-icon" style="color:var(--sys-orange)">${icon('bolt', 'fill')}</span>
      <div class="mid"><span class="subhead semi lines2">${esc(order.station_name || order.station_address || '正在确认换电站')}</span>
        <span class="caption num secondary">${fmtDateTime(parseDate(order.order_created_at))}</span></div>
      <span class="caption semi c-orange" style="text-align:right">${esc(order.order_status_name || '进行中')}</span></div>
    ${(order.queue_number != null || order.vehicles_ahead != null) ? `<div class="row" style="gap:8px;flex-wrap:wrap">${badges.join('')}</div>` : ''}
    <div class="row" style="gap:8px"><span class="caption2 secondary ellip">${esc(order.queue_status_text || `订单号 ${order.order_no}`)}</span><span class="spacer"></span>
      <button class="link-btn caption" data-act="toggle-notify" style="white-space:nowrap">${icon('bell', notify ? 'fill' : '')}${notify ? '已开启临近提醒' : '临近时提醒我'}</button></div>
    ${order.estimated_wait_source === 'station_queue_estimate' && order.estimated_wait_minutes != null ? '<span class="caption2 tertiary">等待时间按当前前车数 × 约 5 分钟估算</span>' : ''}
  </div>`;
}

/** 换电排队临近提醒（SwapQueueNotificationPlanner + Manager 的网页版）。 */
const QueueNotify = {
  enabledKey: 'nio.swapQueueNotificationsEnabled',
  statePrefix: 'nio.swapQueueState.',
  timers: new Map(),
  leadMinutes: 5,
  enabled() { return Store.get(this.enabledKey, false) === true && 'Notification' in window && Notification.permission === 'granted'; },

  async setEnabled(on) {
    if (!on) {
      Store.set(this.enabledKey, false);
      this.timers.forEach((timer) => clearTimeout(timer));
      this.timers.clear();
      Store.keys(this.statePrefix).forEach((key) => Store.remove(key));
      return false;
    }
    if (!('Notification' in window)) {
      Toast.fail('当前环境不支持系统通知（HA 手机 App 的内嵌页面无法弹出通知，可改用浏览器打开）。');
      return false;
    }
    let permission = Notification.permission;
    if (permission === 'default') {
      try { permission = await Notification.requestPermission(); } catch (e) { permission = 'denied'; }
    }
    const granted = permission === 'granted';
    Store.set(this.enabledKey, granted);
    if (!granted) Toast.fail('通知权限未开启，无法发送临近提醒。请在浏览器设置中允许本站通知。');
    else this.sync(Vehicle.s.orders);
    return granted;
  },

  plan(order) {
    const ahead = order.vehicles_ahead;
    if (ahead == null) return null;
    const queueNumber = order.queue_number != null ? `，换电号 ${pad2(order.queue_number)}` : '';
    const station = order.station_name || '换电站';
    if (ahead <= 1) {
      return { title: ahead === 0 ? '已经到你换电' : '下一辆快到你了', body: `${station}${queueNumber}，请做好进站准备。`, delay: 1, immediate: true };
    }
    if (order.estimated_wait_minutes == null) return null;
    const delayMinutes = Math.max(1, order.estimated_wait_minutes - this.leadMinutes);
    return { title: '换电即将排到你', body: `${station}前方还有 ${ahead} 辆${queueNumber}。`, delay: delayMinutes * 60, immediate: false };
  },

  sync(orders) {
    if (!this.enabled()) return;
    const active = new Set(orders.map((order) => order.order_no));
    for (const [orderNo, timer] of this.timers) {
      if (!active.has(orderNo)) { clearTimeout(timer); this.timers.delete(orderNo); }
    }
    for (const order of orders) {
      const plan = this.plan(order);
      if (!plan) continue;
      const state = `${order.vehicles_ahead ?? -1}|${order.estimated_wait_minutes ?? -1}`;
      const key = `${this.statePrefix}${plan.immediate ? 'notified.' : 'scheduled.'}${order.order_no}`;
      if (Store.get(key) === state && (plan.immediate || this.timers.has(order.order_no))) continue;
      clearTimeout(this.timers.get(order.order_no));
      const timer = setTimeout(() => {
        this.timers.delete(order.order_no);
        try { new Notification(plan.title, { body: plan.body, tag: `swap-queue-${order.order_no}` }); } catch (e) { /* ignore */ }
      }, Math.max(1, plan.delay) * 1000);
      this.timers.set(order.order_no, timer);
      Store.set(key, state);
    }
  },
};
async function toggleQueueNotify() {
  await QueueNotify.setEnabled(!QueueNotify.enabled());
  Vehicle.emit('orders');
}

const SwapRecordsListPage = {
  title: '换电记录',
  build(page) {
    const render = () => {
      const s = Vehicle.s;
      if (!s.orders.length && !s.swaps.length && !s.err.orders && !s.err.swaps) {
        page.content.innerHTML = `<div class="unavailable pt80">${icon('swap')}<div class="t">暂无换电记录</div><div class="d">同步到已完成的换电订单后会显示在这里。</div></div>`;
        return;
      }
      page.content.innerHTML = `${s.err.orders ? sectionErrorHTML(`进行中订单：${s.err.orders}`) : ''}${s.err.swaps ? sectionErrorHTML(s.err.swaps) : ''}
        ${s.orders.length ? `<div><div class="list-header">进行中</div><div class="list-group">${s.orders.map((order) => `<div class="li" style="display:block">${activeOrderRowHTML(order)}</div>`).join('')}</div></div>` : ''}
        ${s.swaps.length ? `<div><div class="list-header">已完成</div><div class="list-group">${s.swaps.map((event) => swapEventRowHTML(event, 'li')).join('')}</div></div>` : ''}`;
    };
    delegate(page.content, {
      swap: (el) => {
        const event = Vehicle.s.swaps.find((item) => item.id === el.dataset.id);
        if (event) Nav.push(swapDetailPage(event));
      },
      'toggle-notify': () => toggleQueueNotify(),
    });
    render();
    page.onCleanup(Vehicle.on((keys) => { if (keys.has('swaps') || keys.has('orders') || keys.has('errors')) render(); }));
    if (!Vehicle.s.swaps.length) Vehicle.refreshSwapEvents();
  },
  refresh() { return Vehicle.refreshSwapEvents(); },
};

function swapDetailPage(initial) {
  return {
    title: '换电详情',
    contentClass: 'tight',
    build(page) {
      let event = initial;
      let loadError = null;
      const line = (key, value, strong = false) => `<div class="detail-line${strong ? ' semi' : ''}"><span class="k">${esc(key)}</span><span class="v">${esc(value)}</span></div>`;
      const battery = (title, iconName, colorVar, id, capacity, soc, date) => `<div class="card stack" style="gap:12px">
          <span class="label headline" style="color:var(${colorVar})">${icon(iconName)}${title}</span>
          ${line('电池编号', id || '未获取')}
          ${isNum(capacity) ? line('电池容量', `${capacity.toFixed(1)} kWh`) : ''}
          ${isNum(soc) ? line('换电时 SOC', `${soc.toFixed(0)}%`) : ''}
          ${date ? line('生产日期', date) : ''}
          ${id ? '' : '<span class="caption secondary">订单数据不含电池编号；只有站端库存变化可唯一匹配时才会补充。</span>'}</div>`;
      const render = () => {
        const energy = isNum(event.exact_energy_kwh) ? `${event.exact_energy_kwh.toFixed(2)} kWh（订单值）`
          : isNum(event.estimated_energy_kwh) ? `约 ${event.estimated_energy_kwh.toFixed(2)} kWh（估算）` : '未获取';
        const confidence = { exact: '精确', high: '高', medium: '中' }[event.confidence] || '低';
        const batterySource = { station_inventory_delta: '换电站库存差分', order_import: '订单导入' }[event.battery_source] || '未获取';
        const energySource = { order_import: '订单值', station_inventory_estimate: '根据容量与 SOC 估算' }[event.energy_source] || '未获取';
        const items = event.payment_items || [];
        page.content.innerHTML = `
          <div class="card p18 stack" style="gap:14px">
            <div class="row top"><div class="stack" style="gap:5px;min-width:0"><span class="title3 bold">${esc(event.station_name || '未知换电站')}</span>
              ${event.station_address ? `<span class="subhead secondary">${esc(event.station_address)}</span>` : ''}</div><span class="spacer"></span>
              <span class="title3 bold num c-amber" style="white-space:nowrap;padding-left:10px">${esc(swapPriceLabel(event))}</span></div>
            ${line('记录时间', fmtDateTime(parseDate(event.occurred_at)))}${line('换电电量', energy)}
            ${event.order_status_name ? line('订单状态', event.order_status_name) : ''}</div>
          ${battery('旧电池（从车上换下）', 'downline', '--amber', event.outgoing_battery_id, event.outgoing_capacity_kwh, event.outgoing_soc_percent, event.outgoing_production_date)}
          ${battery('新电池（换到车上）', 'upline', '--green', event.incoming_battery_id, event.incoming_capacity_kwh, event.incoming_soc_percent, event.incoming_production_date)}
          <div class="card stack" style="gap:12px"><span class="label headline">${icon('listrect')}订单与费用</span>
            ${event.order_no ? line('订单号', event.order_no) : ''}${event.price_description ? line('支付说明', event.price_description) : ''}
            ${items.map((item) => line(item.name, moneyLabel(item.amount, event.price_currency))).join('')}
            ${isNum(event.price_amount) ? `${items.length ? '<hr class="divider">' : ''}${line('实付', moneyLabel(event.price_amount, event.price_currency), true)}` : ''}
            ${!event.order_no && !event.price_description && !items.length ? '<span class="subhead secondary">暂无更多订单费用信息</span>' : ''}</div>
          <div class="card stack" style="gap:10px"><span class="label headline">${icon('shieldcheck')}数据说明</span>
            ${line('记录可信度', confidence)}${line('电池信息来源', batterySource)}${line('电量来源', energySource)}</div>
          ${loadError ? `<div class="label footnote c-red">${icon('warn')}${esc(loadError)}</div>` : ''}`;
      };
      render();
      api(`api/v1/swaps/${encodeURIComponent(initial.id)}`)
        .then((data) => { event = data; })
        .catch((err) => { loadError = errText(err); })
        .finally(render);
    },
  };
}

/* ---------- 充换电记录（energyRecordsPage） ---------- */
const EnergyRecordsPage = {
  title: '充换电记录',
  contentClass: 'tight',
  build(page) {
    const render = () => {
      const s = Vehicle.s;
      const charging = s.dashboard && s.dashboard.chargeStateCode === 1;
      const sessions = s.sessions.slice(0, 3);
      const orders = s.orders.slice(0, 3);
      const swaps = s.swaps.slice(0, 3);
      const joined = (rows) => rows.join('<hr class="divider">');
      const swapRows = [...orders.map(activeOrderRowHTML), ...swaps.map((event) => swapEventRowHTML(event))];
      page.content.innerHTML = `
        ${charging ? `<button class="card p18 row tappable c-green" data-act="live-curve" style="width:100%;text-align:left"><span class="label headline">${icon('wave')}本次充电曲线</span><span class="spacer"></span><span class="caption semi">${icon('chevright')}</span></button>` : ''}
        <div class="card stack" style="gap:14px">
          <div class="row"><span class="label headline">${icon('clock')}充电记录</span><span class="spacer"></span><button class="link-btn" data-act="all-sessions">全部${icon('chevright')}</button></div>
          ${s.err.sessions ? sectionErrorHTML(s.err.sessions) : ''}
          ${sessions.length ? joined(sessions.map((session) => chargingSessionRowHTML(session)))
    : '<div class="subhead secondary" style="min-height:72px;display:flex;align-items:center;justify-content:center;text-align:center">暂无充电记录。后端检测到车辆进入充电状态后，会自动形成可查看曲线的充电会话。</div>'}
        </div>
        <div class="card stack" style="gap:14px">
          <div class="row"><span class="label headline">${icon('swap')}换电记录</span><span class="spacer"></span><button class="link-btn" data-act="all-swaps">全部${icon('chevright')}</button></div>
          ${s.err.swaps ? sectionErrorHTML(s.err.swaps) : ''}${s.err.orders ? sectionErrorHTML(`进行中订单：${s.err.orders}`) : ''}
          ${swapRows.length ? joined(swapRows)
    : '<div class="subhead secondary" style="min-height:72px;display:flex;align-items:center;justify-content:center;text-align:center">暂无已完成的换电记录。后端同步到历史换电订单后，会显示时间、换电站、价格和可核验的电池信息。</div>'}
        </div>`;
    };
    delegate(page.content, {
      'live-curve': () => Nav.push(chargingCurvePage(null)),
      'all-sessions': () => Nav.push(ChargingRecordsListPage),
      'all-swaps': () => Nav.push(SwapRecordsListPage),
      session: (el) => {
        const session = Vehicle.s.sessions.find((item) => item.id === el.dataset.id);
        if (session) Nav.push(chargingCurvePage(session));
      },
      swap: (el) => {
        const event = Vehicle.s.swaps.find((item) => item.id === el.dataset.id);
        if (event) Nav.push(swapDetailPage(event));
      },
      'toggle-notify': () => toggleQueueNotify(),
    });
    render();
    page.onCleanup(Vehicle.on((keys) => {
      if (['dashboard', 'sessions', 'swaps', 'orders', 'errors'].some((key) => keys.has(key))) render();
    }));
  },
  refresh() { return Vehicle.refresh(); },
};

'use strict';
/* 数据页「用车账本」：对应 App 的 EnergyAndCouponsView。每日签到是 HA 版原有功能，保留在页面底部。 */

const SH_OFFSET = 8 * 3600 * 1000; // 统计区间按北京时间（Asia/Shanghai，无夏令时）划分
const DAY_MS = 86400000;
const shStartOfDay = (ms) => Math.floor((ms + SH_OFFSET) / DAY_MS) * DAY_MS - SH_OFFSET;
const shDateInputValue = (ms) => new Date(ms + SH_OFFSET).toISOString().slice(0, 10);
const shFromDateInput = (value) => {
  const [y, m, d] = String(value).split('-').map(Number);
  return Date.UTC(y, m - 1, d) - SH_OFFSET;
};
const isoSeconds = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');

/* ---------- 卡券字段解析（AvailableCoupon） ---------- */
function couponDisplay(value) {
  if (typeof value === 'string') return value.trim();
  if (typeof value === 'number') return String(value);
  if (typeof value === 'boolean') return value ? '是' : '否';
  return null;
}
function couponFind(key, value) {
  if (Array.isArray(value)) {
    for (const nested of value) { const hit = couponFind(key, nested); if (hit) return hit; }
  } else if (value && typeof value === 'object') {
    const direct = couponDisplay(value[key]);
    if (direct) return direct;
    for (const nested of Object.values(value)) { const hit = couponFind(key, nested); if (hit) return hit; }
  }
  return null;
}
const couponFirst = (coupon, keys) => { for (const key of keys) { const hit = couponFind(key, coupon); if (hit) return hit; } return null; };
const couponTitle = (c) => couponFirst(c, ['coupon_name', 'couponName', 'display_name', 'displayName', 'title', 'name']) || '可用卡券';
const couponSubtitle = (c) => couponFirst(c, ['sub_title', 'subtitle', 'coupon_desc', 'description', 'use_scope', 'remark']);
const couponValidity = (c) => couponFirst(c, ['valid_time_desc', 'validity', 'expire_time_desc', 'expire_desc', 'expire_time', 'expired_at', 'end_time']);
const couponID = (c) => couponFirst(c, ['coupon_instance_id', 'coupon_id', 'couponId', 'id', 'code']);

const Insights = {
  s: {
    period: 'month', customFrom: shDateInputValue(Date.now() - 6 * DAY_MS), customTo: shDateInputValue(Date.now()),
    stats: null, statsLoading: false, statsError: null,
    coupons: [], couponAmount: 0, couponTotal: null, couponsMore: false, couponsLoading: false, couponsError: null, nextOffset: 0,
    checkinBusy: false, checkinResult: null,
  },
  didLoad: false,
  render: () => {},

  range() {
    const s = this.s;
    const now = Date.now();
    const today = shStartOfDay(now);
    if (s.period === 'month') {
      const sh = new Date(now + SH_OFFSET);
      return [Date.UTC(sh.getUTCFullYear(), sh.getUTCMonth(), 1) - SH_OFFSET, now];
    }
    if (s.period === '7d') return [today - 6 * DAY_MS, now];
    if (s.period === '30d') return [today - 29 * DAY_MS, now];
    const start = shFromDateInput(s.customFrom);
    const endDay = Math.max(start, shFromDateInput(s.customTo));
    return [start, endDay + DAY_MS];
  },

  async refreshStats() {
    const s = this.s;
    const [from, to] = this.range();
    if (!(to > from) || s.statsLoading) return;
    s.statsLoading = true;
    s.statsError = null;
    this.render();
    try {
      s.stats = await api(`api/v1/energy/stats?from=${encodeURIComponent(isoSeconds(from))}&to=${encodeURIComponent(isoSeconds(to))}`, { timeout: 40000 });
    } catch (err) {
      s.statsError = errText(err);
      Toast.fail(s.statsError);
    } finally {
      s.statsLoading = false;
      this.render();
    }
  },

  async refreshCoupons(reset = true) {
    const s = this.s;
    if (s.couponsLoading || (!reset && !s.couponsMore)) return;
    const offset = reset ? 0 : s.nextOffset;
    s.couponsLoading = true;
    s.couponsError = null;
    this.render();
    try {
      const page = await api(`api/v1/coupons/available?limit=20&offset=${offset}`, { timeout: 40000 });
      const groups = page.coupon_groups || [];
      const items = (page.coupons || []).map((fields, index) => ({
        fields,
        quantity: index < groups.length ? groups[index].count ?? null : null,
        faceValue: index < groups.length ? groups[index].face_value_cny ?? null : null,
      }));
      if (reset) {
        s.coupons = items;
      } else {
        const existing = new Set(s.coupons.map((c) => couponID(c.fields)).filter(Boolean));
        s.coupons = s.coupons.concat(items.filter((c) => { const id = couponID(c.fields); return !id || !existing.has(id); }));
      }
      s.couponAmount = page.amount ?? 0;
      s.couponTotal = page.total_coupon_count ?? null;
      s.couponsMore = page.has_more === true;
      s.nextOffset = (page.offset ?? offset) + items.length;
    } catch (err) {
      s.couponsError = errText(err);
      Toast.fail(s.couponsError);
    } finally {
      s.couponsLoading = false;
      this.render();
    }
  },

  refreshAll() { return Promise.all([this.refreshStats(), this.refreshCoupons()]); },

  async checkIn() {
    const s = this.s;
    if (s.checkinBusy) return;
    s.checkinBusy = true;
    this.render();
    try {
      const result = await api('api/v1/check-in', { method: 'POST', body: {}, timeout: 40000 });
      s.checkinResult = `${result.checked_in ? '签到成功' : '今日已签到'} · 积分 +${result.credit || 0} · 连续 ${result.continuous_days || 0} 天`;
      Vehicle.refreshDashboardOnly();
    } catch (err) {
      if (err.code === 'check_in_already_attempted') s.checkinResult = '今天已经尝试过签到（每天只发送一次）。';
      else Toast.fail(`签到失败：${errText(err)}`);
    } finally {
      s.checkinBusy = false;
      this.render();
    }
  },
};

const InsightsPage = {
  title: '用车账本',
  contentClass: 'g14',

  build(page) {
    const s = Insights.s;
    page.setToolbar(`<button class="nav-btn" data-tb="settings" aria-label="设置">${icon('server')}</button>`);
    page.toolbarEl.querySelector('[data-tb="settings"]').addEventListener('click', () => openSettings());
    page.content.innerHTML = `
      <div class="card data">
        <div class="row"><span class="label headline">${icon('chart')}用车概览</span><span class="spacer"></span><span data-el="range-spin" hidden><span class="spinner"></span></span></div>
        <div data-el="period"></div>
        <div data-el="custom" class="stack" style="gap:10px" hidden>
          <label class="date-row"><span>开始日期</span><input type="date" data-el="from"></label>
          <label class="date-row"><span>结束日期</span><input type="date" data-el="to"></label>
        </div>
        <div class="caption secondary" data-el="range-text"></div>
        <button class="btn-bordered" data-act="update">${icon('refresh')}更新统计</button>
      </div>
      <div data-el="stats-error" hidden></div>
      <div data-el="stats" class="stack" style="gap:14px" hidden></div>
      <div data-el="coupons" class="card data"></div>
      <div data-el="checkin" class="card data"></div>`;
    const el = (name) => page.content.querySelector(`[data-el="${name}"]`);
    const from = el('from');
    const to = el('to');
    const today = () => shDateInputValue(Date.now());
    const syncDates = () => {
      if (s.customTo < s.customFrom) s.customTo = s.customFrom;
      from.value = s.customFrom; to.value = s.customTo;
      from.max = today(); to.max = today(); to.min = s.customFrom;
    };
    syncDates();
    from.addEventListener('change', () => { if (from.value) { s.customFrom = from.value; syncDates(); Insights.render(); } });
    to.addEventListener('change', () => { if (to.value) { s.customTo = to.value; syncDates(); Insights.render(); } });
    segmented(el('period'), [
      { value: 'month', label: '本月至今' }, { value: '7d', label: '近 7 天' }, { value: '30d', label: '近 30 天' }, { value: 'custom', label: '自定义' },
    ], s.period, (value) => { s.period = value; Insights.render(); Insights.refreshStats(); });

    delegate(page.content, {
      update: () => Insights.refreshStats(),
      'retry-stats': () => Insights.refreshStats(),
      'refresh-coupons': () => Insights.refreshCoupons(),
      'more-coupons': () => Insights.refreshCoupons(false),
      checkin: () => Insights.checkIn(),
    });

    const money = (value, covered, total) => (total === 0 || covered > 0 ? `¥${Number(value).toFixed(2)}` : '暂无已知金额');
    const kwh = (value) => `${Number(value).toFixed(2)} kWh`;
    const valueRow = (key, value) => `<div class="value-row"><span class="k">${key}</span><span class="v num">${value}</span></div>`;
    const sourceRow = (key, value, detail) => `<div class="stack" style="gap:4px">${valueRow(key, value)}<span class="caption2 secondary">${detail}</span></div>`;
    const metricCard = (title, value, iconName, colorVar) => `<div class="metric-card" style="color:var(${colorVar})">
      <span class="label caption medium">${icon(iconName)}${title}</span><span class="v num">${value}</span></div>`;
    const errorBanner = (message, act) => `<div class="error-banner">${icon('warn', 'fill')}<span class="msg">${esc(message)}</span><button class="retry" data-act="${act}">重试</button></div>`;

    const statsHTML = (st) => {
      const hasKnown = st.swap_energy_covered_count > 0 || st.charging_energy_kwh_estimated != null;
      const swapEnergy = st.swap_count === 0 || st.swap_energy_covered_count > 0 ? kwh(st.swap_energy_kwh_known) : '暂无精确电量';
      const coverage = st.energy_coverage_complete
        ? `<div class="coverage" style="color:var(--sys-green)">${icon('checkcircle')}<div><div class="t">能量覆盖完整</div><div class="d">区间内换电与充电采样均有可用依据。</div></div></div>`
        : `<div class="coverage" style="color:var(--sys-orange)">${icon('warn')}<div><div class="t">能量覆盖不完整</div><div class="d">以下电量及比例只代表有依据的已知部分，不能视为实际总量。</div></div></div>`;
      const share = st.swap_energy_share_percent_of_known != null && st.charging_energy_share_percent_of_known != null
        ? `<hr class="divider"><span class="subhead semi">${st.energy_coverage_complete ? '能量占比' : '已知部分占比'}</span>
           ${valueRow('换电', `${st.swap_energy_share_percent_of_known.toFixed(1)}%`)}${valueRow('充电', `${st.charging_energy_share_percent_of_known.toFixed(1)}%`)}`
        : '<span class="caption secondary">当前没有足够的已知电量计算占比。</span>';
      return `<div class="grid2">
          ${metricCard('区间换电', `${st.swap_count} 次`, 'swap', '--blue')}
          ${metricCard('本月换电', `${st.current_month_swap_count} 次`, 'calendarclock', '--violet')}
          ${metricCard('实际支付', money(st.actual_paid_cny_known, st.paid_amount_covered_count, st.swap_count), 'card', '--graphite')}
          ${metricCard('优惠券减免', money(st.coupon_discount_cny_known, st.fee_breakdown_covered_count, st.swap_count), 'ticket', '--amber')}
        </div>
        <div class="card data"><span class="label headline">${icon('yen')}费用明细</span>
          ${valueRow('电费', money(st.swap_electricity_fee_cny_known, st.fee_breakdown_covered_count, st.swap_count))}
          ${valueRow('服务费', money(st.swap_service_fee_cny_known, st.fee_breakdown_covered_count, st.swap_count))}
          ${valueRow('电费 + 服务费', money(st.swap_total_fee_cny_known, st.fee_breakdown_covered_count, st.swap_count))}
          <hr class="divider">
          <span class="caption secondary">费用分项覆盖 ${st.fee_breakdown_covered_count}/${st.swap_count} 笔；实付金额覆盖 ${st.paid_amount_covered_count}/${st.swap_count} 笔。未覆盖记录不会按 0 元计入。</span></div>
        <div class="card data"><span class="label headline">${icon('bolt')}能量统计</span>
          ${coverage}
          ${valueRow('换电电量', swapEnergy)}
          ${valueRow('充电电量', st.charging_energy_kwh_estimated != null ? kwh(st.charging_energy_kwh_estimated) : '暂无可估算数据')}
          ${valueRow('已知能量合计', hasKnown ? kwh(st.total_energy_kwh_known) : '暂无已知电量')}
          <hr class="divider">
          ${sourceRow('功率积分', st.charging_segments_from_power > 0 ? kwh(st.charging_energy_kwh_from_power) : '无有效采样段', `${st.charging_segments_from_power} 个采样段`)}
          ${sourceRow('容量 × SOC 估算', st.charging_segments_from_soc > 0 ? kwh(st.charging_energy_kwh_from_soc) : '未使用估算', `${st.charging_segments_from_soc} 个回退采样段`)}
          ${st.charging_segments_uncovered > 0 ? `<span class="caption c-orange">另有 ${st.charging_segments_uncovered} 个充电采样段缺少有效功率，且无法用可信电池容量与 SOC 增量估算。</span>` : ''}
          ${share}
          <span class="caption secondary">纳入计算窗口的充电采样：${st.charging_sample_count} 条；精确换电电量覆盖：${st.swap_energy_covered_count}/${st.swap_count} 笔。</span></div>`;
    };

    const couponRow = (coupon) => {
      const title = couponTitle(coupon.fields);
      const subtitle = couponSubtitle(coupon.fields);
      const validity = couponValidity(coupon.fields);
      return `<div class="coupon"><span class="tk">${icon('ticket')}</span>
        <div class="stack" style="gap:4px;min-width:0;flex:1">
          ${coupon.faceValue != null ? `<span class="title2 bold c-amber num">¥${esc(coupon.faceValue)}</span>` : ''}
          <span class="subhead semi">${esc(title)}</span>
          ${subtitle && subtitle !== title ? `<span class="caption secondary lines3">${esc(subtitle)}</span>` : ''}
          ${validity ? `<span class="label caption2 secondary">${icon('clock')}${esc(validity)}</span>` : ''}</div>
        <div class="stack c-amber" style="align-items:flex-end;gap:3px;padding-left:10px">
          <span class="title2 bold num">${coupon.quantity != null ? esc(coupon.quantity) : '—'}</span>
          <span class="caption2 secondary">${coupon.quantity == null ? '张数待确认' : '张可用'}</span></div></div>`;
    };

    Insights.render = () => {
      const [rangeFrom, rangeTo] = Insights.range();
      // 区间按北京时间划分，说明文字也按北京时间显示；自定义区间的结束时间是次日零点，显示时回到所选的结束日。
      const dateText = (ms) => new Date(ms).toLocaleDateString('zh-CN', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'Asia/Shanghai' });
      el('range-spin').hidden = !s.statsLoading;
      el('custom').hidden = s.period !== 'custom';
      el('range-text').textContent = `${dateText(rangeFrom)} – ${dateText(s.period === 'custom' ? rangeTo - 1 : rangeTo)}`;
      page.content.querySelector('[data-act="update"]').disabled = s.statsLoading;

      const errorEl = el('stats-error');
      errorEl.hidden = !s.statsError;
      errorEl.innerHTML = s.statsError ? errorBanner(s.statsError, 'retry-stats') : '';
      const statsEl = el('stats');
      if (s.stats) { statsEl.hidden = false; statsEl.innerHTML = statsHTML(s.stats); }
      else if (s.statsLoading) { statsEl.hidden = false; statsEl.innerHTML = '<div class="loading-card"><span class="spinner"></span>正在计算区间统计…</div>'; }
      else { statsEl.hidden = true; statsEl.innerHTML = ''; }

      let couponBody;
      if (s.couponsError) couponBody = errorBanner(s.couponsError, 'refresh-coupons');
      else if (s.couponsLoading && !s.coupons.length) couponBody = '<div class="row secondary" style="justify-content:center;gap:10px;padding:24px 0"><span class="spinner"></span>正在读取卡包…</div>';
      else if (!s.coupons.length) couponBody = `<div class="unavailable" style="padding:8px 20px 14px">${icon('ticket')}<div class="t">暂无可用卡券</div><div class="d">新的优惠券会在这里显示。</div></div>`;
      else {
        couponBody = s.coupons.map(couponRow).join('');
        if (s.couponsMore) couponBody += `<button class="btn-bordered block" data-act="more-coupons" ${s.couponsLoading ? 'disabled' : ''}>${s.couponsLoading ? '<span class="spinner sm"></span>加载中…' : '加载更多'}</button>`;
      }
      el('coupons').innerHTML = `<div class="row" style="gap:10px"><span class="label headline">${icon('ticket')}可用卡券</span><span class="spacer"></span>
          ${s.couponAmount > 0 ? `<span class="caption secondary">${s.couponTotal != null ? `共 ${s.couponTotal} 张` : `已加载 ${s.coupons.length} 项 · 总张数待确认`}</span>` : ''}
          <button class="link-btn" data-act="refresh-coupons" aria-label="刷新可用卡券" ${s.couponsLoading ? 'disabled' : ''} style="font-size:18px">${icon('refresh')}</button></div>${couponBody}`;

      const info = Vehicle.s.dashboard && Vehicle.s.dashboard.checkedIn;
      const status = info ? (info.checked ? `今日已签到 · 已连续 ${info.days ?? 0} 天` : `今日未签到 · 已连续 ${info.days ?? 0} 天`) : '签到状态待刷新';
      el('checkin').innerHTML = `<div class="row"><span class="label headline">${icon('gift')}每日签到</span><span class="spacer"></span><span class="caption secondary">${esc(status)}</span></div>
        <button class="btn-bordered block" data-act="checkin" ${s.checkinBusy || (info && info.checked) ? 'disabled' : ''}>${s.checkinBusy ? '<span class="spinner sm"></span>签到中…' : (info && info.checked ? '今日已签到' : '签到')}</button>
        ${s.checkinResult ? `<span class="caption secondary">${esc(s.checkinResult)}</span>` : ''}
        <span class="caption2 tertiary">后端每天最多向蔚来发送一次签到请求。</span>`;
    };
    Insights.render();
    Vehicle.on((keys) => { if (keys.has('dashboard')) Insights.render(); });
  },

  refresh() { return Insights.refreshAll(); },
};

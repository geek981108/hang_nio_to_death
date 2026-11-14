'use strict';
/* 启动与全局设置。 */

/** 设置：App 里的「后端设置」在 HA 中由加载项配置承担，这里只保留前端偏好。 */
function openSettings() {
  openSheet({
    large: true,
    render: (body, sheet) => {
      const control = Vehicle.s.controlConfigured;
      body.innerHTML = `<div class="sheet-nav" data-drag><span class="l"></span><span class="title">设置</span>
          <span class="r"><button class="nav-btn strong" data-done>完成</button></span></div>
        <div class="sheet-scroll"><div class="form">
          <div><div class="list-header">后端连接</div>
            <div class="list-group">
              <div class="li"><span>后端</span><span class="spacer"></span><span class="secondary">HA 加载项内置</span></div>
              <div class="li"><span>车辆控制与换电下单</span><span class="spacer"></span><span style="color:var(${control ? '--sys-green' : '--sys-orange'})">${control ? '已启用' : '未配置车控 Key'}</span></div>
            </div>
            <div class="list-footer">API Key、车控 Key、PIN 与证书都保存在 HA「设置 → 加载项 → 蔚来 NIO Power 后端 → 配置」里，由加载项内的代理注入，浏览器不接触任何密钥。车控 Key 留空会关闭车辆控制和换电下单入口。</div></div>
          <div><div class="list-header">换电站</div>
            <div class="list-group"><label class="li"><span>换电站电池过滤</span><span class="spacer"></span>
              <select data-el="filter">${BATTERY_FILTERS.map((option) => `<option value="${esc(option)}">${esc(option)}</option>`).join('')}</select>
              <span class="chev">${icon('chevright')}</span></label></div>
            <div class="list-footer">换电站页面只统计与你的车匹配的电池档位，顶部数字为该档位可换电池数；选「全部」显示站内所有电池。未设置时按加载项的换电目标档位推断。</div></div>
          <div><div class="list-header">外观</div>
            <div data-el="theme"></div>
            <div class="list-footer">「跟随系统」会随设备的浅色 / 深色模式自动切换。</div></div>
        </div></div>`;
      body.querySelector('[data-done]').addEventListener('click', () => sheet.close());
      const filter = body.querySelector('[data-el="filter"]');
      filter.value = Station.preferredType();
      filter.addEventListener('change', () => Station.setPreferredType(filter.value));
      segmented(body.querySelector('[data-el="theme"]'), [
        { value: 'auto', label: '跟随系统' }, { value: 'light', label: '浅色' }, { value: 'dark', label: '深色' },
      ], Theme.mode(), (value) => Theme.set(value));
    },
  });
}

function boot() {
  Theme.init();
  Nav.init([
    { id: 'vehicle', label: '车辆', icon: 'car', root: VehiclePage },
    {
      id: 'station', label: '换电站', icon: 'boltcar', root: StationPage,
      onSelect: () => Station.startAuto(),
      onDeselect: () => Station.stopAuto(),
    },
    {
      id: 'insights', label: '数据', icon: 'chart', root: InsightsPage,
      onSelect: () => { if (!Insights.didLoad) { Insights.didLoad = true; Insights.refreshAll(); } },
    },
  ]);
  // 与 App 的 URL Scheme 对应：#vehicle / #station / #insights
  const initial = (location.hash || '').replace('#', '').toLowerCase();
  Nav.select(Nav.tabs[initial] ? initial : 'vehicle');
  window.addEventListener('hashchange', () => {
    const target = (location.hash || '').replace('#', '').toLowerCase();
    if (Nav.tabs[target]) Nav.select(target);
  });

  Vehicle.activate();
  if (Nav.current !== 'station') Station.load();
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      Vehicle.stopMonitor();
      Station.stopAuto();
    } else {
      Vehicle.activate();
      if (Nav.current === 'station') Station.startAuto();
    }
  });
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
else boot();

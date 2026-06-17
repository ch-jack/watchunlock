// Copyright (c) 2026 JACK <2518926462@qq.com>

const token = document.querySelector('meta[name="watchunlock-token"]').content;
const $ = (selector) => document.querySelector(selector);

const state = {
  status: null,
  discoveredDevices: [],
};

async function api(path, options = {}) {
  const response = await fetch(path, {
    method: options.method || "GET",
    headers: {
      "content-type": "application/json",
      "x-watchunlock-token": token,
      ...(options.headers || {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const data = await response.json();
  if (!response.ok || data.ok === false) {
    throw new Error(data.error || data.output || `HTTP ${response.status}`);
  }
  return data;
}

function toast(message, kind = "ok") {
  const el = $("#toast");
  el.textContent = message;
  el.className = `toast ${kind}`;
  el.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { el.hidden = true; }, 4200);
}

function setBusy(button, busy) {
  if (!button) return;
  button.disabled = busy;
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;",
  }[ch]));
}

function chip(text, kind = "neutral") {
  return `<span class="chip ${kind}">${escapeHtml(text)}</span>`;
}

function valueOrDash(value) {
  return value === undefined || value === null || value === "" ? "未设置" : String(value);
}

function shortIrk(value) {
  const text = String(value || "");
  return text.length > 16 ? `${text.slice(0, 8)}…${text.slice(-8)}` : text;
}

function sourceLabel(source) {
  if (source === "scan") return "广播";
  if (source === "paired") return "已配对";
  if (source === "irk") return "IRK";
  return source || "设备";
}

function renderSignal(monitor) {
  const signal = monitor?.signal || {};
  const running = Boolean(monitor?.running);
  const hasRssi = Number.isFinite(signal.rssi);
  const waiting = signal.presence === "waiting";
  const ageText = signal.ageSeconds === null || signal.ageSeconds === undefined ? "" : ` · ${signal.ageSeconds}s 前`;
  const presenceText = signal.presence ? ` · ${signal.presence}` : "";
  const waitingText = waiting ? "Monitor 正在运行，等待配置 IRK" : "Monitor 运行中，等待目标广播";

  $("#signalCard").innerHTML = `
    <div class="signal-main">${hasRssi ? `${signal.rssi} dBm` : "-- dBm"}</div>
    <div class="signal-meta">${escapeHtml(signal.address || (running ? waitingText : "Monitor 未运行"))}${escapeHtml(presenceText)}${escapeHtml(ageText)}</div>
    <div class="signal-sub">best ${Number.isFinite(signal.bestRssi) ? `${signal.bestRssi} dBm` : "--"} · hits ${signal.nearHits || 0}</div>
  `;
  $("#signalCard").className = `signal-card ${hasRssi ? (signal.presence || "seen") : (running ? "waiting" : "idle")}`;
}

function renderMonitorControls(monitor) {
  const running = Boolean(monitor?.running);
  const startButton = $("#startMonitorBtn");
  const stopButton = $("#stopMonitorBtn");
  startButton.textContent = running ? "运行中" : "启动";
  startButton.disabled = running;
  stopButton.disabled = !running;
}

function renderStartupControls(startup) {
  const enabled = Boolean(startup?.enabled);
  const toggle = $("#startupToggle");
  toggle.checked = enabled;
  $("#startupStatus").textContent = enabled
    ? `已启用：${startup.taskName || "WatchUnlock Monitor"}`
    : "未启用开机自启动";
}

function isEditingForm(form) {
  return form && document.activeElement && form.contains(document.activeElement);
}

function renderStatus(status, options = {}) {
  const syncForms = options.syncForms !== false;
  state.status = status;
  const config = status.config || {};
  const provider = status.provider || {};
  const monitor = status.monitor || {};
  const startup = status.startup || {};

  $("#statusStrip").innerHTML = [
    chip(config.irk ? "蓝牙已配置" : "未选蓝牙", config.irk ? "ok" : "warn"),
    chip(config.hasCredential ? "凭据已保存" : "未保存凭据", config.hasCredential ? "ok" : "warn"),
    chip(provider.registered ? "Provider 已注册" : "Provider 未注册", provider.registered ? "ok" : "bad"),
    chip(monitor.running ? "Monitor 运行中" : "Monitor 已停止", monitor.running ? "ok" : "warn"),
    chip(startup.enabled ? "自启动已开" : "自启动未开", startup.enabled ? "ok" : "warn"),
  ].join("");

  $("#facts").innerHTML = `
    <dt>配置文件</dt><dd>${escapeHtml(config.exists ? config.path : "未创建")}</dd>
    <dt>当前设备</dt><dd>${escapeHtml(valueOrDash(config.deviceName))}</dd>
    <dt>设备地址</dt><dd>${escapeHtml(valueOrDash(config.deviceAddress))}</dd>
    <dt>IRK</dt><dd class="mono">${escapeHtml(valueOrDash(shortIrk(config.irk)))}</dd>
    <dt>账号</dt><dd>${escapeHtml(valueOrDash(config.username))}</dd>
    <dt>Provider</dt><dd>${provider.registered ? "已注册" : "未注册"}</dd>
    <dt>Monitor</dt><dd>${escapeHtml(monitor.running ? `PID ${monitor.pid}` : "未运行")}</dd>
    <dt>自启动</dt><dd>${escapeHtml(startup.enabled ? "已启用" : "未启用")}</dd>
  `;

  renderMonitorControls(monitor);
  renderStartupControls(startup);
  renderSignal(monitor);

  const deviceForm = $("#deviceForm");
  if (syncForms || !isEditingForm(deviceForm)) {
    deviceForm.deviceName.value = config.deviceName || "";
    deviceForm.deviceAddress.value = config.deviceAddress || "";
    deviceForm.irk.value = config.irk || "";
    deviceForm.nearRssi.value = config.nearRssi ?? -68;
    deviceForm.awayRssi.value = config.awayRssi ?? -86;
    deviceForm.awaySeconds.value = config.awaySeconds ?? 30;
    deviceForm.nearHits.value = config.nearHits ?? 2;
    deviceForm.unlockWindowSeconds.value = config.unlockWindowSeconds ?? 30;
    deviceForm.lockOnAway.checked = config.lockOnAway !== false;
  }

  const selectedText = config.irk
    ? `当前设备：${config.deviceName || "未命名设备"}${config.deviceAddress ? ` · ${config.deviceAddress}` : ""}`
    : "尚未选择设备";
  $("#selectedDevice").textContent = selectedText;

  const credentialForm = $("#credentialForm");
  if (syncForms || !isEditingForm(credentialForm)) {
    credentialForm.username.value = config.username || "";
    credentialForm.unlockWindowSeconds.value = config.unlockWindowSeconds ?? 30;
  }
  $("#providerPath").textContent = provider.dllPath || "";
}

async function loadStatus() {
  const status = await api("/api/status");
  renderStatus(status);
  await loadMonitorLog();
}

function renderList(el, items, renderItem, emptyText) {
  if (!items || items.length === 0) {
    el.innerHTML = `<div class="empty">${escapeHtml(emptyText)}</div>`;
    return;
  }
  el.innerHTML = items.map(renderItem).join("");
}

function readDeviceForm() {
  const form = $("#deviceForm");
  return {
    deviceName: form.deviceName.value.trim(),
    deviceAddress: form.deviceAddress.value.trim(),
    irk: form.irk.value.trim(),
    nearRssi: Number(form.nearRssi.value),
    awayRssi: Number(form.awayRssi.value),
    awaySeconds: Number(form.awaySeconds.value),
    nearHits: Number(form.nearHits.value),
    unlockWindowSeconds: Number(form.unlockWindowSeconds.value),
    lockOnAway: form.lockOnAway.checked,
  };
}

async function saveDeviceBody(body, button = null) {
  setBusy(button, true);
  try {
    const data = await api("/api/device", { method: "POST", body });
    toast(data.output || "蓝牙配置已保存");
    await loadStatus();
    return true;
  } catch (error) {
    toast(error.message, "bad");
    return false;
  } finally {
    setBusy(button, false);
  }
}

async function saveDevice(event) {
  event.preventDefault();
  await saveDeviceBody(readDeviceForm(), event.submitter);
}

function openDeviceDialog() {
  $("#deviceDialog").hidden = false;
}

function closeDeviceDialog() {
  $("#deviceDialog").hidden = true;
}

function renderDevicePicker(devices) {
  const list = $("#devicePickerList");
  renderList(list, devices, (item, index) => {
    const title = item.name || "未命名设备";
    const rssi = Number.isFinite(item.rssi) ? ` · ${item.rssi} dBm` : "";
    const paired = item.paired ? " · 已配对" : "";
    const canUse = Boolean(item.irk);
    const manufacturer = (item.manufacturer || []).join(", ");
    const source = sourceLabel(item.source);
    const match = item.match?.type === "rpa" ? "IRK 匹配随机地址" : (item.irk ? "读取到 IRK" : "未匹配 IRK");
    return `
      <button class="device-option ${canUse ? "ready" : ""}" data-pick-index="${index}">
        <span class="device-top">
          <span>
            <strong>${escapeHtml(title)}</strong>
            <span class="meta">${escapeHtml(`${item.address || "无地址"}${rssi}${paired}`)}</span>
          </span>
          <span class="chip ${canUse ? "ok" : "warn"}">${canUse ? "可自动配置" : "无 IRK"}</span>
        </span>
        <span class="meta">${escapeHtml(`${source} · ${item.kind || "Bluetooth"} · ${match}`)}</span>
        ${item.irk ? `<span class="mono">IRK ${escapeHtml(shortIrk(item.irk))}</span>` : ""}
        ${manufacturer ? `<span class="mono">${escapeHtml(manufacturer)}</span>` : ""}
      </button>
    `;
  }, "没有发现蓝牙设备");

  list.querySelectorAll("[data-pick-index]").forEach((button) => {
    button.addEventListener("click", () => pickDiscoveredDevice(Number(button.dataset.pickIndex), button));
  });
}

async function scanDevices() {
  const button = $("#scanBtn");
  setBusy(button, true);
  $("#deviceDialogHint").textContent = "正在扫描附近广播、读取已配对设备和 IRK";
  state.discoveredDevices = [];
  renderDevicePicker([]);
  openDeviceDialog();

  try {
    const data = await api("/api/discover", {
      method: "POST",
      body: { seconds: 8, rssiMin: -100 },
    });
    state.discoveredDevices = Array.isArray(data.devices) ? data.devices : [];
    renderDevicePicker(state.discoveredDevices);
    $("#deviceDialogHint").textContent = `发现 ${state.discoveredDevices.length} 条目 · 扫描引擎 ${data.engine || "unknown"}`;
    toast(state.discoveredDevices.length ? "扫描完成" : "没有发现蓝牙设备", state.discoveredDevices.length ? "ok" : "bad");
  } catch (error) {
    $("#deviceDialogHint").textContent = "扫描失败";
    renderDevicePicker([]);
    toast(error.message, "bad");
  } finally {
    setBusy(button, false);
  }
}

async function pickDiscoveredDevice(index, button) {
  const item = state.discoveredDevices[index];
  if (!item) return;

  const form = $("#deviceForm");
  form.deviceName.value = item.name || item.address || "Bluetooth device";
  form.deviceAddress.value = item.address || item.irkSourceAddress || "";

  if (!item.irk) {
    toast("这个设备没有匹配到 IRK。请确认它已和 Windows 配对，并用管理员权限启动 Web。", "bad");
    return;
  }

  form.irk.value = item.irk;
  const saved = await saveDeviceBody(readDeviceForm(), button);
  if (saved) {
    closeDeviceDialog();
    toast("已自动填入并保存蓝牙设备");
  }
}

async function deleteDevice() {
  if (!confirm("删除当前配置的蓝牙设备？")) return;
  const button = $("#deleteDeviceBtn");
  setBusy(button, true);
  try {
    const data = await api("/api/device/delete", { method: "POST", body: {} });
    toast(data.output || "蓝牙配置已删除");
    $("#deviceForm").irk.value = "";
    $("#deviceForm").deviceName.value = "";
    $("#deviceForm").deviceAddress.value = "";
    await loadStatus();
  } catch (error) {
    toast(error.message, "bad");
  } finally {
    setBusy(button, false);
  }
}

async function saveCredential(event) {
  event.preventDefault();
  const form = $("#credentialForm");
  const button = event.submitter;
  setBusy(button, true);
  try {
    const data = await api("/api/credential", {
      method: "POST",
      body: {
        username: form.username.value.trim(),
        password: form.password.value,
        unlockWindowSeconds: Number(form.unlockWindowSeconds.value),
      },
    });
    form.password.value = "";
    toast(data.output || "凭据已保存");
    await loadStatus();
  } catch (error) {
    toast(error.message, "bad");
  } finally {
    setBusy(button, false);
  }
}

async function testUnlock(button) {
  if (!confirm("测试会立即锁屏，并在 3 秒后尝试自动解锁。现在开始？")) return;
  setBusy(button, true);
  try {
    await api("/api/credential/test", { method: "POST", body: { delaySeconds: 3 } });
    toast("测试解锁已触发");
  } catch (error) {
    toast(error.message, "bad");
  } finally {
    setBusy(button, false);
  }
}

async function providerAction(path, button) {
  setBusy(button, true);
  try {
    const data = await api(path, { method: "POST", body: {} });
    toast(data.output || "Provider 状态已更新");
    await loadStatus();
  } catch (error) {
    toast(error.message, "bad");
  } finally {
    setBusy(button, false);
  }
}

async function startMonitor() {
  const button = $("#startMonitorBtn");
  setBusy(button, true);
  try {
    await api("/api/monitor/start", { method: "POST", body: {} });
    toast("Monitor 已启动");
    await loadStatus();
  } catch (error) {
    toast(error.message, "bad");
  } finally {
    setBusy(button, false);
  }
}

async function stopMonitor() {
  const button = $("#stopMonitorBtn");
  setBusy(button, true);
  try {
    await api("/api/monitor/stop", { method: "POST", body: {} });
    toast("Monitor 已停止");
    await loadStatus();
  } catch (error) {
    toast(error.message, "bad");
  } finally {
    setBusy(button, false);
  }
}

async function setStartup(enabled, control) {
  setBusy(control, true);
  try {
    const data = await api(enabled ? "/api/startup/enable" : "/api/startup/disable", { method: "POST", body: {} });
    toast(data.output || (enabled ? "已启用开机自启动" : "已关闭开机自启动"));
    await loadStatus();
  } catch (error) {
    toast(error.message, "bad");
    await loadStatus();
  } finally {
    setBusy(control, false);
  }
}

async function loadMonitorLog() {
  try {
    const data = await api("/api/logs/monitor");
    $("#monitorLog").textContent = data.text || "";
  } catch {
    $("#monitorLog").textContent = "";
  }
}

async function refreshMonitorStatus() {
  try {
    const status = await api("/api/status");
    renderStatus(status, { syncForms: false });
    await loadMonitorLog();
  } catch {
  }
}

function wireEvents() {
  $("#refreshStatusBtn").addEventListener("click", loadStatus);
  $("#scanBtn").addEventListener("click", scanDevices);
  $("#deleteDeviceBtn").addEventListener("click", deleteDevice);
  $("#closeDeviceDialogBtn").addEventListener("click", closeDeviceDialog);
  $("#deviceDialog").addEventListener("click", (event) => {
    if (event.target.id === "deviceDialog") closeDeviceDialog();
  });
  $("#deviceForm").addEventListener("submit", saveDevice);
  $("#credentialForm").addEventListener("submit", saveCredential);
  $("#testUnlockBtn").addEventListener("click", (event) => testUnlock(event.currentTarget));
  $("#installProviderBtn").addEventListener("click", (event) => providerAction("/api/provider/install", event.currentTarget));
  $("#uninstallProviderBtn").addEventListener("click", (event) => providerAction("/api/provider/uninstall", event.currentTarget));
  $("#startMonitorBtn").addEventListener("click", startMonitor);
  $("#stopMonitorBtn").addEventListener("click", stopMonitor);
  $("#startupToggle").addEventListener("change", (event) => setStartup(event.currentTarget.checked, event.currentTarget));
}

wireEvents();
loadStatus().catch(error => toast(error.message, "bad"));
setInterval(loadMonitorLog, 3000);
setInterval(refreshMonitorStatus, 1000);

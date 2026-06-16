// Copyright (c) 2026 JACK <2518926462@qq.com>

const token = document.querySelector('meta[name="watchunlock-token"]').content;

const $ = (selector) => document.querySelector(selector);

const state = {
  status: null,
  selectedBluetooth: null,
  pairedDevices: [],
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

function chip(text, kind = "neutral") {
  return `<span class="chip ${kind}">${text}</span>`;
}

function valueOrDash(value) {
  return value === undefined || value === null || value === "" ? "未设置" : String(value);
}

function normalizeBluetoothAddress(value) {
  return String(value || "").replace(/[^0-9a-f]/gi, "").toLowerCase();
}

function updateSelectedDevice() {
  const selected = state.selectedBluetooth;
  $("#selectedDevice").textContent = selected
    ? `已选择：${selected.name || "未命名设备"}${selected.address ? ` · ${selected.address}` : ""}。现在点“读取 IRK”会优先匹配这个设备。`
    : "尚未选择配对设备";
}

function renderSignal(monitor) {
  const signal = monitor?.signal || {};
  const running = Boolean(monitor?.running);
  const hasRssi = Number.isFinite(signal.rssi);
  const ageText = signal.ageSeconds === null || signal.ageSeconds === undefined ? "" : ` · ${signal.ageSeconds}s 前`;
  const presenceText = signal.presence ? ` · ${signal.presence}` : "";
  $("#signalCard").innerHTML = `
    <div class="signal-main">${hasRssi ? `${signal.rssi} dBm` : "-- dBm"}</div>
    <div class="signal-meta">${signal.address || (running ? "Monitor 运行中，等待目标广播" : "Monitor 未运行")}${presenceText}${ageText}</div>
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

function findPairedDeviceByAddress(address) {
  const normalized = normalizeBluetoothAddress(address);
  if (!normalized) return null;
  return state.pairedDevices.find(device => normalizeBluetoothAddress(device.address) === normalized) || null;
}

async function ensurePairedDevices() {
  if (state.pairedDevices.length > 0) return state.pairedDevices;
  try {
    const data = await api("/api/paired");
    state.pairedDevices = Array.isArray(data.devices) ? data.devices : [];
  } catch {
    state.pairedDevices = [];
  }
  return state.pairedDevices;
}

function renderStatus(status) {
  state.status = status;
  const config = status.config || {};
  const provider = status.provider || {};
  const monitor = status.monitor || {};

  $("#statusStrip").innerHTML = [
    chip(config.irk ? "蓝牙已配置" : "未选蓝牙", config.irk ? "ok" : "warn"),
    chip(config.hasCredential ? "凭据已保存" : "未保存凭据", config.hasCredential ? "ok" : "warn"),
    chip(provider.registered ? "Provider 已注册" : "Provider 未注册", provider.registered ? "ok" : "bad"),
    chip(monitor.running ? "Monitor 运行中" : "Monitor 已停止", monitor.running ? "ok" : "warn"),
  ].join("");

  $("#facts").innerHTML = `
    <dt>配置文件</dt><dd>${config.exists ? config.path : "未创建"}</dd>
    <dt>当前设备</dt><dd>${valueOrDash(config.deviceName)}</dd>
    <dt>IRK</dt><dd class="mono">${valueOrDash(config.irk)}</dd>
    <dt>账号</dt><dd>${valueOrDash(config.username)}</dd>
    <dt>Provider</dt><dd>${provider.registered ? "已注册" : "未注册"}</dd>
    <dt>Monitor</dt><dd>${monitor.running ? `PID ${monitor.pid}` : "未运行"}</dd>
  `;
  renderMonitorControls(monitor);
  renderSignal(monitor);

  const deviceForm = $("#deviceForm");
  deviceForm.deviceName.value = config.deviceName || "";
  deviceForm.irk.value = config.irk || "";
  deviceForm.nearRssi.value = config.nearRssi ?? -68;
  deviceForm.awayRssi.value = config.awayRssi ?? -86;
  deviceForm.awaySeconds.value = config.awaySeconds ?? 30;
  deviceForm.nearHits.value = config.nearHits ?? 2;
  deviceForm.unlockWindowSeconds.value = config.unlockWindowSeconds ?? 30;
  deviceForm.lockOnAway.checked = config.lockOnAway !== false;

  const credentialForm = $("#credentialForm");
  credentialForm.username.value = config.username || "";
  credentialForm.unlockWindowSeconds.value = config.unlockWindowSeconds ?? 30;
  $("#providerPath").textContent = provider.dllPath || "";
}

async function loadStatus() {
  const status = await api("/api/status");
  renderStatus(status);
  await loadMonitorLog();
}

function renderList(el, items, renderItem, emptyText) {
  if (!items || items.length === 0) {
    el.innerHTML = `<div class="empty">${emptyText}</div>`;
    return;
  }
  el.innerHTML = items.map(renderItem).join("");
}

async function loadKeys() {
  const button = $("#loadKeysBtn");
  setBusy(button, true);
  try {
    await ensurePairedDevices();
    const data = await api("/api/keys");
    const selectedAddress = normalizeBluetoothAddress(state.selectedBluetooth?.address);
    const keys = [...(data.keys || [])].map(item => ({
      ...item,
      pairedDevice: findPairedDeviceByAddress(item.device),
      isSelectedMatch: selectedAddress && normalizeBluetoothAddress(item.device) === selectedAddress,
    })).sort((left, right) => Number(right.isSelectedMatch) - Number(left.isSelectedMatch));
    renderList($("#keyList"), keys, (item, index) => `
      <div class="item ${item.isSelectedMatch ? "selected" : ""}">
        <div class="item-main">
          <div>
            <div class="item-title">${item.pairedDevice?.name || `未知设备 ${index + 1}`}${item.isSelectedMatch ? " · 匹配已选设备" : ""}</div>
            <div class="meta">${item.device || "-"}${item.pairedDevice?.kind ? ` · ${item.pairedDevice.kind}` : ""} · Adapter ${item.adapter || "-"}${state.selectedBluetooth && !item.isSelectedMatch ? " · 与已选设备地址不一致" : ""}</div>
          </div>
          <div class="button-row compact">
            <button class="secondary" data-use-irk="${item.irk}" data-device="${item.device || ""}" data-device-name="${item.pairedDevice?.name || state.selectedBluetooth?.name || ""}">选择</button>
            <button class="secondary" data-use-irk="${item.irkReversed || ""}" data-device="${item.device || ""}" data-device-name="${item.pairedDevice?.name || state.selectedBluetooth?.name || ""}">反向</button>
          </div>
        </div>
        <div class="mono">IRK ${item.irk || ""}</div>
        <div class="mono">反向 ${item.irkReversed || ""}</div>
      </div>
    `, data.output || "没有读到 IRK");
    $("#keyList").querySelectorAll("[data-use-irk]").forEach(button => {
      button.addEventListener("click", () => {
        if (!button.dataset.useIrk) return;
        $("#deviceForm").irk.value = button.dataset.useIrk;
        $("#deviceForm").deviceName.value = button.dataset.deviceName || button.dataset.device || "Paired BLE device";
        toast("已填入 IRK");
      });
    });
    const matchedKey = keys.find(item => item.isSelectedMatch);
    if (matchedKey) {
      $("#deviceForm").irk.value = matchedKey.irk || "";
      $("#deviceForm").deviceName.value = state.selectedBluetooth?.name || matchedKey.device || "Paired BLE device";
      toast("已自动匹配并填入 IRK");
    } else if (state.selectedBluetooth && keys.length > 0) {
      toast("读取到 IRK，但没有找到与已选设备地址一致的项", "bad");
    } else if (data.output && keys.length === 0) {
      toast(data.output, "bad");
    }
  } catch (error) {
    toast(error.message, "bad");
  } finally {
    setBusy(button, false);
  }
}

async function loadPairedDevices() {
  const button = $("#pairedBtn");
  setBusy(button, true);
  try {
    const data = await api("/api/paired");
    state.pairedDevices = Array.isArray(data.devices) ? data.devices : [];
    renderList($("#resultList"), state.pairedDevices, (item, index) => `
      <div class="item">
        <div class="item-main">
          <div>
            <div class="item-title">${item.name || `已配对设备 ${index + 1}`}</div>
            <div class="meta">${item.kind || "Bluetooth"}${item.address ? ` · ${item.address}` : ""} · paired=${item.isPaired} · enabled=${item.isEnabled}</div>
          </div>
          <button class="secondary" data-device-name="${item.name || ""}" data-device-address="${item.address || ""}" data-device-kind="${item.kind || ""}">选择设备</button>
        </div>
        <div class="mono">${item.id || ""}</div>
      </div>
    `, data.output || "Windows 没有返回已配对蓝牙设备");
    $("#resultList").querySelectorAll("[data-device-name]").forEach(button => {
      button.addEventListener("click", () => {
        state.selectedBluetooth = {
          name: button.dataset.deviceName || "Paired Bluetooth device",
          address: button.dataset.deviceAddress || "",
          kind: button.dataset.deviceKind || "",
        };
        $("#deviceForm").deviceName.value = state.selectedBluetooth.name;
        updateSelectedDevice();
        toast("已选择设备，现在点“读取 IRK”匹配密钥");
      });
    });
    toast(state.pairedDevices.length ? "已读取配对设备" : "Windows 没有返回配对设备", state.pairedDevices.length ? "ok" : "bad");
  } catch (error) {
    toast(error.message, "bad");
  } finally {
    setBusy(button, false);
  }
}

async function scanBle() {
  const button = $("#scanBtn");
  setBusy(button, true);
  try {
    const data = await api("/api/scan", {
      method: "POST",
      body: { seconds: 8, rssiMin: -100 },
    });
    renderList($("#resultList"), data.devices, item => `
      <div class="item">
        <div class="item-main">
          <div>
            <div class="item-title">${item.name || "未命名设备"}</div>
            <div class="meta">${item.address} · ${item.rssi} dBm</div>
          </div>
        </div>
        <div class="mono">${(item.manufacturer || []).join(", ")}</div>
      </div>
    `, "没有收到 BLE 广播；已连接设备可能不会广播，请点“已配对”查看 Windows 连接/配对列表");
    toast(data.devices.length ? "扫描完成" : "没有收到 BLE 广播", data.devices.length ? "ok" : "bad");
  } catch (error) {
    toast(error.message, "bad");
  } finally {
    setBusy(button, false);
  }
}

async function testDevice() {
  const form = $("#deviceForm");
  const irk = form.irk.value.trim();
  if (!irk) {
    toast("先填写 IRK", "bad");
    return;
  }
  const button = $("#testDeviceBtn");
  setBusy(button, true);
  try {
    const data = await api("/api/resolve", {
      method: "POST",
      body: { irk, seconds: 20 },
    });
    renderList($("#resultList"), data.matches, item => `
      <div class="item">
        <div class="item-main">
          <div>
            <div class="item-title">MATCH ${item.address}</div>
            <div class="meta">${item.rssi} dBm · ${item.name || "无名称"}</div>
          </div>
        </div>
        <div class="mono">${item.match ? `${item.match.layout}/${item.match.keyOrder}` : ""}</div>
      </div>
    `, "20 秒内没有匹配到这个 IRK");
    if (data.matches.length && data.irkUsed && data.irkUsed !== irk.replace(/[^0-9a-f]/gi, "").toUpperCase()) {
      form.irk.value = data.irkUsed;
      toast("反向 IRK 匹配成功，已自动填入正确 IRK");
    } else {
      toast(data.matches.length ? "已匹配到设备" : "没有匹配到设备", data.matches.length ? "ok" : "bad");
    }
  } catch (error) {
    toast(error.message, "bad");
  } finally {
    setBusy(button, false);
  }
}

function readDeviceForm() {
  const form = $("#deviceForm");
  return {
    deviceName: form.deviceName.value.trim(),
    irk: form.irk.value.trim(),
    nearRssi: Number(form.nearRssi.value),
    awayRssi: Number(form.awayRssi.value),
    awaySeconds: Number(form.awaySeconds.value),
    nearHits: Number(form.nearHits.value),
    unlockWindowSeconds: Number(form.unlockWindowSeconds.value),
    lockOnAway: form.lockOnAway.checked,
  };
}

async function saveDevice(event) {
  event.preventDefault();
  const button = event.submitter;
  setBusy(button, true);
  try {
    const data = await api("/api/device", { method: "POST", body: readDeviceForm() });
    toast(data.output || "蓝牙配置已保存");
    await loadStatus();
  } catch (error) {
    toast(error.message, "bad");
  } finally {
    setBusy(button, false);
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
    renderStatus(status);
    await loadMonitorLog();
  } catch {
  }
}

function wireEvents() {
  $("#refreshStatusBtn").addEventListener("click", loadStatus);
  $("#loadKeysBtn").addEventListener("click", loadKeys);
  $("#pairedBtn").addEventListener("click", loadPairedDevices);
  $("#scanBtn").addEventListener("click", scanBle);
  $("#testDeviceBtn").addEventListener("click", testDevice);
  $("#deleteDeviceBtn").addEventListener("click", deleteDevice);
  $("#deviceForm").addEventListener("submit", saveDevice);
  $("#credentialForm").addEventListener("submit", saveCredential);
  $("#installProviderBtn").addEventListener("click", (event) => providerAction("/api/provider/install", event.currentTarget));
  $("#uninstallProviderBtn").addEventListener("click", (event) => providerAction("/api/provider/uninstall", event.currentTarget));
  $("#startMonitorBtn").addEventListener("click", startMonitor);
  $("#stopMonitorBtn").addEventListener("click", stopMonitor);
}

wireEvents();
updateSelectedDevice();
loadStatus().catch(error => toast(error.message, "bad"));
setInterval(loadMonitorLog, 3000);
setInterval(refreshMonitorStatus, 1000);

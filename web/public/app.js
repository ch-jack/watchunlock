// Copyright (c) 2026 JACK <2518926462@qq.com>

const token = document.querySelector('meta[name="watchunlock-token"]').content;

const $ = (selector) => document.querySelector(selector);

const state = {
  status: null,
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
    const data = await api("/api/keys");
    renderList($("#keyList"), data.keys, (item, index) => `
      <div class="item">
        <div class="item-main">
          <div>
            <div class="item-title">${item.device || `设备 ${index + 1}`}</div>
            <div class="meta">Adapter ${item.adapter || "-"}</div>
          </div>
          <button class="secondary" data-use-irk="${item.irk}" data-device="${item.device || ""}">选择</button>
        </div>
        <div class="mono">${item.irk || ""}</div>
      </div>
    `, data.output || "没有读到 IRK");
    $("#keyList").querySelectorAll("[data-use-irk]").forEach(button => {
      button.addEventListener("click", () => {
        $("#deviceForm").irk.value = button.dataset.useIrk;
        $("#deviceForm").deviceName.value = button.dataset.device || "Paired BLE device";
        toast("已填入 IRK");
      });
    });
    if (data.output && data.keys.length === 0) toast(data.output, "bad");
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
    `, "没有扫描到设备");
    toast("扫描完成");
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
    toast(data.matches.length ? "已匹配到设备" : "没有匹配到设备", data.matches.length ? "ok" : "bad");
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

function wireEvents() {
  $("#refreshStatusBtn").addEventListener("click", loadStatus);
  $("#loadKeysBtn").addEventListener("click", loadKeys);
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
loadStatus().catch(error => toast(error.message, "bad"));
setInterval(loadMonitorLog, 3000);

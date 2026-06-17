"use strict";

// Copyright (c) 2026 JACK <2518926462@qq.com>

const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawn } = require("child_process");

const rootDir = path.resolve(__dirname, "..");
const publicDir = path.join(__dirname, "public");
const runtimeDir = path.join(__dirname, ".runtime");
const psScript = path.join(rootDir, "watchunlock.ps1");
const nativeMonitorExe = path.join(rootDir, "native-monitor", "bin", "x64", "watchunlock-native.exe");
const providerDll = path.join(rootDir, "credential-provider", "bin", "x64", "WatchUnlockCredentialProvider.dll");
const dataRoot = path.join(process.env.ProgramData || path.join(process.env.APPDATA || rootDir, "WatchUnlockCli"), "WatchUnlockCli");
const monitorRuntimeRoot = path.join(process.env.LOCALAPPDATA || dataRoot, "WatchUnlockCli");
const configPath = path.join(dataRoot, "config.json");
const statePath = path.join(dataRoot, "state.json");
const monitorPidPath = path.join(monitorRuntimeRoot, "monitor.pid");
const monitorLogPath = path.join(monitorRuntimeRoot, "monitor.log");
const monitorSignalPath = path.join(monitorRuntimeRoot, "monitor-signal.json");
const port = Number(process.env.WATCHUNLOCK_WEB_PORT || process.argv[2] || 8765);
const host = "127.0.0.1";
const token = crypto.randomBytes(24).toString("hex");
let monitorChild = null;
let startupStatusCache = { at: 0, data: null };

fs.mkdirSync(runtimeDir, { recursive: true });

function sendJson(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

function sendText(res, status, text, contentType = "text/plain; charset=utf-8") {
  res.writeHead(status, {
    "content-type": contentType,
    "cache-control": "no-store",
  });
  res.end(text);
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", chunk => {
      body += chunk;
      if (body.length > 1024 * 1024) {
        reject(new Error("Request body is too large."));
        req.destroy();
      }
    });
    req.on("end", () => {
      if (!body) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(body));
      } catch {
        reject(new Error("Invalid JSON request body."));
      }
    });
    req.on("error", reject);
  });
}

function runCommand(file, args, options = {}) {
  return new Promise((resolve) => {
    const child = spawn(file, args, {
      cwd: rootDir,
      windowsHide: true,
      shell: false,
    });
    let stdout = "";
    let stderr = "";
    const timeoutMs = options.timeoutMs || 30000;
    const timer = setTimeout(() => {
      child.kill();
      stderr += `\nTimed out after ${timeoutMs}ms.`;
    }, timeoutMs);

    child.stdout.on("data", data => { stdout += data.toString(); });
    child.stderr.on("data", data => { stderr += data.toString(); });
    child.on("close", code => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
    if (options.input !== undefined) {
      child.stdin.end(options.input);
    }
  });
}

function runWatchUnlock(args, options = {}) {
  return runCommand("powershell.exe", [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    psScript,
    ...args,
  ], options);
}

function runNativeMonitor(args, options = {}) {
  return runCommand(nativeMonitorExe, args, options);
}

function parseJsonOutput(result, fallback = null) {
  const text = result.stdout.replace(/^\uFEFF/, "").trim();
  if (!text) return fallback;
  try {
    return JSON.parse(text);
  } catch {
    return fallback;
  }
}

function readJsonFile(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, ""));
  } catch {
    return null;
  }
}

function sanitizedConfig() {
  const config = readJsonFile(configPath);
  if (!config) {
    return {
      exists: false,
      path: configPath,
      statePath,
      hasCredential: false,
    };
  }
  const copy = { ...config };
  copy.exists = true;
  copy.path = configPath;
  copy.hasCredential = Boolean(copy.passwordProtected);
  delete copy.passwordProtected;
  return copy;
}

function readPid() {
  try {
    const pid = Number(fs.readFileSync(monitorPidPath, "utf8").trim());
    return Number.isFinite(pid) && pid > 0 ? pid : null;
  } catch {
    return null;
  }
}

function isPidRunning(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function providerStatus() {
  const reg = await runCommand("reg.exe", [
    "query",
    "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Authentication\\Credential Providers\\{B2B7A4C9-6170-4B34-8B95-A4B3E7BBEA6C}",
  ], { timeoutMs: 10000 });
  return {
    registered: reg.code === 0,
    dllExists: fs.existsSync(providerDll),
    dllPath: providerDll,
    registryOutput: reg.stdout.trim(),
  };
}

async function startupStatus() {
  if (startupStatusCache.data && Date.now() - startupStatusCache.at < 5000) {
    return startupStatusCache.data;
  }
  const result = await runWatchUnlock(["startup-status", "-Json"], { timeoutMs: 15000 });
  const data = parseJsonOutput(result, null);
  if (result.code === 0 && data) {
    startupStatusCache = { at: Date.now(), data };
    return data;
  }
  const fallback = {
    exists: false,
    enabled: false,
    taskName: "WatchUnlock Monitor",
    state: "",
    output: `${result.stdout}${result.stderr}`.trim(),
  };
  startupStatusCache = { at: Date.now(), data: fallback };
  return fallback;
}

function monitorStatus() {
  const pid = readPid();
  const childRunning = monitorChild && monitorChild.pid && !monitorChild.killed;
  const effectivePid = pid || (childRunning ? monitorChild.pid : null);
  const running = childRunning || isPidRunning(pid);
  if (pid && !running) {
    try { fs.unlinkSync(monitorPidPath); } catch {}
  }
  const state = readJsonFile(monitorSignalPath) || readJsonFile(statePath) || {};
  const ageSeconds = state.lastSeenAt ? Math.max(0, Math.round(Date.now() / 1000 - Number(state.lastSeenAt))) : null;
  return {
    running,
    pid: running ? effectivePid : null,
    logPath: monitorLogPath,
    signalPath: monitorSignalPath,
    signal: {
      address: state.address || "",
      rssi: Number.isFinite(Number(state.rssi)) ? Number(state.rssi) : null,
      bestRssi: Number.isFinite(Number(state.bestRssi)) ? Number(state.bestRssi) : null,
      presence: state.presence || "",
      nearHits: Number.isFinite(Number(state.nearHits)) ? Number(state.nearHits) : 0,
      lastSeenAt: state.lastSeenAt || null,
      lastSeenIso: state.lastSeenIso || "",
      ageSeconds,
    },
  };
}

function appendLogHeader() {
  try {
    fs.mkdirSync(path.dirname(monitorLogPath), { recursive: true });
    fs.appendFileSync(monitorLogPath, `\n--- monitor start ${new Date().toISOString()} ---\n`, "utf8");
  } catch {
  }
}

function appendMonitorLogLine(text) {
  try {
    fs.mkdirSync(path.dirname(monitorLogPath), { recursive: true });
    fs.appendFileSync(monitorLogPath, `${text}\n`, "utf8");
  } catch {
  }
}

async function startMonitor() {
  const result = await runWatchUnlock(["start-monitor", "-Json"], { timeoutMs: 30000 });
  const data = parseJsonOutput(result, null);
  if (result.code !== 0) {
    throw new Error(`${result.stdout}${result.stderr}`.trim() || "Could not start Monitor.");
  }
  return data || monitorStatus();
}

async function stopMonitor() {
  const result = await runWatchUnlock(["stop-monitor", "-Json"], { timeoutMs: 30000 });
  const data = parseJsonOutput(result, null);
  if (result.code !== 0) {
    throw new Error(`${result.stdout}${result.stderr}`.trim() || "Could not stop Monitor.");
  }
  monitorChild = null;
  return data || monitorStatus();
}

function tailFile(filePath, maxBytes = 24000) {
  try {
    const stat = fs.statSync(filePath);
    const start = Math.max(0, stat.size - maxBytes);
    const fd = fs.openSync(filePath, "r");
    const buffer = Buffer.alloc(stat.size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    fs.closeSync(fd);
    return buffer.toString("utf8");
  } catch {
    return "";
  }
}

function requireToken(req, res) {
  if (req.method === "GET") return true;
  if (req.headers["x-watchunlock-token"] === token) return true;
  sendJson(res, 403, { ok: false, error: "Invalid local session token." });
  return false;
}

function safeInt(value, fallback, min, max) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(n)));
}

function normalizeIrk(value) {
  return String(value || "").replace(/[^0-9a-f]/gi, "").toUpperCase();
}

function reverseHexBytes(hex) {
  const clean = normalizeIrk(hex);
  return clean.match(/../g)?.reverse().join("") || "";
}

function normalizeAddress(value) {
  const clean = String(value || "").replace(/[^0-9a-f]/gi, "").toUpperCase();
  return clean.length === 12 ? clean : "";
}

function hexToBuffer(value, expectedBytes) {
  const clean = String(value || "").replace(/[^0-9a-f]/gi, "");
  if (clean.length !== expectedBytes * 2) return null;
  return Buffer.from(clean, "hex");
}

function reverseBuffer(buffer) {
  return Buffer.from([...buffer].reverse());
}

function zeroBuffer(length) {
  return Buffer.alloc(length);
}

function aesBlock(key, block) {
  try {
    const cipher = crypto.createCipheriv("aes-128-ecb", key, null);
    cipher.setAutoPadding(false);
    return Buffer.concat([cipher.update(block), cipher.final()]);
  } catch {
    return null;
  }
}

function bufferEqual(left, right) {
  return Buffer.isBuffer(left) && Buffer.isBuffer(right) && left.length === right.length && left.equals(right);
}

function resolveRpaAddress(address, irkHex) {
  const addressBytes = hexToBuffer(address, 6);
  const key = hexToBuffer(irkHex, 16);
  if (!addressBytes || !key) return null;

  const keys = [
    { name: "key", bytes: key },
    { name: "reversed-key", bytes: reverseBuffer(key) },
  ];
  const addresses = [
    { name: "display", bytes: addressBytes },
    { name: "reversed-address", bytes: reverseBuffer(addressBytes) },
  ];

  for (const addressCandidate of addresses) {
    const addr = addressCandidate.bytes;
    const layouts = [
      { name: "hash-high/prand-low", prand: addr.subarray(3, 6), hash: addr.subarray(0, 3), rpaByte: 3 },
      { name: "prand-high/hash-low", prand: addr.subarray(0, 3), hash: addr.subarray(3, 6), rpaByte: 0 },
    ];

    for (const layout of layouts) {
      if ((addr[layout.rpaByte] & 0xc0) !== 0x40) continue;
      const prands = [
        { name: "prand", bytes: layout.prand },
        { name: "reversed-prand", bytes: reverseBuffer(layout.prand) },
      ];
      const observedHashes = [
        { name: "hash", bytes: layout.hash },
        { name: "reversed-hash", bytes: reverseBuffer(layout.hash) },
      ];

      for (const keyCandidate of keys) {
        for (const prandCandidate of prands) {
          const blocks = [
            { name: "tail-prand", bytes: Buffer.concat([zeroBuffer(13), prandCandidate.bytes]) },
            { name: "head-prand", bytes: Buffer.concat([prandCandidate.bytes, zeroBuffer(13)]) },
          ];

          for (const blockCandidate of blocks) {
            const encrypted = aesBlock(keyCandidate.bytes, blockCandidate.bytes);
            if (!encrypted) continue;
            const hashes = [
              { name: "tail-hash", bytes: encrypted.subarray(13, 16) },
              { name: "reversed-tail-hash", bytes: reverseBuffer(encrypted.subarray(13, 16)) },
              { name: "head-hash", bytes: encrypted.subarray(0, 3) },
              { name: "reversed-head-hash", bytes: reverseBuffer(encrypted.subarray(0, 3)) },
            ];

            for (const hashCandidate of hashes) {
              for (const observedHash of observedHashes) {
                if (bufferEqual(hashCandidate.bytes, observedHash.bytes)) {
                  return {
                    addressOrder: addressCandidate.name,
                    layout: layout.name,
                    keyOrder: keyCandidate.name,
                    prandOrder: prandCandidate.name,
                    blockMode: blockCandidate.name,
                    hashMode: hashCandidate.name,
                    observedHash: observedHash.name,
                  };
                }
              }
            }
          }
        }
      }
    }
  }

  return null;
}

async function readBluetoothKeys() {
  let result = await runWatchUnlock(["keys", "-Json"], { timeoutMs: 20000 });
  let data = parseJsonOutput(result, null);
  let usedSystem = false;
  if (!Array.isArray(data) || data.length === 0) {
    const systemResult = await runWatchUnlock(["keys-system", "-Json"], { timeoutMs: 45000 });
    const systemData = parseJsonOutput(systemResult, null);
    if (Array.isArray(systemData)) {
      result = systemResult;
      data = systemData;
      usedSystem = true;
    }
  }
  return {
    ok: result.code === 0 && Array.isArray(data),
    keys: Array.isArray(data) ? data : [],
    usedSystem,
    output: `${result.stdout}${result.stderr}`.trim(),
  };
}

async function readPairedDevices() {
  const result = await runWatchUnlock(["paired", "-Json"], { timeoutMs: 20000 });
  const data = parseJsonOutput(result, null);
  return {
    ok: result.code === 0 && Array.isArray(data),
    devices: Array.isArray(data) ? data : [],
    output: `${result.stdout}${result.stderr}`.trim(),
  };
}

async function scanAdvertisements(seconds, rssiMin) {
  const useNative = fs.existsSync(nativeMonitorExe);
  const result = useNative
    ? await runNativeMonitor(["scan", "--seconds", String(seconds), "--rssi-min", String(rssiMin), "--json"], { timeoutMs: (seconds + 8) * 1000 })
    : await runWatchUnlock(["scan", "-Seconds", String(seconds), "-RssiMin", String(rssiMin), "-Json"], { timeoutMs: (seconds + 8) * 1000 });
  const devices = parseJsonOutput(result, []);
  return {
    ok: result.code === 0 && Array.isArray(devices),
    engine: useNative ? "native" : "powershell",
    devices: Array.isArray(devices) ? devices : [],
    output: `${result.stdout}${result.stderr}`.trim(),
  };
}

function findIrkForAddress(address, keys, pairedByAddress) {
  const cleanAddress = normalizeAddress(address);
  if (!cleanAddress) return null;

  for (const key of keys) {
    const keyAddress = normalizeAddress(key.device);
    const pairedDevice = pairedByAddress.get(keyAddress) || null;
    if (keyAddress && keyAddress === cleanAddress && key.irk) {
      return {
        irk: normalizeIrk(key.irk),
        irkReversed: normalizeIrk(key.irkReversed),
        sourceAddress: key.device || "",
        sourceName: pairedDevice?.name || key.device || "",
        pairedDevice,
        match: { type: "identity-address" },
      };
    }

    for (const candidate of [
      { irk: key.irk, variant: "normal" },
      { irk: key.irkReversed, variant: "reversed" },
    ]) {
      const irk = normalizeIrk(candidate.irk);
      if (irk.length !== 32) continue;
      const match = resolveRpaAddress(cleanAddress, irk);
      if (match) {
        return {
          irk,
          irkReversed: candidate.variant === "normal" ? normalizeIrk(key.irkReversed) : normalizeIrk(key.irk),
          sourceAddress: key.device || "",
          sourceName: pairedDevice?.name || key.device || "",
          pairedDevice,
          match: { type: "rpa", variant: candidate.variant, ...match },
        };
      }
    }
  }

  return null;
}

function buildDiscoveredDevices(scanData, pairedData, keyData) {
  const pairedByAddress = new Map();
  for (const device of pairedData.devices || []) {
    const address = normalizeAddress(device.address);
    if (address) pairedByAddress.set(address, device);
  }

  const rows = [];
  const seen = new Set();
  const addRow = (row) => {
    const key = `${row.source}:${normalizeAddress(row.address) || row.id || row.name || rows.length}`;
    if (seen.has(key)) return;
    seen.add(key);
    rows.push(row);
  };

  for (const item of scanData.devices || []) {
    const address = item.address || "";
    const cleanAddress = normalizeAddress(address);
    const pairedDevice = pairedByAddress.get(cleanAddress) || null;
    const matchedKey = findIrkForAddress(address, keyData.keys || [], pairedByAddress);
    addRow({
      source: "scan",
      name: item.name || matchedKey?.sourceName || pairedDevice?.name || "",
      address,
      rssi: Number.isFinite(Number(item.rssi)) ? Number(item.rssi) : null,
      manufacturer: item.manufacturer || [],
      services: item.services || [],
      paired: Boolean(pairedDevice || matchedKey?.pairedDevice),
      kind: pairedDevice?.kind || "BLE",
      id: pairedDevice?.id || "",
      irk: matchedKey?.irk || "",
      irkReversed: matchedKey?.irkReversed || "",
      irkSourceAddress: matchedKey?.sourceAddress || "",
      match: matchedKey?.match || null,
    });
  }

  for (const device of pairedData.devices || []) {
    const matchedKey = findIrkForAddress(device.address, keyData.keys || [], pairedByAddress);
    addRow({
      source: "paired",
      name: device.name || "",
      address: device.address || "",
      rssi: null,
      manufacturer: [],
      services: [],
      paired: Boolean(device.isPaired),
      kind: device.kind || "Bluetooth",
      id: device.id || "",
      irk: matchedKey?.irk || "",
      irkReversed: matchedKey?.irkReversed || "",
      irkSourceAddress: matchedKey?.sourceAddress || "",
      match: matchedKey?.match || null,
      isEnabled: device.isEnabled,
    });
  }

  for (const key of keyData.keys || []) {
    const address = key.device || "";
    const cleanAddress = normalizeAddress(address);
    const pairedDevice = pairedByAddress.get(cleanAddress) || null;
    addRow({
      source: "irk",
      name: pairedDevice?.name || address || "Paired BLE key",
      address,
      rssi: null,
      manufacturer: [],
      services: [],
      paired: Boolean(pairedDevice),
      kind: pairedDevice?.kind || "IRK",
      id: pairedDevice?.id || "",
      irk: normalizeIrk(key.irk),
      irkReversed: normalizeIrk(key.irkReversed),
      irkSourceAddress: address,
      match: { type: "registry-key" },
    });
  }

  return rows.sort((left, right) => {
    const score = (item) => (item.irk ? 1000 : 0) + (item.source === "scan" ? 200 : 0) + (item.paired ? 100 : 0) + (Number.isFinite(item.rssi) ? item.rssi + 127 : 0);
    return score(right) - score(left);
  });
}

async function handleApi(req, res, url) {
  if (!requireToken(req, res)) return;

  if (req.method === "GET" && url.pathname === "/api/status") {
    sendJson(res, 200, {
      ok: true,
      config: sanitizedConfig(),
      provider: await providerStatus(),
      monitor: monitorStatus(),
      startup: await startupStatus(),
      paths: { rootDir, configPath, statePath, providerDll },
    });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/keys") {
    let result = await runWatchUnlock(["keys", "-Json"], { timeoutMs: 20000 });
    let data = parseJsonOutput(result, null);
    let usedSystem = false;
    if ((!Array.isArray(data) || data.length === 0) && /Cannot read Bluetooth key registry path|不允许所请求的注册表访问权|Access is denied/i.test(`${result.stdout}${result.stderr}`)) {
      const systemResult = await runWatchUnlock(["keys-system", "-Json"], { timeoutMs: 45000 });
      const systemData = parseJsonOutput(systemResult, null);
      if (Array.isArray(systemData)) {
        result = systemResult;
        data = systemData;
        usedSystem = true;
      }
    }
    sendJson(res, 200, {
      ok: result.code === 0 && Array.isArray(data),
      keys: Array.isArray(data) ? data : [],
      usedSystem,
      output: `${result.stdout}${result.stderr}`.trim(),
    });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/paired") {
    const result = await runWatchUnlock(["paired", "-Json"], { timeoutMs: 20000 });
    const data = parseJsonOutput(result, null);
    sendJson(res, 200, {
      ok: result.code === 0 && Array.isArray(data),
      devices: Array.isArray(data) ? data : [],
      output: `${result.stdout}${result.stderr}`.trim(),
    });
    return;
  }

  if (req.method === "GET" && url.pathname === "/api/logs/monitor") {
    sendJson(res, 200, { ok: true, text: tailFile(monitorLogPath) });
    return;
  }

  const body = await readRequestBody(req);

  if (req.method === "POST" && url.pathname === "/api/discover") {
    const seconds = safeInt(body.seconds, 8, 1, 60);
    const rssiMin = safeInt(body.rssiMin, -100, -127, 0);
    const [scanData, pairedData, keyData] = await Promise.all([
      scanAdvertisements(seconds, rssiMin),
      readPairedDevices(),
      readBluetoothKeys(),
    ]);
    sendJson(res, 200, {
      ok: scanData.ok || pairedData.ok || keyData.ok,
      engine: scanData.engine,
      devices: buildDiscoveredDevices(scanData, pairedData, keyData),
      scan: { ok: scanData.ok, output: scanData.output },
      paired: { ok: pairedData.ok, output: pairedData.output },
      keys: { ok: keyData.ok, usedSystem: keyData.usedSystem, output: keyData.output },
    });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/scan") {
    const seconds = safeInt(body.seconds, 8, 1, 60);
    const rssiMin = safeInt(body.rssiMin, -100, -127, 0);
    const useNative = fs.existsSync(nativeMonitorExe);
    const result = useNative
      ? await runNativeMonitor(["scan", "--seconds", String(seconds), "--rssi-min", String(rssiMin), "--json"], { timeoutMs: (seconds + 8) * 1000 })
      : await runWatchUnlock(["scan", "-Seconds", String(seconds), "-RssiMin", String(rssiMin), "-Json"], { timeoutMs: (seconds + 8) * 1000 });
    const devices = parseJsonOutput(result, []);
    sendJson(res, 200, { ok: result.code === 0, engine: useNative ? "native" : "powershell", devices: Array.isArray(devices) ? devices : [], output: `${result.stdout}${result.stderr}`.trim() });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/resolve") {
    const irk = normalizeIrk(body.irk);
    if (irk.length !== 32) {
      sendJson(res, 400, { ok: false, error: "IRK must be 16 bytes / 32 hex chars." });
      return;
    }
    const seconds = safeInt(body.seconds, 15, 1, 120);
    const useNative = fs.existsSync(nativeMonitorExe);
    let result = useNative
      ? await runNativeMonitor(["resolve", "--irk", irk, "--seconds", String(seconds), "--json"], { timeoutMs: (seconds + 8) * 1000 })
      : await runWatchUnlock(["resolve", "-Irk", irk, "-Seconds", String(seconds), "-Json"], { timeoutMs: (seconds + 8) * 1000 });
    let matches = parseJsonOutput(result, []);
    let irkUsed = irk;
    let variant = "normal";
    const reversedIrk = reverseHexBytes(irk);
    if ((!Array.isArray(matches) || matches.length === 0) && reversedIrk.length === 32 && reversedIrk !== irk) {
      const reversedResult = useNative
        ? await runNativeMonitor(["resolve", "--irk", reversedIrk, "--seconds", String(seconds), "--json"], { timeoutMs: (seconds + 8) * 1000 })
        : await runWatchUnlock(["resolve", "-Irk", reversedIrk, "-Seconds", String(seconds), "-Json"], { timeoutMs: (seconds + 8) * 1000 });
      const reversedMatches = parseJsonOutput(reversedResult, []);
      if (Array.isArray(reversedMatches) && reversedMatches.length > 0) {
        result = reversedResult;
        matches = reversedMatches;
        irkUsed = reversedIrk;
        variant = "reversed";
      }
    }
    sendJson(res, 200, {
      ok: result.code === 0,
      engine: useNative ? "native" : "powershell",
      matches: Array.isArray(matches) ? matches : [],
      irkUsed,
      variant,
      output: `${result.stdout}${result.stderr}`.trim(),
    });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/device") {
    const irk = normalizeIrk(body.irk);
    if (irk.length !== 32) {
      sendJson(res, 400, { ok: false, error: "IRK must be 16 bytes / 32 hex chars." });
      return;
    }
    const args = [
      "init",
      "-Irk", irk,
      "-NearRssi", String(safeInt(body.nearRssi, -68, -127, 0)),
      "-AwayRssi", String(safeInt(body.awayRssi, -86, -127, 0)),
      "-AwaySeconds", String(safeInt(body.awaySeconds, 30, 5, 600)),
      "-NearHits", String(safeInt(body.nearHits, 2, 1, 20)),
      "-UnlockWindow", String(safeInt(body.unlockWindowSeconds, 30, 5, 300)),
    ];
    if (body.lockOnAway) args.push("-LockOnAway");
    if (body.deviceName) args.push("-DeviceName", String(body.deviceName).slice(0, 120));
    if (body.deviceAddress) args.push("-DeviceAddress", String(body.deviceAddress).slice(0, 64));
    const result = await runWatchUnlock(args, { timeoutMs: 20000 });
    sendJson(res, result.code === 0 ? 200 : 500, { ok: result.code === 0, output: `${result.stdout}${result.stderr}`.trim(), config: sanitizedConfig() });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/device/delete") {
    const result = await runWatchUnlock(["remove-device"], { timeoutMs: 15000 });
    sendJson(res, result.code === 0 ? 200 : 500, { ok: result.code === 0, output: `${result.stdout}${result.stderr}`.trim(), config: sanitizedConfig() });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/credential") {
    const username = String(body.username || "").trim();
    const password = String(body.password || "");
    if (!username || !password) {
      sendJson(res, 400, { ok: false, error: "Username and password are required." });
      return;
    }
    const args = ["set-credential", "-Username", username, "-PasswordStdin", "-UnlockWindow", String(safeInt(body.unlockWindowSeconds, 30, 5, 300))];
    const result = await runWatchUnlock(args, { input: password, timeoutMs: 20000 });
    sendJson(res, result.code === 0 ? 200 : 500, { ok: result.code === 0, output: `${result.stdout}${result.stderr}`.trim(), config: sanitizedConfig() });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/provider/install") {
    const result = await runWatchUnlock(["install-provider"], { timeoutMs: 60000 });
    sendJson(res, result.code === 0 ? 200 : 500, { ok: result.code === 0, output: `${result.stdout}${result.stderr}`.trim(), provider: await providerStatus() });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/provider/uninstall") {
    const result = await runWatchUnlock(["uninstall-provider"], { timeoutMs: 60000 });
    sendJson(res, result.code === 0 ? 200 : 500, { ok: result.code === 0, output: `${result.stdout}${result.stderr}`.trim(), provider: await providerStatus() });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/monitor/start") {
    sendJson(res, 200, { ok: true, monitor: await startMonitor() });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/monitor/stop") {
    sendJson(res, 200, { ok: true, monitor: await stopMonitor() });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/startup/enable") {
    const result = await runWatchUnlock(["enable-startup", "-Json"], { timeoutMs: 30000 });
    const startup = parseJsonOutput(result, null);
    startupStatusCache = { at: Date.now(), data: startup };
    sendJson(res, result.code === 0 ? 200 : 500, {
      ok: result.code === 0,
      startup,
      output: `${result.stdout}${result.stderr}`.trim(),
    });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/startup/disable") {
    const result = await runWatchUnlock(["disable-startup", "-Json"], { timeoutMs: 30000 });
    const startup = parseJsonOutput(result, null);
    startupStatusCache = { at: Date.now(), data: startup };
    sendJson(res, result.code === 0 ? 200 : 500, {
      ok: result.code === 0,
      startup,
      output: `${result.stdout}${result.stderr}`.trim(),
    });
    return;
  }

  sendJson(res, 404, { ok: false, error: "Unknown API route." });
}

function serveStatic(req, res, url) {
  let filePath = url.pathname === "/" ? path.join(publicDir, "index.html") : path.join(publicDir, decodeURIComponent(url.pathname));
  const relative = path.relative(publicDir, filePath);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    sendText(res, 403, "Forbidden");
    return;
  }
  fs.readFile(filePath, (err, data) => {
    if (err) {
      sendText(res, 404, "Not found");
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    const types = {
      ".html": "text/html; charset=utf-8",
      ".css": "text/css; charset=utf-8",
      ".js": "application/javascript; charset=utf-8",
      ".svg": "image/svg+xml",
    };
    let body = data;
    if (path.basename(filePath) === "index.html") {
      body = Buffer.from(data.toString("utf8").replace("__WATCHUNLOCK_TOKEN__", token), "utf8");
    }
    res.writeHead(200, {
      "content-type": types[ext] || "application/octet-stream",
      "cache-control": "no-store",
    });
    res.end(body);
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${host}:${port}`);
    if (url.pathname.startsWith("/api/")) {
      await handleApi(req, res, url);
      return;
    }
    serveStatic(req, res, url);
  } catch (error) {
    sendJson(res, 500, { ok: false, error: error.message || String(error) });
  }
});

server.on("error", (error) => {
  if (error && error.code === "EADDRINUSE") {
    console.error(`WatchUnlock Web is already running or another app is using http://${host}:${port}`);
    console.error(`Open http://${host}:${port} or start with another port: web.cmd ${port + 1}`);
    process.exit(0);
  }
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
});

server.listen(port, host, () => {
  console.log(`WatchUnlock Web is running at http://${host}:${port}`);
  console.log("Press Ctrl+C to stop the web server.");
});

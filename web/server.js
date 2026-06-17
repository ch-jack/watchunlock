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
const configPath = path.join(dataRoot, "config.json");
const statePath = path.join(dataRoot, "state.json");
const monitorPidPath = path.join(runtimeDir, "monitor.pid");
const monitorLogPath = path.join(runtimeDir, "monitor.log");
const monitorSignalPath = path.join(runtimeDir, "monitor-signal.json");
const port = Number(process.env.WATCHUNLOCK_WEB_PORT || process.argv[2] || 8765);
const host = "127.0.0.1";
const token = crypto.randomBytes(24).toString("hex");
let monitorChild = null;

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

function monitorStatus() {
  const pid = readPid();
  const childRunning = monitorChild && monitorChild.pid && !monitorChild.killed;
  const running = childRunning || isPidRunning(pid);
  if (pid && !running) {
    try { fs.unlinkSync(monitorPidPath); } catch {}
  }
  const state = readJsonFile(monitorSignalPath) || readJsonFile(statePath) || {};
  const ageSeconds = state.lastSeenAt ? Math.max(0, Math.round(Date.now() / 1000 - Number(state.lastSeenAt))) : null;
  return {
    running,
    pid: running ? pid : null,
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
  fs.mkdirSync(runtimeDir, { recursive: true });
  fs.appendFileSync(monitorLogPath, `\n--- monitor start ${new Date().toISOString()} ---\n`, "utf8");
}

function appendMonitorLogLine(text) {
  fs.mkdirSync(runtimeDir, { recursive: true });
  fs.appendFileSync(monitorLogPath, `${text}\n`, "utf8");
}

function startMonitor() {
  const current = monitorStatus();
  if (current.running) {
    return current;
  }
  appendLogHeader();
  try { fs.unlinkSync(monitorSignalPath); } catch {}
  const useNative = fs.existsSync(nativeMonitorExe);
  const file = useNative ? nativeMonitorExe : "powershell.exe";
  const args = useNative
    ? [
        "monitor",
        "--config",
        configPath,
        "--log-file",
        monitorLogPath,
        "--signal-state",
        monitorSignalPath,
      ]
    : [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        psScript,
        "monitor",
        "-LogFile",
        monitorLogPath,
        "-SignalStatePath",
        monitorSignalPath,
      ];
  appendMonitorLogLine(`[web][monitor] spawn ${file} ${args.map(arg => `"${arg}"`).join(" ")}`);
  const child = spawn(file, args, {
    cwd: rootDir,
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  monitorChild = child;
  child.stdout.resume();
  child.stderr.on("data", data => appendMonitorLogLine(data.toString().trimEnd()));
  child.on("error", error => {
    appendMonitorLogLine(`[web][monitor] failed to start: ${error.message}`);
  });
  child.on("exit", (code, signal) => {
    appendMonitorLogLine(`[web][monitor] exited code=${code ?? ""} signal=${signal ?? ""}`);
    if (monitorChild === child) monitorChild = null;
    try {
      const currentPid = fs.readFileSync(monitorPidPath, "utf8").trim();
      if (currentPid === String(child.pid)) fs.unlinkSync(monitorPidPath);
    } catch {}
  });
  fs.writeFileSync(monitorPidPath, String(child.pid), "utf8");
  return { running: true, pid: child.pid, logPath: monitorLogPath, engine: useNative ? "native" : "powershell" };
}

async function stopMonitor() {
  const pid = readPid();
  if (!pid) return monitorStatus();
  await runCommand("taskkill.exe", ["/PID", String(pid), "/T", "/F"], { timeoutMs: 10000 });
  if (monitorChild && monitorChild.pid === pid) monitorChild = null;
  try { fs.unlinkSync(monitorPidPath); } catch {}
  return monitorStatus();
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

async function handleApi(req, res, url) {
  if (!requireToken(req, res)) return;

  if (req.method === "GET" && url.pathname === "/api/status") {
    sendJson(res, 200, {
      ok: true,
      config: sanitizedConfig(),
      provider: await providerStatus(),
      monitor: monitorStatus(),
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
    sendJson(res, 200, { ok: true, monitor: startMonitor() });
    return;
  }

  if (req.method === "POST" && url.pathname === "/api/monitor/stop") {
    sendJson(res, 200, { ok: true, monitor: await stopMonitor() });
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

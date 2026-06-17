# WatchUnlock CLI

Copyright (c) 2026 JACK <2518926462@qq.com>

一个无界面的 Windows 蓝牙自动锁屏/解锁实验实现，思路来自 V2EX 帖子里的 ZuUnlock：

https://www.v2ex.com/t/1172240

现在仓库分成两部分：

- `watchunlock.cmd` / `watchunlock.ps1`: 扫描 BLE、用 IRK 识别 Apple 隐私地址、判断靠近/远离、写入解锁状态、远离锁屏。
- `monitor.cmd`: 独立启动后台 Monitor，不启动 Web。
- `credential-provider\`: Windows Credential Provider 原生 DLL，运行在 LogonUI 里，靠近窗口有效时读取配置里的 Windows 账号密码并自动提交。

## 当前能力

- 手机/手表靠近：BLE monitor 识别到目标 IRK 后写入 `%ProgramData%\WatchUnlockCli\state.json`，Credential Provider 在锁屏界面自动提交凭据。
- 手机/手表远离：BLE monitor 在目标消失或信号弱于阈值一段时间后调用 Windows 锁屏。
- Windows 账号密码：通过 `set-credential` 写入配置，密码使用 Windows DPAPI LocalMachine 加密，不明文保存。

## 重要安全说明

这会把 Windows 登录密码加密保存在本机，并安装一个 Credential Provider 自动提交登录凭据。它适合你自己的机器，不适合共享电脑或高安全要求环境。忘记配置、密码错误或 Provider 出问题时，仍然可以在登录界面选择其他登录方式。

## 安装前要求

- Windows 10/11
- PowerShell 5.1+
- BLE 蓝牙适配器
- 目标设备的 IRK
- Visual Studio Build Tools，包含 C++ 桌面开发和 Windows SDK

## 配置

推荐用本地 Web 配置台：

```cmd
web.cmd
```

然后打开：

http://127.0.0.1:8765

页面可以读取已配对 IRK、扫描 BLE、保存/删除当前蓝牙设备、保存 Windows 账号密码、查看 Provider 和 Monitor 状态，并选择是否开机自启动后台 Monitor。

也可以继续使用命令行。

从仓库根目录运行：

```cmd
watchunlock.cmd init -Irk 00112233445566778899AABBCCDDEEFF -NearRssi -68 -AwayRssi -86 -AwaySeconds 30 -LockOnAway
```

保存 Windows 登录账号和密码：

```cmd
watchunlock.cmd set-credential -Username ".\alice"
```

如果是微软账号，常见格式是：

```cmd
watchunlock.cmd set-credential -Username "MicrosoftAccount\name@example.com"
```

如果填写的是纯本地用户名，例如 `Administrator`，程序会自动按本机账号处理并提交为 `COMPUTERNAME\Administrator`。

## 编译并安装 Credential Provider

打开 **x64 Native Tools Command Prompt for VS**：

```cmd
cd /d C:\Users\Administrator\Documents\watchunlock\credential-provider
build.cmd
```

以管理员身份安装：

```cmd
install.cmd
```

也可以从仓库根目录以管理员身份运行：

```cmd
watchunlock.cmd install-provider
```

测试 Credential Provider 是否能用已保存凭据自动解锁：

```cmd
watchunlock.cmd test-unlock
```

这个命令会先校验已保存的 Windows 凭据和 Provider 注册状态，然后立即锁屏，默认 3 秒后写入一次测试解锁窗口。如果自动解锁失败，手动登录后运行 `watchunlock.cmd provider-log` 查看 Provider 是否被 LogonUI 加载、是否收到 unlock state、是否提交失败。可用 `-DelaySeconds 5` 调整锁屏后等待时间。

## 运行

Web 只用于配置，日常监听用独立 Monitor 启动：

```cmd
monitor.cmd
```

也可以用命令启动/停止后台 Monitor：

```cmd
watchunlock.cmd start-monitor
watchunlock.cmd stop-monitor
watchunlock.cmd monitor-status
```

锁屏后，手机/手表靠近并满足 RSSI 阈值时，Monitor 会打开一个短期解锁窗口，Credential Provider 会自动提交配置里的 Windows 凭据。设备远离超过 `AwaySeconds` 后会自动锁屏。

开机自启动只启动后台 Monitor，不启动 Web：

```cmd
watchunlock.cmd enable-startup
watchunlock.cmd disable-startup
watchunlock.cmd startup-status
```

也可以在 Web 页面 Monitor 卡片里勾选“开机自启动 Monitor”。

## 常用命令

扫描附近 BLE 设备：

```cmd
watchunlock.cmd scan -Seconds 20
```

列出 Windows 已配对/已连接过的蓝牙设备：

```cmd
watchunlock.cmd paired
```

尝试从 Windows 蓝牙注册表列出已配对设备 IRK：

```cmd
watchunlock.cmd keys
```

用 IRK 查找目标设备当前滚动地址：

```cmd
watchunlock.cmd resolve -Irk 00112233445566778899AABBCCDDEEFF -Seconds 60
```

自测：

```cmd
watchunlock.cmd selftest
```

卸载 Credential Provider：

```cmd
watchunlock.cmd uninstall-provider
```

## 参数建议

- `NearRssi`: 靠近阈值，常见为 `-55` 到 `-75`。
- `AwayRssi`: 远离保持阈值，建议比 `NearRssi` 小 10 到 20，例如 `-86`。
- `AwaySeconds`: 远离多久锁屏，建议 20 到 60 秒。
- `NearHits`: 连续命中几次靠近阈值后触发，默认 2。
- `UnlockWindow`: 靠近后允许 Credential Provider 自动提交的秒数，默认 30。

## 注意

`scan` 只监听附近设备正在发送的 BLE 广播包。已经连接、已配对、休眠中，或者当前不广播的设备可能不会出现在扫描结果里；这时先用 `paired` 查看 Windows 已知设备，再用 `keys` 读取 IRK，最后用 `resolve` 测试 IRK 是否能匹配实时广播。

Apple 设备会使用 BLE 隐私地址并定期轮换，所以 iPhone / Apple Watch 需要 IRK 才能稳定识别。`keys` 读取 IRK 的注册表位置通常需要管理员或 SYSTEM 权限：

`HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys`

## Native BLE Monitor

PowerShell/WinRT can create a BLE watcher, but on some Windows builds it does not reliably receive advertisement events. The recommended monitor is now the native C++ executable:

```cmd
native-monitor\build.cmd
native-monitor\bin\x64\watchunlock-native.exe scan-test --seconds 8
```

After the native monitor is built, both `web.cmd` and `watchunlock.cmd monitor` automatically prefer `native-monitor\bin\x64\watchunlock-native.exe`. The PowerShell monitor remains as a fallback when the native executable is not present.

The native monitor is designed to stay running. If no IRK is configured yet, it waits and reports `waiting`; after the Web UI saves an IRK, the same monitor process starts detecting the trusted device without being restarted.

In the Web UI, use **扫描选择设备** as the main Bluetooth flow. It combines live BLE advertisements, paired Windows Bluetooth devices, and paired IRK registry keys. When a scanned random address can be resolved by an IRK, the device is marked as available for automatic configuration; clicking it fills and saves the Bluetooth settings.

## CI, Package, Release

GitHub Actions runs on every push to `master` and every pull request:

- build `native-monitor\bin\x64\watchunlock-native.exe`
- build `credential-provider\bin\x64\WatchUnlockCredentialProvider.dll`
- run native and PowerShell core self-tests
- check Web JavaScript syntax
- create a zip package under `dist\`
- update the `latest` prerelease on every successful `master` build

Create a local package:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package.ps1
```

Automatic development release:

- push to `master`
- wait for Actions to pass
- download the zip from the `latest` prerelease

Publish a formal GitHub Release by pushing a version tag:

```cmd
git tag v0.1.0
git push origin v0.1.0
```

Both release zips include the native monitor exe, Credential Provider DLL, Web UI, cmd launchers, and install/uninstall scripts.

# Codex Windows SSH

An unofficial, narrow compatibility patch for connecting the Codex desktop app to SSH hosts whose login shell is Windows PowerShell.

中文摘要：这个补丁让桌面 Codex 自动识别 Windows SSH 主机，Windows 走 PowerShell + `ssh -W`，Linux/macOS 保持官方路径。仓库不包含 OpenAI 的程序、`app.asar` 或反编译源码；补丁只从你本机已安装且签名有效的官方包生成。

## Why this repository is not an `openai/codex` fork

OpenAI publishes the Codex CLI, SDK, and App Server in `openai/codex`, but the desktop UI and its Electron SSH transport are not listed as open-source components. Forking the CLI repository would therefore not change this desktop connection path.

The current desktop build already groups remote work by project and renders the remote host indicator beside the project name. This project deliberately leaves that renderer untouched and patches only the missing Windows SSH transport branch.

- [OpenAI: Remote connections](https://learn.chatgpt.com/docs/remote-connections)
- [OpenAI: Projects](https://learn.chatgpt.com/docs/projects)
- [OpenAI: Open-source Codex components](https://learn.chatgpt.com/docs/open-source)

## Supported desktop builds

| Desktop package | Main-bundle input SHA-256 | Status |
|---|---|---|
| `26.820.7780.0` | `3148e679...5d97e1` | Current; includes upstream remote-project grouping |
| `26.803.10989.0` | `1b4fa622...26712` | Legacy transport baseline |

Unknown bundle hashes fail closed. A Store update cannot silently receive an unreviewed patch.

## Requirements

- Windows with the Microsoft Store Codex desktop package installed
- PowerShell 7 (`pwsh.exe`) and Node.js on the local PC
- A normal OpenSSH alias that already works with `ssh <alias>`
- On a Windows SSH host: OpenSSH Server, PowerShell, and an authenticated Codex CLI with `codex.exe` available through the login environment
- SSH `direct-tcpip` forwarding enabled (used by `ssh -W`)

## Install

Close all Codex/ChatGPT desktop processes before the first patched launch, then run:

```powershell
pwsh -NoProfile -File .\Install-Codex-Windows-SSH.ps1
```

Open the new **Codex** desktop or Start-menu shortcut. It uses the official icon and the same user data, projects, and Codex home as the Store app.

The installer:

1. resolves the currently registered Store package and checks the official executable signature;
2. accepts only a reviewed main-bundle SHA-256;
3. rewrites the ASAR locally and verifies its syntax and integrity blocks;
4. creates an isolated runtime under `%LOCALAPPDATA%\OpenAI\Codex-Windows-SSH\<version>`;
5. when an older user-owned patched runtime exists, hardlinks byte-identical files from it and copies only files changed by the Store update;
6. creates a normal-looking `Codex` shortcut.

The signed WindowsApps package is never modified. Windows does not allow an ordinary user to create hardlinks directly from the protected WindowsApps tree, so a first install requires a regular runtime copy. Later version upgrades reuse the existing user-owned runtime and are much lighter.

## Connection flow

```text
SSH connect
  ├─ remote accepts PowerShell probe → Windows controller
  │    ├─ codex app-server binds remote 127.0.0.1
  │    ├─ one loopback proxy endpoint is announced
  │    └─ desktop connects through ssh -W
  └─ PowerShell missing / non-Windows exit → original POSIX bootstrap unchanged
```

The controller converts stdout chunks with `.toString("utf8")` before splitting lines, fixing the earlier `r.stdout.split is not a function` failure. Both the app server and proxy bind only to remote loopback. Closing the data connection stops the remote child process; there is no manager, PID file, service, or public listener.

## Verify or inspect without installing

```powershell
node .\patch-codex-asar.mjs --self-test
node .\patch-codex-asar.mjs --check "C:\path\to\official\app.asar"
node .\patch-codex-asar.mjs --verify "C:\path\to\patched\app.asar"
```

## Uninstall

Exit the patched desktop app, then run:

```powershell
pwsh -NoProfile -File .\Uninstall-Codex-Windows-SSH.ps1
```

This removes only the owned shortcut and `%LOCALAPPDATA%\OpenAI\Codex-Windows-SSH`. The Store package, user data, `~/.codex`, repositories, and remote hosts are untouched.

## Updating for a new Store build

Do not remove the SHA-256 guard. Audit the new transport bundle, confirm each patch point is unique, add a version profile for any renamed minified helpers, run the self-test and real SSH regressions, and only then add the new hash. `UPSTREAM-DESIGN.patch` documents the source-level change that should ultimately land upstream.

## Legal and project status

This project is not affiliated with or endorsed by OpenAI. It contains original patching/controller code and short transformation anchors only. It does not redistribute OpenAI binaries, packaged archives, extracted bundles, or application source.

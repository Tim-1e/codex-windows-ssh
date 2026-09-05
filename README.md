# Codex Windows SSH

An unofficial, narrow compatibility patch for connecting the Codex desktop app to SSH hosts whose login shell is Windows PowerShell.

中文摘要：这个补丁让桌面 Codex 自动识别 Windows SSH 主机，Windows 走 PowerShell + `ssh -W`，Linux/macOS 保持官方路径。仓库不包含 OpenAI 的程序、`app.asar` 或反编译源码；修复版从本机官方安装或官方 CDN 下载的原包生成，先验证签名，再做结构兼容检查和隔离启动验证。

## Why this repository is not an `openai/codex` fork

OpenAI publishes the Codex CLI, SDK, and App Server in `openai/codex`, but the desktop UI and its Electron SSH transport are not listed as open-source components. Forking the CLI repository would therefore not change this desktop connection path.

The current desktop build already groups remote work by project and renders the remote host indicator beside the project name. This project leaves that project-grouping renderer untouched, adding the missing Windows SSH transport branch and the launch/update compatibility integration described below.

- [OpenAI: Remote connections](https://learn.chatgpt.com/docs/remote-connections)
- [OpenAI: Projects](https://learn.chatgpt.com/docs/projects)
- [OpenAI: Open-source Codex components](https://learn.chatgpt.com/docs/open-source)

## Desktop compatibility

The patcher is not tied to a package version or a full-bundle hash. It discovers the minified SSH helpers and desktop update-menu handler from the official bundle itself, cross-checks repeated bindings, and requires every semantic patch point to occur exactly once. The generated main bundle must then pass Node syntax, patch-structure, and ASAR integrity verification.

This means ordinary Store releases whose SSH transport keeps the same structure can be rebased without adding a version profile. It does **not** mean every future build is accepted blindly: a relevant upstream structural change fails closed and leaves the last working runtime selected. The structural patcher is regression-tested against desktop `26.820.7780.0` and `26.901.1978.0`.

## Remote project grouping

Desktop `26.820.7780.0` already groups saved SSH project folders in the same sidebar **Projects** section as local projects. Its resolver matches the remote host plus each chat's working directory to the saved remote project path; the project row keeps the built-in remote/globe indicator. This repository leaves that renderer unchanged.

If remote chats still appear as individual globe-marked items under **Tasks**:

1. fully exit every older Codex/ChatGPT desktop process;
2. open the generated desktop or Start-menu **Codex_Fix** shortcut;
3. in **Settings > Connections**, make sure each folder was saved as a remote project rather than only opening an unregistered remote working directory.

The launcher refuses to mix two desktop runtime versions. Installing the new runtime does not change an already-running older window; that window must exit once before the new sidebar logic can load.

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

Open the new **Codex_Fix** desktop or Start-menu shortcut. It uses the official icon and the same user data, projects, and Codex home as the Store app. To keep it on the taskbar, pin the **Codex_Fix** Start-menu entry once; do not pin the running Store-app window.

The installer:

1. resolves the currently registered Store package and checks the official executable signature;
2. discovers and cross-checks the official SSH transport bindings;
3. rewrites the ASAR locally, synchronizes Electron's embedded `ElectronAsar` header hash in the copied executable, and verifies both integrity layers;
4. creates an isolated runtime under `%LOCALAPPDATA%\OpenAI\Codex-Windows-SSH\<official-version>-r<patch-revision>`;
5. when an older user-owned patched runtime exists, hardlinks byte-identical files from it and copies only files changed by the Store update;
6. verifies the bundled CLI and starts the staged desktop with an isolated temporary profile, requiring its first page to load and the process to remain alive;
7. builds a tiny stable taskbar host that immediately hands off to the VBS launcher, creates stable desktop and Start-menu shortcuts, and migrates any existing taskbar pin already owned by this project. The `current.version` pointer is switched only after validation succeeds.

The signed WindowsApps package is never modified. The installer verifies that upstream signature before copying. Synchronizing the copied executable's Electron integrity resource intentionally removes Authenticode from that user-owned copy; validation therefore checks its exact ASAR/resource pair instead. Windows does not allow an ordinary user to create hardlinks directly from the protected WindowsApps tree, so a first install requires a regular runtime copy. Later version upgrades reuse the existing user-owned runtime and are much lighter; `ChatGPT.exe` itself is always copied rather than hardlinked before its resource is changed.

## Updating

The official Store installation and **Codex_Fix** are separate. **Help > Check for Updates** now checks the [official online release feed](https://persistent.oaistatic.com/codex-app-prod/windows-store-update.json), not just the locally registered Store version:

```text
Check official release → download and verify MSIX → detect structure and patch
  → assemble staged runtime → verify isolated desktop startup → atomically select
```

The updater requests the release-specific MSIX for the current architecture. If the feed announces a release before that CDN package is available, it checks the official stable MSIX endpoint and reads its published version. It explicitly reports this rollout lag, never labels an older available package as the feed's latest release, and never downgrades the selected runtime.

Before building, it verifies the MSIX's trusted digital signature, expected package publisher and identity, architecture, and version. It also verifies the OpenAI-signed executable and its original embedded ASAR integrity. Structural guards must accept the patch; the resulting ASAR, executable integrity, bundled CLI, and runtime-local `desktop-updater.cjs` bridge are validated. A real isolated desktop process must load its first page and remain alive before selection changes. This is startup validation, not an authenticated SSH or full UI regression test. Compatibility or validation failure leaves the existing runtime selected.

Clicking **Check for Updates** immediately opens the app's existing rounded installation card. A small adapter supplies its title, current stage, measured download/extraction percentage, and explicit latest/success/failure result through the existing update-state channel. It reuses the official dialog, typography, buttons, progress bar and theme tokens, including light/dark appearance; there is no separate Windows progress window or console. Signature checks and startup validation use indeterminate progress instead of fabricated percentages. Detailed output stays in the log, not the card. Each runtime carries its own bridge, so preparing a new build does not overwrite the running desktop's bridge. An active session is never hot-swapped or stopped: use the official restart action when ready, or fully exit and reopen **Codex_Fix** later. Rechecking before restart preserves the restart-ready state.

No source change or version-profile edit is needed while the relevant upstream structure remains compatible. Rerunning `Install-Codex-Windows-SSH.ps1` still explicitly rebases from the locally registered Store package; the online path is `Update-Codex-Windows-SSH.ps1`.

To enable automatic checks shortly after each patched Codex launch, run once:

```powershell
pwsh -NoProfile -File .\Install-Codex-Windows-SSH.ps1 -EnableAutoUpdate
```

The stable launcher starts the last validated runtime without an online wait. Before opening it, a local-only cleanup retries unused files previously locked by the old process. When enabled, the running app checks after ten seconds and displays progress using its own card and selected theme. Online checks no longer block the VBS entry behind a separate window. Failure leaves the selected working runtime unchanged. These updates do not install, replace, or modify the official Store package.

The `-r<patch-revision>` suffix is independent of the Store version. It lets a new launcher, validation rule, or menu patch be published beside a running older patch of the same official release. Only after the new directory passes every check does `current.version` atomically switch to that runtime ID; the stable taskbar entry follows the pointer on the next launch.

The last update result is recorded in `%LOCALAPPDATA%\OpenAI\Codex-Windows-SSH\last-update.json`, with phase details in `last-update.log`. The launcher's selected path and outcome are recorded separately in `last-launch.txt`; its 1.2-second process-survival check is additional to the installer's isolated page-load validation. `-Status` reads only the selected runtime and last local update record; it does **not** query the online feed. Use the app's Help menu for the themed UI, or run the headless worker directly for structured output:

```powershell
pwsh -NoProfile -File .\Update-Codex-Windows-SSH.ps1 -Status
pwsh -NoProfile -File .\Update-Codex-Windows-SSH.ps1 -JsonProgress
```

The patched app is named **Codex_Fix**, separate from the official **ChatGPT** entry. It uses the dedicated `com.openai.codex.windows-ssh` application identity. Its shortcuts target the stable `CodexLauncher.exe`, which still follows the VBS route and never points at a numbered runtime. The installer uses the official white `chatgpt-app-dark.ico` for `%LOCALAPPDATA%\OpenAI\Codex-Windows-SSH\Codex_Fix.ico` and embeds it in the launcher EXE. Optional window relaunch/icon APIs are feature-detected: the shipped Owl runtime does not implement stock Electron's `BrowserWindow.setAppDetails`, so calling it unconditionally prevents startup. Existing account, user-data, protocol, and SSH settings are unchanged.

Legacy project-owned Desktop and Start-menu shortcuts are moved to `shortcut-backups` under the install root; unrelated links and the official WindowsApps package are not removed. An old taskbar pin can retain a cached `com.openai.codex` identity even when its on-disk shortcut has been repaired. Unpin such an old Codex/ChatGPT entry once, then right-click **Codex_Fix** in Start and choose **Pin to taskbar**. Windows 11 requires user approval for adding that pin. Subsequent updates retain the stable entry.

Temporary MSIX downloads and extracted packages are cleaned after the update attempt. After a successful build and isolated startup validation, cleanup removes inactive project-owned runtimes, preserving the selected runtime and every runtime referenced by a live process. Ownership/path checks reject unrelated directories and junctions; account data and the official Store package are outside the deletion scope. `Remove-OldCodexRuntimes.ps1 -WhatIf` previews the same cleanup for manual maintenance. Byte-identical runtime files use hardlinks, and downloaded source files can be linked into the staged runtime before their temporary names are removed. Thus the project does not redistribute installers or retain a collection of full original packages. Directory-size tools may count hardlinked files repeatedly even though their data is stored only once.

For the separate Python voice gateway prototype, `integrations/voice-gateway-runtime.patch` records the integration change and its regression tests. It resolves generic `codex` plus inherited desktop tool paths at App Server startup, follows `current.version`, and leaves global configuration untouched. Apply it from the gateway root with `git apply <path-to-patch>`, then run `python -m unittest discover -s tests`. The gateway stop script also terminates its MCP descendants, so they do not keep obsolete runtimes open after a restart.

The VBS launcher also normalizes repository, stable-root, and retained version-directory launches back to the canonical install root. Version pointers are written without a line terminator, while the reader still strips CR/LF for compatibility with older installations.

The Windows notification-area (tray) icon uses Electron's default registration without the official signed application's fixed GUID. Windows binds an unsigned executable's tray GUID to its path, so reusing the official GUID after copying or updating the runtime can prevent the icon from appearing. The normal tray menu, including Quit, remains available. You can also quit from the app using **Ctrl+Q**.

Disable automatic launch-time checks without uninstalling:

```powershell
pwsh -NoProfile -File .\Install-Codex-Windows-SSH.ps1 -DisableAutoUpdate
```

Desktop app updates do not update Codex CLI installations on SSH hosts. If the connection UI asks for a CLI update, update `codex` on that host using the same official installation method originally used there, then reconnect.

- [OpenAI: Manage app updates](https://learn.chatgpt.com/docs/enterprise/manage-app-updates)
- [OpenAI: Codex CLI](https://learn.chatgpt.com/docs/codex/cli)

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

Every push and pull request also runs [`.github/workflows/validate.yml`](.github/workflows/validate.yml) on Windows. It executes the structural SSH/update-menu patcher self-test, parses every PowerShell script plus the VBScript launcher, compiles and self-tests the Electron integrity tool, compiles the stable taskbar host, and regression-tests both EXE-to-VBS and stable/version-local VBS resolution with a legacy trailing-LF pointer. The installer supplies the package-dependent validation that CI cannot run without redistributing the official app.

## Uninstall

Exit the patched desktop app, then run:

```powershell
pwsh -NoProfile -File .\Uninstall-Codex-Windows-SSH.ps1
```

This removes only shortcuts owned by this project and `%LOCALAPPDATA%\OpenAI\Codex-Windows-SSH`. The Store package, user data, `~/.codex`, repositories, and remote hosts are untouched.

## When an upstream transport change fails compatibility

Keep the structural guard. Audit the changed transport, update the narrow semantic anchors or binding discovery, run the self-test and real SSH regressions, and then rerun the installer. Do not replace failure with an unconditional patch. `UPSTREAM-DESIGN.patch` documents the source-level change that should ultimately land upstream.

## Legal and project status

This project is not affiliated with or endorsed by OpenAI. It contains original patching/controller code and short transformation anchors only. It does not redistribute OpenAI binaries, packaged archives, extracted bundles, or application source.

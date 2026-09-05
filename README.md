# Codex Windows SSH

An unofficial, narrow compatibility patch for connecting the Codex desktop app to SSH hosts whose login shell is Windows PowerShell.

中文摘要：这个补丁让桌面 Codex 自动识别 Windows SSH 主机，Windows 走 PowerShell + `ssh -W`，Linux/macOS 保持官方路径。仓库不包含 OpenAI 的程序、`app.asar` 或反编译源码；补丁只从你本机已安装且签名有效的官方包生成。

## Why this repository is not an `openai/codex` fork

OpenAI publishes the Codex CLI, SDK, and App Server in `openai/codex`, but the desktop UI and its Electron SSH transport are not listed as open-source components. Forking the CLI repository would therefore not change this desktop connection path.

The current desktop build already groups remote work by project and renders the remote host indicator beside the project name. This project deliberately leaves that renderer untouched and patches only the missing Windows SSH transport branch.

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
2. open the generated desktop or Start-menu **Codex** shortcut;
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

Open the new **Codex** desktop or Start-menu shortcut. It uses the official icon and the same user data, projects, and Codex home as the Store app. To keep it on the taskbar, pin the **Codex** Start-menu entry once; do not pin the running Store-app window.

The installer:

1. resolves the currently registered Store package and checks the official executable signature;
2. discovers and cross-checks the official SSH transport bindings;
3. rewrites the ASAR locally, synchronizes Electron's embedded `ElectronAsar` header hash in the copied executable, and verifies both integrity layers;
4. creates an isolated runtime under `%LOCALAPPDATA%\OpenAI\Codex-Windows-SSH\<official-version>-r<patch-revision>`;
5. when an older user-owned patched runtime exists, hardlinks byte-identical files from it and copies only files changed by the Store update;
6. builds a tiny stable taskbar host that immediately hands off to the VBS launcher, creates stable desktop and Start-menu shortcuts, and migrates any existing taskbar pin already owned by this project. The `current.version` pointer is switched only after a new runtime is complete.

The signed WindowsApps package is never modified. The installer verifies that upstream signature before copying. Synchronizing the copied executable's Electron integrity resource intentionally removes Authenticode from that user-owned copy; validation therefore checks its exact ASAR/resource pair instead. Windows does not allow an ordinary user to create hardlinks directly from the protected WindowsApps tree, so a first install requires a regular runtime copy. Later version upgrades reuse the existing user-owned runtime and are much lighter; `ChatGPT.exe` itself is always copied rather than hardlinked before its resource is changed.

## Updating

The Microsoft Store package and this patched runtime are separate update surfaces. The official desktop app normally receives its own updates; rerunning the installer rebases the SSH patch onto whatever signed Store package is currently registered:

```powershell
pwsh -NoProfile -File .\Install-Codex-Windows-SSH.ps1
```

No source change or version-profile edit is needed while the SSH transport remains structurally compatible.

To enable automatic checks before each patched Codex launch, run once:

```powershell
pwsh -NoProfile -File .\Install-Codex-Windows-SSH.ps1 -EnableAutoUpdate
```

The Microsoft Store remains responsible for installing the signed official package. On launch, this project compares that registered official version with the selected patched runtime. A current, validated build adds only a quick hidden check. When the official package changes—or an older build lacks the current validation stamp—a visible PowerShell progress bar covers upstream signature verification, compatibility checking, patching, runtime assembly, embedded-ASAR synchronization, ASAR verification, and bundled-CLI startup verification. The validated runtime is selected atomically and used by that same launch.

The patched app's **Help > Check for Updates** item uses the same project updater instead of Electron's unavailable packaged-app updater. An already-current check stays hidden until it shows a small result dialog; a required rebuild opens the visible progress window and reports success or failure. An active Codex process is never hot-swapped, so restart Codex after a newly selected runtime is built.

The `-r<patch-revision>` suffix is independent of the Store version. It lets a new launcher, validation rule, or menu patch be published beside a running older patch of the same official release. Only after the new directory passes every check does `current.version` atomically switch to that runtime ID; the stable taskbar entry follows the pointer on the next launch.

The last update result, including the official version and selected runtime ID, is recorded in `%LOCALAPPDATA%\OpenAI\Codex-Windows-SSH\last-update.json`. The launcher's last selected path and outcome are recorded in `last-launch.txt`; after dispatch it waits in the background for 1.2 seconds and records `running`, `exited-early`, or `dispatched-unverified`, so a native startup crash is no longer reported as success. A failed check leaves `current.version` unchanged and starts the last validated runtime. You can inspect update state without changing anything:

```powershell
pwsh -NoProfile -File .\Update-Codex-Windows-SSH.ps1 -Status
```

The patched app is named **Codex_Fix**, separate from the official **ChatGPT** entry. It uses the dedicated `com.openai.codex.windows-ssh` application identity. Its shortcuts target the stable `CodexLauncher.exe`, which still follows the VBS route and never points at a numbered runtime. The installer uses the official white `chatgpt-app-dark.ico` for `%LOCALAPPDATA%\OpenAI\Codex-Windows-SSH\Codex_Fix.ico` and embeds it in the launcher EXE. Optional window relaunch/icon APIs are feature-detected: the shipped Owl runtime does not implement stock Electron's `BrowserWindow.setAppDetails`, so calling it unconditionally prevents startup. Existing account, user-data, protocol, and SSH settings are unchanged.

Legacy project-owned Desktop and Start-menu shortcuts are moved to `shortcut-backups` under the install root; unrelated links and the official WindowsApps package are not removed. An old taskbar pin can retain a cached `com.openai.codex` identity even when its on-disk shortcut has been repaired. Unpin such an old Codex/ChatGPT entry once, then right-click **Codex_Fix** in Start and choose **Pin to taskbar**. Windows 11 requires user approval for adding that pin. Subsequent updates retain the stable entry.

After confirming the selected desktop actually opens, unused runtime copies can be removed with `Remove-OldCodexRuntimes.ps1` (also installed in the `updater` directory). Run it with `-WhatIf` to preview, then without `-WhatIf` to delete. It preserves the selected runtime and any runtime referenced by a live process, validates ownership/path boundaries, and refuses junctions. Account data and the official package are outside its deletion scope. Cleanup is intentionally not triggered by build validation alone: a successful ASAR/CLI check does not prove that the desktop UI starts. Files shared by hard links are counted repeatedly by directory-size tools but are stored only once on disk.

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

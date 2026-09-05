// codex-windows-ssh: stable Windows shell identity
(() => {
  const { app } = require('electron');
  const { resolve, join } = require('node:path');
  const name = 'Codex_Fix';
  const appId = 'com.openai.codex.windows-ssh';
  const originalName = app.getName();
  const root = resolve(process.resourcesPath, '..', '..', '..');
  const icon = join(root, 'Codex_Fix.ico');
  const launcher = join(root, 'CodexLauncher.exe');

  // Keep the existing user-data path, account, protocol, and SSH settings intact.
  app.setName(name);
  app.setAppUserModelId(appId);
  app.on('browser-window-created', (_event, window) => {
    if (process.env.CODEX_WINDOWS_SSH_STARTUP_PROBE) {
      window.hide?.();
      window.on('show', () => window.hide?.());
      window.webContents.once('did-finish-load', () => {
        require('node:fs').writeFileSync(process.env.CODEX_WINDOWS_SSH_STARTUP_PROBE,
          JSON.stringify({ status: 'ready', pid: process.pid, pageLoaded: true }));
      });
    }
    // Owl's BrowserWindow omits some stock Electron shell APIs. Cosmetics
    // must never prevent the main window from opening; the Start shortcut
    // already supplies the stable relaunch target and dedicated app ID.
    window.setAppDetails?.({
      appId,
      appIconPath: icon,
      appIconIndex: 0,
      relaunchCommand: '"' + launcher + '"',
      relaunchDisplayName: name,
    });
    window.setIcon?.(icon);
    if (window.getTitle?.() === originalName) window.setTitle?.(name);
    window.on('page-title-updated', (event, title) => {
      if (title === originalName) {
        event.preventDefault();
        window.setTitle?.(name);
      }
    });
  });
})();

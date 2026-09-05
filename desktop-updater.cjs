// Feed the official in-app update card; the worker never opens another window.
const { spawn } = require('node:child_process');
const { readFileSync, existsSync } = require('node:fs');
const { join, resolve, basename } = require('node:path');
const { app } = require('electron');
const root = resolve(process.resourcesPath, '..', '..', '..');
let pending, sequence = 0;

function publish(manager, state) {
  manager.codexFixUpdate = state;
  // A new stage can have the same percentage: explicitly publish the snapshot.
  manager.options.onUpdateLifecycleStateChanged?.();
}

function begin(manager) {
  publish(manager, { id: ++sequence, title: '正在检查更新', message: '正在检查官方新版…',
    phase: 'checking', percent: null, done: false, succeeded: false, restartRequired: false });
  manager.setUpdateLifecycleState('checking');
}

function finish(manager, result, wasReady = false) {
  manager.setDownloadProgressPercent(null);
  manager.setInstallProgressPercent(null);
  const ready = result.succeeded ? Boolean(result.restartRequired) : wasReady;
  manager.setUpdateReady(ready);
  manager.setUpdateLifecycleState(ready ? 'ready' : 'idle');
  publish(manager, { id: manager.codexFixUpdate?.id ?? ++sequence,
    title: !result.succeeded ? '更新失败' : ready ? '更新已准备好' : '检查完成',
    message: result.message || (result.succeeded ? '检查完成。' : '更新失败，当前版本保持不变。'),
    phase: result.succeeded ? 'complete' : 'failed', percent: result.succeeded ? 100 : null,
    done: true, succeeded: Boolean(result.succeeded), restartRequired: ready });
}

exports.install = function install(manager) {
  for (const method of ['setUpdateLifecycleState', 'setDownloadProgressPercent', 'setInstallProgressPercent', 'setUpdateReady']) {
    if (typeof manager[method] !== 'function') throw new Error(`Unsupported official updater interface: ${method}`);
  }
  manager.lastUnavailableReason = null;
  manager.updater = {
    hasUpdater: () => true,
    getIsUpdateReady: () => manager.getIsUpdateReady(),
    checkForUpdates: () => run(manager),
    installUpdatesIfAvailable: async () => {
      const selected = readFileSync(join(root, 'current.version'), 'utf8').trim();
      if (!/^\d+\.\d+\.\d+\.\d+-r\d+$/.test(selected)) throw new Error('Invalid selected runtime');
      if (!manager.getIsUpdateReady()) return;
      app.relaunch({ execPath: join(root, 'CodexLauncher.exe'), args: [] });
      if (manager.options.onInstallUpdatesRequested) manager.options.onInstallUpdatesRequested({ quitImmediately: true });
      else app.quit();
    },
  };
  // Launch the validated app first so any progress uses its own UI and theme.
  if (!process.env.CODEX_WINDOWS_SSH_STARTUP_PROBE && existsSync(join(root, 'auto-update.enabled'))) {
    setTimeout(() => exports.check(manager), 10000).unref();
  }
};

exports.check = async function check(manager) {
  if (pending) return pending;
  const wasReady = manager.getIsUpdateReady();
  try {
    begin(manager);
    await manager.checkForUpdates(); // Keep the official launch-policy / trusted-IPC path.
    if (!manager.hasUpdater()) throw new Error(manager.getUnavailableReason() || 'Updater unavailable');
    if (!manager.codexFixUpdate.done) throw new Error('更新检查未启动，请检查应用更新策略。');
  } catch (error) {
    finish(manager, { succeeded: false, message: String(error.message || error) }, wasReady);
  }
};

function run(manager) {
  if (pending) return pending;
  if (!manager.codexFixUpdate || manager.codexFixUpdate.done) begin(manager);
  const wasReady = manager.getIsUpdateReady();
  pending = new Promise((resolveRun, reject) => {
    const child = spawn('pwsh.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-File',
      join(root, 'updater', 'Update-Codex-Windows-SSH.ps1'), '-JsonProgress',
      '-RunningRuntimeId', basename(resolve(process.resourcesPath, '..', '..'))],
    { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let buffer = '', stderr = '', terminal;
    const stages = { checking: '正在检查官方新版…', downloading: '正在下载官方原包…',
      verifying: '正在验证官方签名…', extracting: '正在展开官方原包…', building: '正在应用兼容补丁…',
      validating: '正在验证启动…', switching: '正在准备切换修复版…', cleanup: '正在清理临时文件…' };
    const accept = line => {
      let event;
      try { event = JSON.parse(line); } catch { return; }
      if (event.type === 'result') { terminal = event; finish(manager, event, wasReady); return; }
      if (event.type !== 'progress' || terminal) return;
      const measurable = ['downloading', 'extracting'].includes(event.phase);
      const percent = measurable && typeof event.percent === 'number' && Number.isFinite(event.percent)
        ? Math.max(0, Math.min(100, event.percent)) : null;
      publish(manager, { ...manager.codexFixUpdate,
        title: event.phase === 'checking' ? '正在检查更新' : '正在准备更新', phase: event.phase,
        message: stages[event.phase] || '正在处理更新…', percent });
      if (event.phase === 'downloading') {
        manager.setUpdateLifecycleState('downloading');
        manager.setDownloadProgressPercent(percent);
      } else if (event.phase !== 'checking') {
        manager.setDownloadProgressPercent(null);
        manager.setInstallProgressPercent(0); // Header state; card reads the honest per-stage value above.
      }
    };
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      buffer += chunk;
      const lines = buffer.split(/\r?\n/); buffer = lines.pop();
      for (const line of lines) accept(line);
    });
    child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-4000); });
    child.once('error', reject);
    child.once('close', code => {
      if (buffer) accept(buffer);
      if (!terminal) reject(new Error(stderr || `Updater exited without a result (${code})`));
      else if (code !== 0 && terminal.succeeded) reject(new Error(`Updater exited with code ${code}`));
      else resolveRun();
    });
  }).catch(error => {
    finish(manager, { succeeded: false, message: `更新失败，保留当前可用版本：${error.message || error}` }, wasReady);
  }).finally(() => { pending = null; });
  return pending;
}

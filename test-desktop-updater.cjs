const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { runInNewContext } = require('node:vm');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const path = require('node:path');
const api = {}, children = [], restarts = [], snapshots = [];
const manager = {
  state: 'idle', ready: false, options: { onInstallUpdatesRequested: e => restarts.push(e),
    onUpdateLifecycleStateChanged: () => snapshots.push(manager.codexFixUpdate) },
  setUpdateReady(e) { this.ready = e; }, getIsUpdateReady() { return this.ready; },
  setUpdateLifecycleState(e) { this.state = e; },
  setDownloadProgressPercent(e) { this.download = e; }, setInstallProgressPercent(e) { this.build = e; },
  hasUpdater() { return Boolean(this.updater); }, checkForUpdates() { return this.updater.checkForUpdates(); },
};
runInNewContext(readFileSync(path.join(__dirname, 'desktop-updater.cjs'), 'utf8'), {
  exports: api, process: { resourcesPath: path.join(__dirname, '1.2.3.4-r7', 'app', 'resources'), env: {} },
  require(name) {
    if (name === 'node:path') return path;
    if (name === 'node:fs') return { readFileSync: () => '1.2.3.5-r7', existsSync: () => false };
    if (name === 'electron') return { app: { relaunch: e => restarts.push(e), quit() {} } };
    if (name === 'node:child_process') return { spawn(exe, args, options) {
      assert.equal(options.windowsHide, true);
      assert(!args.includes('-Menu') && args.includes('-JsonProgress'));
      const child = new EventEmitter(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
      children.push(child); return child;
    } };
    throw new Error(name);
  },
});
(async () => {
  api.install(manager);
  const check = api.check(manager);
  const duplicate = api.check(manager);
  assert.equal(children.length, 1);
  assert.equal(manager.state, 'checking');
  assert.equal(manager.codexFixUpdate.title, '正在检查更新');
  assert.equal(manager.codexFixUpdate.percent, null);
  const child = children[0];
  const line = JSON.stringify({ type: 'progress', phase: 'downloading', percent: 37, message: '正在下载' }) + '\n';
  child.stdout.write(line.slice(0, 12)); child.stdout.write(line.slice(12));
  assert.equal(manager.download, 37);
  child.stdout.write(JSON.stringify({ type: 'progress', phase: 'building', percent: 62 }) + '\n');
  assert.equal(manager.build, 0);
  assert.equal(manager.codexFixUpdate.percent, null); // Build milestones are not measured completion.
  assert.match(manager.codexFixUpdate.message, /兼容补丁/);
  const previousStage = snapshots.length;
  child.stdout.write(JSON.stringify({ type: 'progress', phase: 'validating', percent: 62 }) + '\n');
  assert(snapshots.length > previousStage);
  assert.match(manager.codexFixUpdate.message, /验证启动/);
  child.stdout.write(JSON.stringify({ type: 'progress', phase: 'extracting', percent: 0 }) + '\n');
  assert.equal(manager.codexFixUpdate.percent, 0);
  child.stdout.write(JSON.stringify({ type: 'result', succeeded: true, restartRequired: true }) + '\n');
  assert.equal(manager.state, 'ready');
  assert.equal(manager.codexFixUpdate.done, true);
  child.emit('close', 0); await check; await duplicate;
  await manager.updater.installUpdatesIfAvailable();
  assert.equal(restarts[0].execPath, path.join(__dirname, 'CodexLauncher.exe'));
  assert.equal(restarts[1].quitImmediately, true);
  const failed = api.check(manager);
  children[1].emit('error', new Error('pwsh missing'));
  await failed;
  assert.equal(manager.state, 'ready'); // Failure must not discard an already-prepared restart.
  assert.match(manager.codexFixUpdate.message, /pwsh missing/);
  const crash = api.check(manager);
  children[2].emit('close', 9);
  await crash;
  assert.equal(manager.state, 'ready');
  assert.match(manager.codexFixUpdate.message, /without a result/);
  const failure = api.check(manager);
  children[3].stdout.write(JSON.stringify({type:'result',succeeded:false,message:'signature rejected'}) + '\n');
  children[3].emit('close', 1); await failure;
  assert.equal(manager.codexFixUpdate.title, '更新失败');
  assert.equal(manager.codexFixUpdate.message, 'signature rejected');
  manager.checkForUpdates = async () => {}; // Official policy can skip an installed adapter.
  await api.check(manager);
  assert.match(manager.codexFixUpdate.message, /更新策略/);
  console.log('Official updater card bridge: immediate state, measured progress, stages, deduplication, safe restart and visible failures passed.');
})().catch(error => { console.error(error); process.exitCode = 1; });

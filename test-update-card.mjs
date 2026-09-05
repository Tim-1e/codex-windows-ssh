import assert from 'node:assert/strict';
import { openSync, readSync, closeSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { patchUpdateCard, patchUpdateViewState, UPDATE_CARD_MARKER } from './patch-update-card.mjs';

// A small authored fixture models the compiled semantic anchors, not a copy of
// an official renderer. Real local archives can additionally be passed as args.
export const fixture = [
  'var State="state",Progress=derived(Scope,({get:e})=>e(State).installProgressPercent);',
  'function Card(e){let{installProgressPercent:r}=e,i=intl(),a=read(Progress),o=r===void 0?a:r;if(o==null)return null;',
  'let d=(0,J.jsx)(Title,{className:`sr-only`,children:(0,J.jsx)(Intl,{id:`appUpdate.installProgress.title`})}),f="Update",p=(0,J.jsx)(Header,{title:f,subtitle:(0,J.jsx)(Intl,{id:`appUpdate.installProgress.subtitle`})});',
  'let m={id:`appUpdate.installProgress.progressLabel`},status={id:`appUpdate.installProgress.preparing`},label={id:`appUpdate.installProgress.percent`};',
  'let pulse=(0,J.jsx)(`div`,{className:`h-full w-1/3 animate-pulse rounded-full bg-chart-blue motion-reduce:animate-none`});',
  'let fill=(0,J.jsx)(`div`,{className:`h-full rounded-full bg-chart-blue transition-[width] duration-basic ease-out motion-reduce:transition-none`});',
  'let track=(0,J.jsx)(`div`,{className:`h-2 flex-1 overflow-hidden rounded-full bg-border`});',
  'let count=(0,J.jsx)(`span`,{className:`min-w-10 text-end text-sm font-medium text-secondary tabular-nums`});',
  'return(0,J.jsx)(Dialog,{open:!0,onOpenChange:Ignore,shouldIgnoreClickOutside:!0,showDialogClose:!1,size:`compact`,contentProps:m,children:(0,J.jsx)(Body,{children:(0,J.jsxs)(Content,{className:`gap-3`,children:[d,p,(0,J.jsxs)(`div`,{className:`flex items-center gap-3`,children:[track,count]})]})})})}',
  'function Ignore(){}',
  'function Confirm(e){let n=e.onClose,f=(0,K.jsx)(Intl,{id:`appHeader.installUpdate.confirmCancel`});return(0,K.jsx)(Button,{color:`secondary`,onClick:n,children:f})}var Cache,K,InitConfirm=init((()=>{K=J}));',
  'function Mounted(){let e=0,t=useStore(Scope),n;t.set(State,n);return(0,J.jsx)(Card,{})}',
].join('');

function renderTest(text) {
  let current = { codexFixUpdate: null, installProgressPercent: null };
  const jsx = (type, props) => ({ type, props });
  const context = { J: { jsx, jsxs: jsx }, Scope: {}, init: fn => fn, derived: () => 'progress',
    read: atom => atom === 'state' ? current : current.installProgressPercent,
    useStore: () => ({ get: () => current, set: (_atom, next) => { current = next; } }),
    Title: 'OfficialTitle', Header: 'OfficialHeader', Dialog: 'OfficialDialog', Body: 'OfficialBody',
    Content: 'OfficialContent', Button: 'OfficialButton', Intl: 'OfficialIntl' };
  runInNewContext(text + ';globalThis.render=Card;', context);
  const descendants = node => !node || typeof node !== 'object' ? [] : [node, ...[node.props?.children].flat(Infinity).flatMap(descendants)];
  const render = update => { current = { ...current, codexFixUpdate: update }; return context.render({}); };
  assert.equal(render(null).type.name, 'Card_codexFixOriginal');
  const base = { id: 'one', title: '正在更新', message: '正在检查', phase: 'checking', percent: null, done: false, succeeded: false, restartRequired: false };
  const initial = render(base);
  assert.equal(initial.type, 'OfficialDialog');
  assert.equal(initial.props.size, 'compact');
  assert.equal(initial.props.showDialogClose, false);
  let prevented = false;
  initial.props.contentProps.onEscapeKeyDown({ preventDefault() { prevented = true; } });
  assert(prevented);
  initial.props.onOpenChange(false);
  assert.equal(current.codexFixUpdate.id, 'one');
  assert.equal(descendants(initial).find(node => node.props?.role === 'progressbar').props['aria-valuenow'], undefined);
  for (const percent of [0, 37, 100]) {
    const tree = descendants(render({ ...base, percent, message: '正在下载' }));
    assert.equal(tree.find(node => node.props?.role === 'progressbar').props['aria-valuenow'], percent);
    assert.equal(tree.find(node => node.props?.style?.width)?.props.style.width, percent + '%');
  }
  for (const message of ['正在验证', '正在构建', '<img src=x onerror=bad>']) {
    const tree = descendants(render({ ...base, percent: 37, message }));
    assert.equal(tree.find(node => node.props?.role === 'status').props.children, message + ' 37%');
    assert(!tree.some(node => node.props?.dangerouslySetInnerHTML));
  }
  for (const succeeded of [false, true]) {
    const result = { ...base, id: succeeded ? 2 : 1, done: true, succeeded, restartRequired: succeeded };
    const terminal = descendants(render(result));
    assert(!terminal.some(node => node.props?.role === 'progressbar'));
    terminal.find(node => node.type === 'OfficialButton').props.onClick();
    assert.equal(current.codexFixUpdate, null);
    // A later manager snapshot still contains its terminal result; closing it
    // must not be undone by that unrelated update-state broadcast.
    assert.equal(render(result).type.name, 'Card_codexFixOriginal');
    assert.equal(render({ ...result, id: result.id + 10 }).type, 'OfficialDialog');
  }
  assert.equal(render({ ...base, id: 1 }).type, 'OfficialDialog');
  assert.equal(render({ ...base, id: NaN }).type.name, 'Card_codexFixOriginal');
  // These are the original theme tokens; no hardcoded light/dark colors or CSS.
  for (const theme of ['light', 'dark']) {
    context.theme = theme;
    const tree = descendants(render(base));
    assert(tree.some(node => node.props?.className?.includes('bg-chart-blue')));
    assert(tree.some(node => node.props?.className?.includes('bg-border')));
    assert(tree.some(node => node.props?.className?.includes('text-secondary')));
  }
}

export function selfTestUpdateCard() {
const patched = patchUpdateCard(Buffer.from(fixture)).toString();
assert(patched.includes(UPDATE_CARD_MARKER));
renderTest(patched);
assert.throws(() => patchUpdateCard(Buffer.from(patched)), /already patched/);
assert.throws(() => patchUpdateCard(Buffer.from(fixture.replace('size:`compact`', 'size:`large`'))), /modal layout/);
assert.throws(() => patchUpdateCard(Buffer.from(fixture.replace('Progress=derived', 'Missing=derived'))), /shared update state/);
assert.throws(() => patchUpdateCard(Buffer.from(fixture + fixture)), /Expected one official install modal/);
const renamed = fixture.replace(/\b(?:Card|J|Title|Header|Dialog|Body|Content|read|Progress|State|useStore|Button|InitConfirm)\b/g, name => 'renamed_' + name);
assert(patchUpdateCard(Buffer.from(renamed)).includes('function renamed_Card('));
const stateFixture = 'class Windows{getAppUpdateViewState(){return{downloadProgressPercent:this.options.sparkleManager.getDownloadProgressPercent(),installProgressPercent:this.options.sparkleManager.getInstallProgressPercent(),isUpdateReady:this.options.sparkleManager.getIsUpdateReady(),lifecycleState:this.options.sparkleManager.getUpdateLifecycleState(),relaunchNotice:this.options.sparkleManager.getRelaunchNotice()}}}';
const patchedState = patchUpdateViewState(Buffer.from(stateFixture)).toString();
const stateContext = {};
runInNewContext(patchedState + ';globalThis.Manager=Windows;', stateContext);
const manager = new stateContext.Manager();
const payload = { id: 'safe', message: 'checking', percent: 0 };
manager.options = { sparkleManager: { codexFixUpdate: payload, getDownloadProgressPercent() {}, getInstallProgressPercent() {}, getIsUpdateReady() {}, getUpdateLifecycleState() {}, getRelaunchNotice() {} } };
assert.equal(manager.getAppUpdateViewState().codexFixUpdate, payload);
}

function checkArchive(path) {
  const fd = openSync(path, 'r');
  try {
    const preamble = Buffer.alloc(16); readSync(fd, preamble, 0, 16, 0);
    const header = Buffer.alloc(preamble.readUInt32LE(12)); readSync(fd, header, 0, header.length, 16);
    const entries = [];
    const walk = (directory, prefix = '') => { for (const [name, entry] of Object.entries(directory.files || {})) {
      const itemPath = prefix + name;
      if (entry.files) walk(entry, itemPath + '/');
      else if (itemPath.endsWith('.js') && (itemPath.startsWith('.vite/build/') || itemPath.startsWith('webview/assets/app-initial-'))) entries.push({ ...entry, path: itemPath });
    } };
    walk(JSON.parse(header));
    let cardCount = 0, stateCount = 0;
    for (const entry of entries) {
      if (entry.unpacked || entry.size > 15_000_000) continue;
      const content = Buffer.alloc(entry.size); readSync(fd, content, 0, content.length, 8 + preamble.readUInt32LE(4) + Number(entry.offset));
      if (content.includes('id:`appUpdate.installProgress.title`') && content.includes('id:`appUpdate.installProgress.progressLabel`')) { patchUpdateCard(content); cardCount++; }
      if (content.includes('getAppUpdateViewState(){return{')) { patchUpdateViewState(content); stateCount++; }
    }
    assert.equal(cardCount, 1); assert.equal(stateCount, 1);
    console.log('Read-only official archive structural check passed:', path);
  } finally { closeSync(fd); }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  selfTestUpdateCard();
  for (const path of process.argv.slice(2)) checkArchive(path);
  console.log('Official update card: structural discovery, live stages, progress, theme tokens, failure, dismissal and fallback passed.');
}

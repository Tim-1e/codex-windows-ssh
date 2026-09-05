import { spawnSync } from 'node:child_process';

export const UPDATE_CARD_MARKER = 'codex-windows-ssh: official update card';
const identifier = '[A-Za-z_$][\\w$]*';
const escape = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function exactlyOne(text, pattern, label) {
  const matches = [...text.matchAll(pattern)];
  if (matches.length !== 1) throw new Error(`Unsupported update card: ${label} (${matches.length} matches)`);
  return matches[0];
}

function syntaxChecked(text) {
  const result = spawnSync(process.execPath, ['--check', '--input-type=module'], { input: text, encoding: 'utf8', windowsHide: true });
  if (result.status !== 0) throw new Error(`Patched update card syntax failed: ${result.stderr || result.error}`);
  return Buffer.from(text);
}

// Function boundaries are accepted only for these small, flat compiled UI
// functions; a new nested declaration fails the semantic checks below.
function functions(text) {
  const declarations = [...text.matchAll(new RegExp(`function (${identifier})\\([^)]*\\)\\{`, 'g'))];
  return declarations.map((match, index) => ({ name: match[1], start: match.index,
    end: declarations[index + 1]?.index ?? text.length,
    text: text.slice(match.index, declarations[index + 1]?.index ?? text.length) }));
}

export function patchUpdateViewState(source) {
  const text = source.toString('utf8');
  const match = exactlyOne(text, /getAppUpdateViewState\(\)\{return\{([^{}]+)\}\}/g, 'update state getter');
  for (const field of ['downloadProgressPercent', 'installProgressPercent', 'isUpdateReady', 'lifecycleState', 'relaunchNotice']) {
    if (!match[1].includes(`${field}:this.options.sparkleManager.`)) throw new Error(`Unsupported update state field: ${field}`);
  }
  if (match[1].includes('codexFixUpdate:')) throw new Error('Update state is already patched');
  return syntaxChecked(text.slice(0, match.index) + match[0].replace(/\}\}$/, ',codexFixUpdate:this.options.sparkleManager.codexFixUpdate??null}}') + text.slice(match.index + match[0].length));
}

export function patchUpdateCard(source) {
  const text = source.toString('utf8');
  if (text.includes(UPDATE_CARD_MARKER)) throw new Error('Update card is already patched');
  const declarations = functions(text);
  const candidates = declarations.filter(fn => ['title', 'subtitle', 'progressLabel', 'preparing', 'percent']
    .every(key => fn.text.includes(`id:\`appUpdate.installProgress.${key}\``)));
  if (candidates.length !== 1) throw new Error(`Expected one official install modal, found ${candidates.length}`);
  const card = candidates[0];
  if (!card.text.endsWith('}')) throw new Error('Unsupported official install modal boundary');
  const get = (pattern, label) => exactlyOne(card.text, pattern, label).groups;
  const title = get(new RegExp(`\\(0,(?<jsx>${identifier})\\.jsx\\)\\((?<title>${identifier}),\\{className:\x60sr-only\x60,children:\\(0,\\k<jsx>\\.jsx\\)\\(${identifier},\\{id:\x60appUpdate\\.installProgress\\.title\x60`, 'g'), 'accessible title');
  const header = get(new RegExp(`\\(0,${escape(title.jsx)}\\.jsx\\)\\((?<header>${identifier}),\\{title:${identifier},subtitle:`, 'g'), 'header');
  const modal = get(new RegExp(`\\(0,${escape(title.jsx)}\\.jsx\\)\\((?<dialog>${identifier}),\\{open:!0,onOpenChange:${identifier},shouldIgnoreClickOutside:!0,showDialogClose:!1,size:\x60compact\x60,contentProps:${identifier},children:\\(0,${escape(title.jsx)}\\.jsx\\)\\((?<body>${identifier}),\\{children:\\(0,${escape(title.jsx)}\\.jsxs\\)\\((?<content>${identifier}),\\{className:\x60gap-3\x60`, 'g'), 'modal layout');
  const atom = get(new RegExp(`(?<read>${identifier})\\((?<progress>${identifier})\\),${identifier}=${identifier}===void 0\\?${identifier}:${identifier};if\\(${identifier}==null\\)return null`, 'g'), 'progress atom');
  const state = exactlyOne(text, new RegExp(`${escape(atom.progress)}=${identifier}\\(${identifier},\\(\\{get:(?<get>${identifier})\\}\\)=>\\k<get>\\((?<state>${identifier})\\)\\.installProgressPercent\\)`, 'g'), 'shared update state').groups.state;
  const parents = declarations.filter(fn => fn.text.includes(`.set(${state},`) && fn.text.includes(`.jsx)(${card.name},{})`));
  if (parents.length !== 1) throw new Error('Unsupported update modal mount/subscription');
  const store = exactlyOne(parents[0].text, new RegExp(`,(?<local>${identifier})=(?<hook>${identifier})\\((?<scope>${identifier})\\),`, 'g'), 'state store hook').groups;
  if (!parents[0].text.includes(`${store.local}.set(${state},`)) throw new Error('Update store binding does not match its subscriber');
  const confirmations = declarations.filter(fn => fn.text.includes('id:`appHeader.installUpdate.confirmCancel`'));
  if (confirmations.length !== 1) throw new Error('Unsupported official update confirmation');
  const confirmation = confirmations[0];
  const button = exactlyOne(confirmation.text, new RegExp(`\\(0,${identifier}\\.jsx\\)\\((?<button>${identifier}),\\{color:\x60secondary\x60,onClick:${identifier},children:${identifier}\\}`, 'g'), 'official secondary button').groups.button;
  const initialize = exactlyOne(confirmation.text, new RegExp(`var ${identifier},${identifier},(?<init>${identifier})=${identifier}\\(\\(\\(\\)=>\\{`, 'g'), 'button dependency initializer').groups.init;
  const classes = {};
  for (const [key, prefix] of Object.entries({ pulse: 'h-full w-1/3 animate-pulse', fill: 'h-full rounded-full bg-chart-blue', track: 'h-2 flex-1', percent: 'min-w-10 text-end', row: 'flex items-center gap-3' })) {
    classes[key] = exactlyOne(card.text, new RegExp(`className:\x60(${escape(prefix)}[^\x60]*)\x60`, 'g'), `official ${key} style`)[1];
  }
  const fallback = `${card.name}_codexFixOriginal`;
  const dismissed = `${card.name}_codexFixDismissedId`;
  if (text.includes(fallback) || text.includes(dismissed)) throw new Error('Update card adapter identifier collides');
  // Reuse the original modal primitives and theme classes, without touching
  // React compiler cache slots. Every render reads the newest stage string.
  const wrapper = `let ${dismissed};function ${card.name}(props){/* ${UPDATE_CARD_MARKER} */
    ${initialize}();
    const state=${atom.read}(${state}),store=${store.hook}(${store.scope}),update=state.codexFixUpdate;
    if(!update||!(typeof update.id==='string'||Number.isFinite(update.id)))return (0,${title.jsx}.jsx)(${fallback},props);
    if(update.done===true&&update.id===${dismissed})return (0,${title.jsx}.jsx)(${fallback},props);
    const done=update.done===true,percent=Number.isFinite(update.percent)?Math.max(0,Math.min(100,Math.round(update.percent))):null;
    const title=typeof update.title==='string'?update.title:'Codex_Fix 更新';
    const message=typeof update.message==='string'?update.message:'';
    const subtitle=done?(update.restartRequired?'更新已准备好；关闭此窗口后，可使用应用的更新按钮确认重启。':'当前会话保持运行。'):'当前会话保持运行；更新就绪后，由你确认重启。';
    const close=()=>{if(done){${dismissed}=update.id;store.set(${state},{...store.get(${state}),codexFixUpdate:null,installProgressPercent:null})}};
    const fill=(0,${title.jsx}.jsx)('div',{className:percent===null?${JSON.stringify(classes.pulse)}:${JSON.stringify(classes.fill)},...(percent===null?{}:{style:{width:percent+'%'}})});
    const progress=(0,${title.jsx}.jsxs)('div',{className:${JSON.stringify(classes.row)},children:[
      (0,${title.jsx}.jsx)('div',{className:${JSON.stringify(classes.track)},role:'progressbar','aria-label':'更新进度','aria-valuemin':0,'aria-valuemax':100,'aria-valuenow':percent===null?undefined:percent,children:fill}),
      (0,${title.jsx}.jsx)('span',{className:${JSON.stringify(classes.percent)},role:'status','aria-live':'polite',children:message+(percent===null?'':' '+percent+'%')})]});
    return (0,${title.jsx}.jsx)(${modal.dialog},{open:true,onOpenChange:open=>{if(!open)close()},shouldIgnoreClickOutside:!done,showDialogClose:false,size:'compact',contentProps:{onEscapeKeyDown:event=>{if(!done)event.preventDefault();else close()}},children:
      (0,${title.jsx}.jsx)(${modal.body},{children:(0,${title.jsx}.jsxs)(${modal.content},{className:'gap-3',children:[
        (0,${title.jsx}.jsx)(${title.title},{className:'sr-only',children:title}),
        (0,${title.jsx}.jsx)(${header.header},{title,subtitle,titleSize:'base',subtitleSize:'sm'}),
        !done&&progress,
        done&&(0,${title.jsx}.jsx)('div',{className:'text-sm text-secondary',role:'status','aria-live':'polite',children:message}),
        done&&(0,${title.jsx}.jsx)(${button},{color:'secondary',onClick:close,children:'关闭'})]})})});
  }`;
  const original = card.text.replace(`function ${card.name}(`, `function ${fallback}(`);
  return syntaxChecked(text.slice(0, card.start) + wrapper + original + text.slice(card.end));
}

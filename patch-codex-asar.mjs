import { createHash } from "node:crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readSync,
  renameSync,
  rmSync,
  statSync,
  writeSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const hash = (value) => createHash("sha256").update(value).digest("hex");
const align4 = (value) => (value + 3) & ~3;

function matchExactlyOnce(source, pattern, label) {
  const matches = [...source.matchAll(pattern)];
  if (matches.length !== 1) {
    throw new Error(`Expected exactly one ${label}, found ${matches.length}`);
  }
  return matches[0].groups ?? {};
}

function sectionExactlyOnce(source, start, end, label) {
  const first = source.indexOf(start);
  const second = first < 0 ? -1 : source.indexOf(start, first + start.length);
  const finish = first < 0 ? -1 : source.indexOf(end, first + start.length);
  if (first < 0 || second >= 0 || finish < 0) {
    throw new Error(`Expected exactly one ${label} section`);
  }
  return source.slice(first, finish);
}

function discoverMainBindings(source) {
  const proxy = sectionExactlyOnce(
    source,
    "createSshProxyStream(e){",
    "async runWithSshStartupGate(e){",
    "SSH proxy",
  );
  const login = sectionExactlyOnce(
    source,
    "async runRemoteLoginShellCommand(",
    "createSshProxyStream(e){",
    "remote login shell",
  );
  const reference = "[A-Za-z_$][\\w$]*(?:\\.[A-Za-z_$][\\w$]*)*";
  const capture = (text, pattern, label) =>
    matchExactlyOnce(text, new RegExp(pattern, "gu"), label);

  const result = {
    ...capture(
      proxy,
      `^createSshProxyStream\\(e\\)\\{let t=(?<codexExecutable>${reference})\\(\\),`,
      "Codex executable binding",
    ),
    ...capture(
      proxy,
      `this\\.logger\\.info\\(\\x60ssh_websocket_v0\\.proxy_command_starting\\x60,\\{safe:\\{operation:\\x60app_server_proxy\\x60,\\.\\.\\.(?<shellMetadata>${reference})\\(e\\.shellEnv\\),sshCommandKind:`,
      "shell metadata binding",
    ),
    ...capture(
      proxy,
      `let [A-Za-z_$][\\w$]*=(?<spawnFunction>\\(0,${reference}\\))\\((?<executableResolver>${reference})\\.resolve\\(\\x60ssh\\x60\\)\\?\\?\\x60ssh\\x60,\\[\\x60-T\\x60,\\.\\.\\.(?<sshOptions>${reference})\\(this\\.options\\.getConnectTimeoutSeconds\\?\\.\\(\\)\\),\\.\\.\\.(?<sshDestination>${reference})\\(this\\.options\\.sshConnection\\),[\\s\\S]+?\\],\\{env:(?<environmentNormalizer>${reference})\\(process\\.env\\),stdio:\\[\\x60pipe\\x60,\\x60pipe\\x60,\\x60pipe\\x60\\]\\}\\)`,
      "SSH stream spawn bindings",
    ),
    ...capture(
      proxy,
      `new (?<duplexConstructor>${reference})\\(\\{read\\(\\)\\{`,
      "Duplex stream binding",
    ),
    ...capture(
      proxy,
      `let [A-Za-z_$][\\w$]*=(?<stderrSanitizer>${reference})\\([A-Za-z_$][\\w$]*\\);this\\.logger\\.warning\\(\\x60ssh_websocket_v0\\.proxy_command_failed\\x60`,
      "stderr sanitizer binding",
    ),
    ...capture(
      login,
      `async runRemoteLoginShellCommand\\(\\{command:e,context:t,operation:n,timeoutMessage:r,timeoutMs:i=(?<timeouts>${reference})\\.remoteLoginShellCommandMinimum\\}\\)`,
      "remote command timeout binding",
    ),
    ...capture(
      login,
      `Math\\.max\\((?<timeoutsAgain>${reference})\\.remoteLoginShellCommandMinimum,\\(c\\?\\?0\\)\\*1e3,a\\),u=(?<processSpawner>${reference})\\(\\{args:\\[\\x60ssh\\x60,\\.\\.\\.(?<sshOptionsAgain>${reference})\\(c\\),\\.\\.\\.(?<sshDestinationAgain>${reference})\\(this\\.options\\.sshConnection\\),`,
      "remote command spawn bindings",
    ),
  };

  for (const [first, second] of [
    ["timeouts", "timeoutsAgain"],
    ["sshOptions", "sshOptionsAgain"],
    ["sshDestination", "sshDestinationAgain"],
  ]) {
    if (result[first] !== result[second]) {
      throw new Error(`Inconsistent ${first} binding in official SSH transport`);
    }
    delete result[second];
  }
  return result;
}

function discoverUpdateMenuBindings(source) {
  const reference = "[A-Za-z_$][\\w$]*(?:\\.[A-Za-z_$][\\w$]*)*";
  const result = matchExactlyOnce(
    source,
    new RegExp(
      `(?<handler>click:\\(\\)=>\\{(?<logger>${reference})\\(\\)\\.info\\(\\x60Check for updates requested via menu\\.\\x60\\),(?<manager>${reference})\\.checkForUpdates\\(\\)\\.then\\(\\(\\)=>\\{if\\((?<managerHas>${reference})\\.hasUpdater\\(\\)\\)return;let e=(?<managerReason>${reference})\\.getUnavailableReason\\(\\)\\?\\?\\x60unknown\\x60;(?<loggerWarn>${reference})\\(\\)\\.warning\\(\\x60Desktop updater unavailable; init likely skipped\\.\\x60,\\{safe:\\{reason:e\\},sensitive:\\{\\}\\}\\),(?<electron>${reference})\\.dialog\\.showMessageBox\\(\\{type:\\x60info\\x60,title:\\x60Updates Unavailable\\x60,message:\\x60Automatic updates are unavailable right now\\.\\x60,detail:\\x60Updater initialization skipped: \\$\\{e\\}\\x60\\}\\)\\}\\)\\})`,
      "gu",
    ),
    "desktop update menu handler",
  );
  if (
    result.manager !== result.managerHas ||
    result.manager !== result.managerReason ||
    result.logger !== result.loggerWarn
  ) {
    throw new Error("Inconsistent bindings in desktop update menu handler");
  }
  delete result.managerHas;
  delete result.managerReason;
  delete result.loggerWarn;
  return result;
}

function readExact(fd, size, position) {
  const value = Buffer.alloc(size);
  let offset = 0;
  while (offset < size) {
    const bytesRead = readSync(fd, value, offset, size - offset, position + offset);
    if (bytesRead === 0) {
      throw new Error(`Short ASAR read at ${position + offset}`);
    }
    offset += bytesRead;
  }
  return value;
}

function writeExact(fd, value, position) {
  let offset = 0;
  while (offset < value.length) {
    const bytesWritten = writeSync(
      fd,
      value,
      offset,
      value.length - offset,
      position + offset,
    );
    if (bytesWritten === 0) {
      throw new Error(`Short ASAR write at ${position + offset}`);
    }
    offset += bytesWritten;
  }
}

function parseArchive(archivePath) {
  const fd = openSync(archivePath, "r");
  try {
    const archiveSize = statSync(archivePath).size;
    const sizePickle = readExact(fd, 8, 0);
    if (sizePickle.readUInt32LE(0) !== 4) {
      throw new Error("Unsupported ASAR size pickle");
    }
    const headerSize = sizePickle.readUInt32LE(4);
    if (headerSize < 8 || 8 + headerSize > archiveSize) {
      throw new Error(`Invalid ASAR header size: ${headerSize}`);
    }
    const headerPickle = readExact(fd, headerSize, 8);
    const jsonSize = headerPickle.readUInt32LE(4);
    if (jsonSize < 1 || 8 + jsonSize > headerPickle.length) {
      throw new Error(`Invalid ASAR JSON size: ${jsonSize}`);
    }
    const header = JSON.parse(
      headerPickle.subarray(8, 8 + jsonSize).toString("utf8"),
    );
    const entries = [];
    let traversalIndex = 0;
    const visit = (node, prefix = "") => {
      for (const [name, entry] of Object.entries(node.files ?? {})) {
        const path = prefix ? `${prefix}/${name}` : name;
        if (entry.files) {
          visit(entry, path);
        } else if (
          !entry.unpacked &&
          entry.link == null &&
          entry.offset != null &&
          entry.size != null
        ) {
          const offset = Number(entry.offset);
          const size = Number(entry.size);
          if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(size)) {
            throw new Error(`Invalid packed entry metadata: ${path}`);
          }
          entries.push({ entry, path, offset, size, traversalIndex });
          traversalIndex += 1;
        }
      }
    };
    visit(header);
    entries.sort((a, b) => a.offset - b.offset || a.traversalIndex - b.traversalIndex);
    const dataOffset = 8 + headerSize;
    for (const item of entries) {
      if (item.offset + item.size > archiveSize - dataOffset) {
        throw new Error(`Packed entry exceeds archive: ${item.path}`);
      }
    }
    return { archiveSize, dataOffset, entries, fd, header, headerSize };
  } catch (error) {
    closeSync(fd);
    throw error;
  }
}

function serializeHeader(header) {
  const json = Buffer.from(JSON.stringify(header), "utf8");
  const headerSize = align4(8 + json.length);
  const sizePickle = Buffer.alloc(8);
  sizePickle.writeUInt32LE(4, 0);
  sizePickle.writeUInt32LE(headerSize, 4);
  const headerPickle = Buffer.alloc(headerSize);
  headerPickle.writeUInt32LE(headerSize - 4, 0);
  headerPickle.writeUInt32LE(json.length, 4);
  json.copy(headerPickle, 8);
  return { headerPickle, sizePickle };
}

function makeIntegrity(value, blockSize = 4 * 1024 * 1024) {
  const blocks = [];
  for (let offset = 0; offset < value.length; offset += blockSize) {
    blocks.push(hash(value.subarray(offset, Math.min(value.length, offset + blockSize))));
  }
  return {
    algorithm: "SHA256",
    hash: hash(value),
    blockSize,
    blocks,
  };
}

function assertNodeSyntax(source, label) {
  const syntax = spawnSync(process.execPath, ["--check", "-"], {
    input: source,
    encoding: "utf8",
  });
  if (syntax.status !== 0) {
    throw new Error(`${label} syntax check failed: ${syntax.stderr}`);
  }
}

function copyRange(inputFd, outputFd, inputPosition, outputPosition, size) {
  const buffer = Buffer.allocUnsafe(Math.min(4 * 1024 * 1024, Math.max(1, size)));
  let copied = 0;
  while (copied < size) {
    const wanted = Math.min(buffer.length, size - copied);
    const bytesRead = readSync(inputFd, buffer, 0, wanted, inputPosition + copied);
    if (bytesRead !== wanted) {
      throw new Error(`Short packed-data read at ${inputPosition + copied}`);
    }
    writeExact(outputFd, buffer.subarray(0, bytesRead), outputPosition + copied);
    copied += bytesRead;
  }
}

function rewriteArchive(inputPath, outputPath, replacements) {
  const parsed = parseArchive(inputPath);
  const absoluteOutput = resolve(outputPath);
  const temporaryOutput = join(
    dirname(absoluteOutput),
    `.${absoluteOutput.split(/[\\/]/u).pop()}.tmp-${process.pid}`,
  );
  if (resolve(inputPath) === absoluteOutput) {
    closeSync(parsed.fd);
    throw new Error("Input and output ASAR paths must differ");
  }
  if (existsSync(absoluteOutput) || existsSync(temporaryOutput)) {
    closeSync(parsed.fd);
    throw new Error(`Refusing to overwrite existing output: ${absoluteOutput}`);
  }

  let nextOffset = 0;
  for (const item of parsed.entries) {
    const replacement = replacements.get(item.path);
    item.entry.offset = String(nextOffset);
    if (replacement) {
      item.entry.size = replacement.length;
      item.entry.integrity = makeIntegrity(
        replacement,
        item.entry.integrity?.blockSize ?? 4 * 1024 * 1024,
      );
      nextOffset += replacement.length;
    } else {
      nextOffset += item.size;
    }
  }

  const { headerPickle, sizePickle } = serializeHeader(parsed.header);
  let outputFd;
  try {
    outputFd = openSync(temporaryOutput, "wx");
    writeExact(outputFd, sizePickle, 0);
    writeExact(outputFd, headerPickle, sizePickle.length);
    let outputPosition = sizePickle.length + headerPickle.length;
    for (const item of parsed.entries) {
      const replacement = replacements.get(item.path);
      if (replacement) {
        writeExact(outputFd, replacement, outputPosition);
        outputPosition += replacement.length;
      } else {
        copyRange(
          parsed.fd,
          outputFd,
          parsed.dataOffset + item.offset,
          outputPosition,
          item.size,
        );
        outputPosition += item.size;
      }
    }
    fsyncSync(outputFd);
    closeSync(outputFd);
    outputFd = undefined;
    closeSync(parsed.fd);
    renameSync(temporaryOutput, absoluteOutput);
  } catch (error) {
    if (outputFd != null) closeSync(outputFd);
    closeSync(parsed.fd);
    rmSync(temporaryOutput, { force: true });
    throw error;
  }
}

function patchMainBundle(source, controllerScript) {
  const inputHash = hash(source);
  let patched = source.toString("utf8");
  const build = discoverMainBindings(patched);
  const updateMenu = discoverUpdateMenuBindings(patched);
  const replaceOnce = (needle, replacement, label) => {
    const first = patched.indexOf(needle);
    if (first < 0 || patched.indexOf(needle, first + needle.length) >= 0) {
      throw new Error(`Expected exactly one ${label} patch point`);
    }
    patched = `${patched.slice(0, first)}${replacement}${patched.slice(first + needle.length)}`;
  };

  const updaterSuffix =
    "\\OpenAI\\Codex-Windows-SSH\\updater\\Update-Codex-Windows-SSH.ps1";
  const updateClickHandler = [
    "click:()=>{",
    `${updateMenu.logger}().info(\x60Check for updates requested via Codex Windows SSH.\x60);`,
    "let e=process.env.LOCALAPPDATA;",
    `if(!e){${updateMenu.electron}.dialog.showMessageBox({type:\x60error\x60,title:\x60Update Check Failed\x60,message:\x60LOCALAPPDATA is unavailable; the patched updater could not be located.\x60});return}`,
    `let t=e+${JSON.stringify(updaterSuffix)},n=${build.spawnFunction}(\x60pwsh.exe\x60,[\x60-NoLogo\x60,\x60-NoProfile\x60,\x60-NonInteractive\x60,\x60-File\x60,t,\x60-Menu\x60],{detached:!0,stdio:\x60ignore\x60,windowsHide:!0});`,
    `n.once(\x60error\x60,e=>{${updateMenu.logger}().warning(\x60Failed to start Codex Windows SSH updater.\x60,{safe:{},sensitive:{error:e}}),${updateMenu.electron}.dialog.showMessageBox({type:\x60error\x60,title:\x60Update Check Failed\x60,message:\x60Could not start the Codex Windows SSH updater.\x60,detail:e instanceof Error?e.message:String(e)})}),n.unref()}`,
  ].join("");
  replaceOnce(
    updateMenu.handler,
    updateClickHandler,
    "desktop update menu handler",
  );

  replaceOnce(
    "proxyStreams=new Set;hasConnected=!1;installedCodexVersion;constructor",
    "proxyStreams=new Set;hasConnected=!1;installedCodexVersion;windowsSshDetected=!1;windowsSshPort;windowsController;constructor",
    "class fields",
  );
  replaceOnce(
    "dispose(){for(let e of this.proxyStreams)e.destroy();this.proxyStreams.clear()}",
    "dispose(){for(let e of this.proxyStreams)e.destroy();this.proxyStreams.clear(),this.disposeWindowsController()}",
    "dispose lifecycle",
  );
  replaceOnce(
    "if(this.hasConnected)try{return await this.connectToRemoteAppServer(t)}catch(e)",
    "if(this.hasConnected&&(!this.windowsSshDetected||this.windowsSshPort!=null))try{return await this.connectToRemoteAppServer(t)}catch(e)",
    "reconnect guard",
  );
  replaceOnce(
    "return this.installedCodexVersion=void 0,await this.ensureRemoteAppServer(t),this.connectToRemoteAppServer(t)}",
    "return this.installedCodexVersion=void 0,(await this.tryEnsureWindowsRemoteAppServer(t))||await this.ensureRemoteAppServer(t),this.connectToRemoteAppServer(t)}",
    "automatic platform branch",
  );

  const methods = [
    "disposeWindowsController(){this.windowsSshPort=void 0;let e=this.windowsController;this.windowsController=void 0,e?.kill()}",
    "async tryEnsureWindowsRemoteAppServer(e){return this.runWithSshStartupGate(async()=>{",
    "this.disposeWindowsController();let script=",
    JSON.stringify(controllerScript),
    `,encoded=Buffer.from(script,\`utf16le\`).toString(\`base64\`),pending=\`\`,stdoutTail=\`\`,stderrTail=\`\`,sawWindows=!1,resolveEndpoint,rejectEndpoint,endpointPromise=new Promise((e,t)=>{resolveEndpoint=e,rejectEndpoint=t}),connectSeconds=this.options.getConnectTimeoutSeconds?.(),timeoutMs=Math.max(${build.timeouts}.remoteLoginShellCommandMinimum,(connectSeconds??0)*1e3),controller=${build.processSpawner}({args:[\`ssh\`,\`-T\`,...${build.sshOptions}(connectSeconds),...${build.sshDestination}(this.options.sshConnection),\`powershell.exe\`,\`-NoLogo\`,\`-NoProfile\`,\`-NonInteractive\`,\`-EncodedCommand\`,encoded],spawnInsideWsl:!1,collectOutput:!1,stdoutChunkHandler:e=>{let t=e.toString(\`utf8\`);pending+=t,stdoutTail=\`${"${stdoutTail}${t}"}\`.slice(-4e3);let n=pending.split(/\\r?\\n/u);pending=n.pop()??\`\`;for(let e of n){let t=e.trim();if(t===\`CODEX_WINDOWS_CONTROLLER_V1\`)this.windowsSshDetected=sawWindows=!0;else if(t.startsWith(\`CODEX_WINDOWS_ENDPOINT_V1 \`))try{let e=JSON.parse(t.slice(\`CODEX_WINDOWS_ENDPOINT_V1 \`.length));Number.isInteger(e.port)&&e.port>0&&e.port<65536?resolveEndpoint({kind:\`endpoint\`,endpoint:e}):rejectEndpoint(Error(\`Windows controller returned an invalid endpoint\`))}catch(e){rejectEndpoint(e)}}},stderrChunkHandler:e=>{stderrTail=\`${"${stderrTail}${e.toString(`utf8`)}"}\`.slice(-4e3)}});`,
    "this.windowsController=controller;let timeoutHandle,outcome;try{let e=new Promise((e,t)=>{timeoutHandle=setTimeout(()=>t(Error(`SSH: Windows app-server bootstrap timed out after ${timeoutMs}ms`)),timeoutMs),timeoutHandle.unref()});outcome=await Promise.race([endpointPromise,controller.wait().then(e=>({kind:`exit`,result:e})),e])}catch(e){controller.kill(),this.windowsController===controller&&(this.windowsController=void 0);throw this.createSshSetupError(`remote_app_server_start`,e)}finally{timeoutHandle!=null&&clearTimeout(timeoutHandle)}",
    "if(outcome.kind===`exit`){this.windowsController===controller&&(this.windowsController=void 0);let e={...outcome.result,stdout:stdoutTail,stderr:stderrTail};if(!sawWindows&&(e.code===127||e.code===87))return this.windowsSshDetected=!1,!1;throw this.createSshSetupError(`remote_app_server_start`,Error(await this.getSshCommandFailureMessage(e)))}",
    "this.windowsSshDetected=!0,this.windowsSshPort=outcome.endpoint.port;let clear=()=>{this.windowsController===controller&&(this.windowsController=void 0,this.windowsSshPort=void 0)};controller.wait().then(e=>{clear(),this.logger.info(`ssh_websocket_v0.windows_controller_completed`,{safe:{code:e.code},sensitive:{sshAlias:this.options.sshConnection.alias,sshHost:this.options.sshConnection.host,sshPort:this.options.sshConnection.port,stderr:stderrTail}})},e=>{clear(),this.logger.warning(`ssh_websocket_v0.windows_controller_failed`,{safe:{},sensitive:{error:e,sshAlias:this.options.sshConnection.alias,sshHost:this.options.sshConnection.host,sshPort:this.options.sshConnection.port,stderr:stderrTail}})}),this.logger.info(`ssh_websocket_v0.windows_app_server_ready`,{safe:{port:outcome.endpoint.port},sensitive:{sshAlias:this.options.sshConnection.alias,sshHost:this.options.sshConnection.host,sshPort:this.options.sshConnection.port}});return!0})}",
  ].join("");
  replaceOnce(
    "async ensureRemoteAppServer(e){",
    `${methods}async ensureRemoteAppServer(e){`,
    "Windows controller method insertion",
  );
  replaceOnce(
    "async killCodexProcess(){let{code:e,stdout:t,stderr:r}=await this.runRemoteLoginShellCommand",
    "async killCodexProcess(){if(this.windowsSshDetected){for(let e of this.proxyStreams)e.destroy();this.proxyStreams.clear(),this.disposeWindowsController();return}let{code:e,stdout:t,stderr:r}=await this.runRemoteLoginShellCommand",
    "Windows stop branch",
  );

  const proxyMethod = [
    "createWindowsSshProxyStream(e){let t=this.windowsSshPort;if(t==null)throw Error(`Windows SSH app-server port is unavailable`);",
    `this.logger.info(\`ssh_websocket_v0.windows_proxy_command_starting\`,{safe:{operation:\`app_server_proxy\`,port:t,...${build.shellMetadata}(e.shellEnv),sshCommandKind:\`ssh_direct_tcpip\`,sshPhase:e.phase},sensitive:{sshAlias:this.options.sshConnection.alias,sshHost:this.options.sshConnection.host,sshPort:this.options.sshConnection.port}});`,
    `let r=${build.spawnFunction}(${build.executableResolver}.resolve(\`ssh\`)??\`ssh\`,[\`-T\`,...${build.sshOptions}(this.options.getConnectTimeoutSeconds?.()),\`-W\`,\`127.0.0.1:${"${t}"}\`,...${build.sshDestination}(this.options.sshConnection)],{env:${build.environmentNormalizer}(process.env),stdio:[\`pipe\`,\`pipe\`,\`pipe\`],windowsHide:!0}),{stdin:a,stdout:o,stderr:s}=r;if(a==null||o==null||s==null)throw r.kill(),Error(\`ssh direct-tcpip stdio was unavailable\`);`,
    `let c=\`\`;s.on(\`data\`,e=>{c=\`${"${c}${e.toString(`utf8`)}"}\`.slice(-4e3)});let l=new ${build.duplexConstructor}({read(){o.resume()},write(e,t,n){a.write(e,t,n)},final(e){a.end(),e()},destroy(e,t){r.kill(),t(e)}});Object.assign(l,{setKeepAlive:()=>l,setNoDelay:()=>l,setTimeout:()=>l});`,
    "let u=e=>{l.destroy(e)};a.on(`error`,u),o.on(`error`,u),this.proxyStreams.add(l),l.once(`close`,()=>{this.proxyStreams.delete(l)}),o.on(`data`,e=>{e.length!==0&&(l.push(e)||o.pause())}),o.on(`end`,()=>{l.push(null)}),r.on(`error`,e=>{l.destroy(e)}),",
    `r.on(\`close\`,(t,n)=>{if(a.removeListener(\`error\`,u),o.removeListener(\`error\`,u),t===0){l.push(null);return}let r=${build.stderrSanitizer}(c);this.logger.warning(\`ssh_websocket_v0.windows_proxy_command_failed\`,{safe:{code:t,operation:\`app_server_proxy\`,...${build.shellMetadata}(e.shellEnv),signal:n,sshCommandKind:\`ssh_direct_tcpip\`,sshPhase:e.phase},sensitive:{sshAlias:this.options.sshConnection.alias,sshHost:this.options.sshConnection.host,sshPort:this.options.sshConnection.port,stderr:c}}),l.destroy(Error(\`ssh -W exited with code ${"${t}"}, signal ${"${n}"}: ${"${r}"}\`))}),queueMicrotask(()=>{l.emit(\`connect\`)});return l}`,
  ].join("");
  replaceOnce(
    `createSshProxyStream(e){let t=${build.codexExecutable}()`,
    `${proxyMethod}createSshProxyStream(e){if(this.windowsSshPort!=null)return this.createWindowsSshProxyStream(e);let t=${build.codexExecutable}()`,
    "Windows direct-tcpip method insertion",
  );

  const output = Buffer.from(patched, "utf8");
  assertNodeSyntax(output, "Patched main bundle");
  return {
    inputHash,
    output,
    outputHash: hash(output),
    compatibility: "structural",
  };
}

function verifyArchive(archivePath) {
  const parsed = parseArchive(archivePath);
  try {
    const main = findMainEntry(parsed);
    const source = readExact(parsed.fd, main.size, parsed.dataOffset + main.offset);
    const mainHash = hash(source);
    for (const token of [
      "CODEX_WINDOWS_CONTROLLER_V1",
      "CODEX_WINDOWS_ENDPOINT_V1",
      "windowsSshDetected",
      "ssh_direct_tcpip",
      "collectOutput:!1",
      "toString(`utf8`)",
      "Check for updates requested via Codex Windows SSH.",
      "Update-Codex-Windows-SSH.ps1",
      "windowsHide:!0",
    ]) {
      if (!source.includes(token)) {
        throw new Error(`Patched main bundle is missing: ${token}`);
      }
    }
    for (const token of [
      "windowsSshDetected=!1;windowsSshPort;windowsController;constructor",
      "disposeWindowsController(){",
      "async tryEnsureWindowsRemoteAppServer(e){",
      "createWindowsSshProxyStream(e){",
      "if(this.windowsSshPort!=null)return this.createWindowsSshProxyStream(e);",
    ]) {
      const first = source.indexOf(token);
      if (first < 0 || source.indexOf(token, first + token.length) >= 0) {
        throw new Error(`Expected exactly one patched structure: ${token}`);
      }
    }
    for (const token of [
      "CODEX_WINDOWS_SSH_HOSTS",
      "codex-app-server-ws.ps1",
      "windows_app_server_manager",
      "Automatic updates are unavailable right now.",
    ]) {
      if (source.includes(token)) {
        throw new Error(`Patched main bundle contains a legacy token: ${token}`);
      }
    }
    if (main.entry.integrity?.hash !== mainHash) {
      throw new Error("Patched main ASAR integrity hash does not match its bytes");
    }
    const computedIntegrity = makeIntegrity(
      source,
      main.entry.integrity.blockSize,
    );
    if (
      computedIntegrity.blocks.length !== main.entry.integrity.blocks?.length ||
      computedIntegrity.blocks.some(
        (block, index) => block !== main.entry.integrity.blocks[index],
      )
    ) {
      throw new Error("Patched main ASAR integrity blocks do not match its bytes");
    }
    assertNodeSyntax(source, "Verified main bundle");
    return {
      ok: true,
      verified: true,
      compatibility: "structural",
      mainEntryPath: main.path,
      mainSha256: mainHash,
      archivePath: resolve(archivePath),
      packedEntryCount: parsed.entries.length,
    };
  } finally {
    closeSync(parsed.fd);
  }
}

function findMainEntry(parsed) {
  const candidates = parsed.entries.filter((item) =>
    /^\.vite\/build\/main-[^/]+\.js$/u.test(item.path),
  );
  if (candidates.length !== 1) {
    throw new Error(`Expected one Electron main bundle, found ${candidates.length}`);
  }
  return candidates[0];
}

function patchArchive(inputPath, outputPath, checkOnly = false) {
  const parsed = parseArchive(inputPath);
  let result;
  let main;
  try {
    main = findMainEntry(parsed);
    const source = readExact(parsed.fd, main.size, parsed.dataOffset + main.offset);
    const controllerScript = readFileSync(
      new URL("./codex-windows-controller.ps1", import.meta.url),
      "utf8",
    ).replace(/\r\n/gu, "\n");
    result = patchMainBundle(source, controllerScript);
  } finally {
    closeSync(parsed.fd);
  }
  if (!checkOnly) {
    rewriteArchive(inputPath, outputPath, new Map([[main.path, result.output]]));
  }
  return {
    ok: true,
    checkOnly,
    compatibility: result.compatibility,
    mainEntryPath: main.path,
    inputMainSha256: result.inputHash,
    outputMainSha256: result.outputHash,
    inputAsar: resolve(inputPath),
    outputAsar: checkOnly ? null : resolve(outputPath),
  };
}

function makeSyntheticMain(bindings) {
  return Buffer.from(
    [
      "class SyntheticTransport{",
      "proxyStreams=new Set;hasConnected=!1;installedCodexVersion;constructor(){}",
      "dispose(){for(let e of this.proxyStreams)e.destroy();this.proxyStreams.clear()}",
      "async connect(t){if(this.hasConnected)try{return await this.connectToRemoteAppServer(t)}catch(e){}return this.installedCodexVersion=void 0,await this.ensureRemoteAppServer(t),this.connectToRemoteAppServer(t)}",
      "async ensureRemoteAppServer(e){}",
      "async killCodexProcess(){let{code:e,stdout:t,stderr:r}=await this.runRemoteLoginShellCommand({});return e+t+r}",
      `async runRemoteLoginShellCommand({command:e,context:t,operation:n,timeoutMessage:r,timeoutMs:i=${bindings.timeouts}.remoteLoginShellCommandMinimum}){return this.runRemoteLoginShellCommandWithoutGate({command:e,context:t,operation:n,timeoutMessage:r,timeoutMs:i})}`,
      `async runRemoteLoginShellCommandWithoutGate({command:e,context:t,operation:r,timeoutMessage:i,timeoutMs:a=${bindings.timeouts}.remoteLoginShellCommandMinimum}){let c=this.options.getConnectTimeoutSeconds?.(),l=Math.max(${bindings.timeouts}.remoteLoginShellCommandMinimum,(c??0)*1e3,a),u=${bindings.processSpawner}({args:[\`ssh\`,...${bindings.sshOptions}(c),...${bindings.sshDestination}(this.options.sshConnection),e],spawnInsideWsl:!1});return u}`,
      `createSshProxyStream(e){let t=${bindings.codexExecutable}(),r=\`proxy\`,i=0;this.logger.info(\`ssh_websocket_v0.proxy_command_starting\`,{safe:{operation:\`app_server_proxy\`,...${bindings.shellMetadata}(e.shellEnv),sshCommandKind:\`app_server_proxy\`}});let a=${bindings.spawnFunction}(${bindings.executableResolver}.resolve(\`ssh\`)??\`ssh\`,[\`-T\`,...${bindings.sshOptions}(this.options.getConnectTimeoutSeconds?.()),...${bindings.sshDestination}(this.options.sshConnection),r],{env:${bindings.environmentNormalizer}(process.env),stdio:[\`pipe\`,\`pipe\`,\`pipe\`]}),{stdin:o,stdout:s,stderr:c}=a,l=\`\`,u=new ${bindings.duplexConstructor}({read(){s.resume()}});a.on(\`close\`,()=>{let r=${bindings.stderrSanitizer}(l);this.logger.warning(\`ssh_websocket_v0.proxy_command_failed\`,{})});return u}`,
      "async runWithSshStartupGate(e){return e()}",
      "}",
      `const SyntheticUpdateMenu={click:()=>{${bindings.updateLogger}().info(\`Check for updates requested via menu.\`),${bindings.updateManager}.checkForUpdates().then(()=>{if(${bindings.updateManager}.hasUpdater())return;let e=${bindings.updateManager}.getUnavailableReason()??\`unknown\`;${bindings.updateLogger}().warning(\`Desktop updater unavailable; init likely skipped.\`,{safe:{reason:e},sensitive:{}}),${bindings.electron}.dialog.showMessageBox({type:\`info\`,title:\`Updates Unavailable\`,message:\`Automatic updates are unavailable right now.\`,detail:\`Updater initialization skipped: ${"${e}"}\`})})}};`,
    ].join(""),
    "utf8",
  );
}

function selfTest() {
  const root = mkdtempSync(join(tmpdir(), "codex-asar-self-test-"));
  const input = join(root, "input.asar");
  const output = join(root, "output.asar");
  try {
    const first = makeSyntheticMain({
      codexExecutable: "SS",
      duplexConstructor: "E.Duplex",
      environmentNormalizer: "i.t",
      executableResolver: "n.Kn",
      processSpawner: "n.Bn",
      shellMetadata: "GS",
      spawnFunction: "(0,x.spawn)",
      sshDestination: "HS",
      sshOptions: "BS",
      stderrSanitizer: "VS",
      timeouts: "MS",
      updateLogger: "UL",
      updateManager: "UM",
      electron: "EL",
    });
    const second = Buffer.from([0, 1, 2, 3]);
    const header = {
      files: {
        ".vite": {
          files: {
            build: {
              files: {
                "main-test.js": {
                  size: first.length,
                  offset: "0",
                  integrity: makeIntegrity(first),
                },
              },
            },
          },
        },
        nested: {
          files: {
            "second.bin": {
              size: second.length,
              offset: String(first.length),
              integrity: makeIntegrity(second),
            },
          },
        },
      },
    };
    const { headerPickle, sizePickle } = serializeHeader(header);
    const fd = openSync(input, "wx");
    try {
      let position = 0;
      for (const value of [sizePickle, headerPickle, first, second]) {
        writeExact(fd, value, position);
        position += value.length;
      }
    } finally {
      closeSync(fd);
    }
    patchArchive(input, output);
    verifyArchive(output);
    const parsed = parseArchive(output);
    try {
      const byPath = new Map(parsed.entries.map((item) => [item.path, item]));
      const firstEntry = byPath.get(".vite/build/main-test.js");
      const secondEntry = byPath.get("nested/second.bin");
      const firstValue = readExact(
        parsed.fd,
        firstEntry.size,
        parsed.dataOffset + firstEntry.offset,
      );
      const secondValue = readExact(
        parsed.fd,
        secondEntry.size,
        parsed.dataOffset + secondEntry.offset,
      );
      if (
        !firstValue.includes("createWindowsSshProxyStream") ||
        !firstValue.includes("Update-Codex-Windows-SSH.ps1") ||
        firstValue.includes("Automatic updates are unavailable right now.") ||
        !secondValue.equals(second)
      ) {
        throw new Error("ASAR self-test content mismatch");
      }
      if (firstEntry.entry.integrity.hash !== hash(firstValue)) {
        throw new Error("ASAR self-test integrity mismatch");
      }
    } finally {
      closeSync(parsed.fd);
    }

    const renamed = makeSyntheticMain({
      codexExecutable: "HC",
      duplexConstructor: "E.Duplex",
      environmentNormalizer: "n.hi",
      executableResolver: "n.Gn",
      processSpawner: "n.zn",
      shellMetadata: "dw",
      spawnFunction: "(0,x.spawn)",
      sshDestination: "cw",
      sshOptions: "ow",
      stderrSanitizer: "sw",
      timeouts: "QC",
      updateLogger: "uL",
      updateManager: "uM",
      electron: "eL",
    });
    const renamedResult = patchMainBundle(renamed, "Write-Output test");
    if (!renamedResult.output.includes("env:n.hi(process.env)")) {
      throw new Error("Renamed binding self-test failed");
    }

    let rejectedChangedStructure = false;
    try {
      patchMainBundle(
        Buffer.from(
          renamed
            .toString("utf8")
            .replace(
              "dispose(){for(let e of this.proxyStreams)e.destroy();this.proxyStreams.clear()}",
              "dispose(){}",
            ),
          "utf8",
        ),
        "Write-Output test",
      );
    } catch (error) {
      rejectedChangedStructure = /dispose lifecycle/u.test(error.message);
    }
    if (!rejectedChangedStructure) {
      throw new Error("Changed structure did not fail closed");
    }
    return {
      ok: true,
      selfTest: true,
      structuralCompatibility: true,
      changedStructureFailsClosed: true,
    };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const args = process.argv.slice(2);
let result;
if (args[0] === "--self-test" && args.length === 1) {
  result = selfTest();
} else if (args[0] === "--check" && args.length === 2) {
  result = patchArchive(args[1], null, true);
} else if (args[0] === "--verify" && args.length === 2) {
  result = verifyArchive(args[1]);
} else if (args.length === 2) {
  result = patchArchive(args[0], args[1], false);
} else {
  console.error(
    "Usage: node patch-codex-asar.mjs --self-test | --check <official.asar> | --verify <patched.asar> | <input.asar> <output.asar>",
  );
  process.exit(2);
}
console.log(JSON.stringify(result, null, 2));

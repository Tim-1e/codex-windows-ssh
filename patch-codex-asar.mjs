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

const supportedMainBuilds = new Map([
  [
    "1b4fa62253cde7fde2c5e8a7f88947c1a675481ae5472f0ef6ff1645aa626712",
    {
      version: "26.803.10989.0",
      codexExecutable: "hC",
      executableResolver: "n.Vn",
      processSpawner: "n.Fn",
      shellMetadata: "IC",
      sshDestination: "NC",
      sshOptions: "jC",
      stderrSanitizer: "MC",
      timeouts: "CC",
    },
  ],
  [
    "3148e6792685e112ddeed3bafd72cc0e00f9f543ec07194e6b22da18af5d97e1",
    {
      version: "26.820.7780.0",
      codexExecutable: "SS",
      executableResolver: "n.Kn",
      processSpawner: "n.Bn",
      shellMetadata: "GS",
      sshDestination: "HS",
      sshOptions: "BS",
      stderrSanitizer: "VS",
      timeouts: "MS",
    },
  ],
]);

const supportedPatchedMainHashes = new Map([
  [
    "3dc14b5dcda41a94ef8dba2b570475c5be1d23ea288ce86cd6e170298d578b3c",
    "26.803.10989.0",
  ],
  [
    "92c962b7cfdf0bc3b80ad76e2f96a4bca8114d9b0fbd97c45ca0df20832837a6",
    "26.820.7780.0",
  ],
]);

const hash = (value) => createHash("sha256").update(value).digest("hex");
const align4 = (value) => (value + 3) & ~3;

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
  const build = supportedMainBuilds.get(inputHash);
  if (!build) {
    throw new Error(
      `Unsupported Codex Desktop main bundle SHA-256: ${inputHash}`,
    );
  }
  let patched = source.toString("utf8");
  const replaceOnce = (needle, replacement, label) => {
    const first = patched.indexOf(needle);
    if (first < 0 || patched.indexOf(needle, first + needle.length) >= 0) {
      throw new Error(`Expected exactly one ${label} patch point`);
    }
    patched = `${patched.slice(0, first)}${replacement}${patched.slice(first + needle.length)}`;
  };

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
    `let r=(0,x.spawn)(${build.executableResolver}.resolve(\`ssh\`)??\`ssh\`,[\`-T\`,...${build.sshOptions}(this.options.getConnectTimeoutSeconds?.()),\`-W\`,\`127.0.0.1:${"${t}"}\`,...${build.sshDestination}(this.options.sshConnection)],{env:i.t(process.env),stdio:[\`pipe\`,\`pipe\`,\`pipe\`],windowsHide:!0}),{stdin:a,stdout:o,stderr:s}=r;if(a==null||o==null||s==null)throw r.kill(),Error(\`ssh direct-tcpip stdio was unavailable\`);`,
    "let c=``;s.on(`data`,e=>{c=`${c}${e.toString(`utf8`)}`.slice(-4e3)});let l=new E.Duplex({read(){o.resume()},write(e,t,n){a.write(e,t,n)},final(e){a.end(),e()},destroy(e,t){r.kill(),t(e)}});Object.assign(l,{setKeepAlive:()=>l,setNoDelay:()=>l,setTimeout:()=>l});",
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
    packageVersion: build.version,
  };
}

function verifyArchive(archivePath) {
  const parsed = parseArchive(archivePath);
  try {
    const main = findMainEntry(parsed);
    const source = readExact(parsed.fd, main.size, parsed.dataOffset + main.offset);
    const mainHash = hash(source);
    const packageVersion = supportedPatchedMainHashes.get(mainHash);
    if (!packageVersion) {
      throw new Error(`Unsupported patched main bundle SHA-256: ${mainHash}`);
    }
    for (const token of [
      "CODEX_WINDOWS_CONTROLLER_V1",
      "CODEX_WINDOWS_ENDPOINT_V1",
      "windowsSshDetected",
      "ssh_direct_tcpip",
      "collectOutput:!1",
      "toString(`utf8`)",
    ]) {
      if (!source.includes(token)) {
        throw new Error(`Patched main bundle is missing: ${token}`);
      }
    }
    for (const token of [
      "CODEX_WINDOWS_SSH_HOSTS",
      "codex-app-server-ws.ps1",
      "windows_app_server_manager",
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
      packageVersion,
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
    packageVersion: result.packageVersion,
    mainEntryPath: main.path,
    inputMainSha256: result.inputHash,
    outputMainSha256: result.outputHash,
    inputAsar: resolve(inputPath),
    outputAsar: checkOnly ? null : resolve(outputPath),
  };
}

function selfTest() {
  const root = mkdtempSync(join(tmpdir(), "codex-asar-self-test-"));
  const input = join(root, "input.asar");
  const output = join(root, "output.asar");
  try {
    const first = Buffer.from("first", "utf8");
    const second = Buffer.from([0, 1, 2, 3]);
    const header = {
      files: {
        "first.txt": {
          size: first.length,
          offset: "0",
          integrity: makeIntegrity(first),
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
    const replacement = Buffer.from("first-expanded", "utf8");
    rewriteArchive(input, output, new Map([["first.txt", replacement]]));
    const parsed = parseArchive(output);
    try {
      const byPath = new Map(parsed.entries.map((item) => [item.path, item]));
      const firstEntry = byPath.get("first.txt");
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
      if (!firstValue.equals(replacement) || !secondValue.equals(second)) {
        throw new Error("ASAR self-test content mismatch");
      }
      if (firstEntry.entry.integrity.hash !== hash(replacement)) {
        throw new Error("ASAR self-test integrity mismatch");
      }
    } finally {
      closeSync(parsed.fd);
    }
    return { ok: true, selfTest: true };
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

$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Install-Codex-Windows-SSH.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Installer syntax is invalid.' }
foreach ($name in @('Set-CodexShortcutAppId', 'New-CodexLauncherShortcut', 'Test-OwnedLauncherShortcut')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codex-shortcuts-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$shell = New-Object -ComObject WScript.Shell
$target = Join-Path $fixture 'CodexLauncher.exe'
$icon = Join-Path $fixture 'Codex_Fix.ico'
$link = Join-Path $fixture 'Codex_Fix.lnk'
New-CodexLauncherShortcut -Shell $shell -Path $link -Target $target -InstallRoot $fixture -Icon $icon
New-CodexLauncherShortcut -Shell $shell -Path $link -Target $target -InstallRoot $fixture -Icon $icon
$details = $shell.CreateShortcut($link)
$namespace = New-Object -ComObject Shell.Application
$appId = $namespace.Namespace($fixture).ParseName('Codex_Fix.lnk').ExtendedProperty('System.AppUserModel.ID')
if ($details.TargetPath -ne $target -or $details.Arguments -ne '' -or $details.Description -ne 'Codex_Fix' -or $details.IconLocation -ne ($icon + ',0') -or $appId -ne 'com.openai.codex.windows-ssh') {
    throw 'Stable shortcut contents or shell identity did not survive recreation.'
}
if (-not (Test-OwnedLauncherShortcut -Shell $shell -Path $link -LauncherHost 'wscript.exe' -InstallRoot $fixture)) { throw 'Owned launcher not detected.' }
$unrelated = Join-Path $fixture 'ChatGPT.lnk'
$unrelatedLink = $shell.CreateShortcut($unrelated)
$unrelatedLink.TargetPath = Join-Path $env:SystemRoot 'notepad.exe'
$unrelatedLink.Save()
if (Test-OwnedLauncherShortcut -Shell $shell -Path $unrelated -LauncherHost 'wscript.exe' -InstallRoot $fixture) { throw 'Unrelated ChatGPT-named shortcut was considered owned.' }
[pscustomobject]@{ ok=$true; identity=$appId; recreation=$true; unrelatedPreserved=$true } | ConvertTo-Json
Remove-Item -LiteralPath $link, $unrelated -Force
[IO.Directory]::Delete($fixture)

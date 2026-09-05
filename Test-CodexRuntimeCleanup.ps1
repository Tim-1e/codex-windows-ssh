$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Remove-OldCodexRuntimes.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Cleanup script syntax is invalid.' }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-RemovableCodexRuntime' }, $false)
. ([scriptblock]::Create($definition.Extent.Text))
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codex-cleanup-test-' + [guid]::NewGuid().ToString('N'))
$old = Join-Path $fixture '1.2.3.4-r1'
$exe = Join-Path $old 'app\ChatGPT.exe'
New-Item -ItemType Directory -Path (Split-Path -Parent $exe) -Force | Out-Null
try {
    [IO.File]::WriteAllBytes($exe, [byte[]]@())
    [IO.File]::WriteAllText((Join-Path $old 'installed.json'), (@{ packageVersion='1.2.3.4'; automaticWindowsDetection=$true } | ConvertTo-Json))
    if (-not (Test-RemovableCodexRuntime $fixture $old '1.2.3.4-r2' @())) { throw 'Unused owned runtime was not recognized.' }
    if (Test-RemovableCodexRuntime $fixture $old '1.2.3.4-r1' @()) { throw 'Selected runtime must be retained.' }
    if (Test-RemovableCodexRuntime $fixture $old '1.2.3.4-r2' @(@{ ExecutablePath=$exe; CommandLine='' })) { throw 'Running runtime must be retained.' }
    if (Test-RemovableCodexRuntime $fixture $old '1.2.3.4-r2' @(@{ ExecutablePath='node.exe'; CommandLine=('node ' + $old + '\helper.js') })) { throw 'Runtime with an active helper must be retained.' }
    if (Test-RemovableCodexRuntime $fixture $fixture '1.2.3.4-r2' @()) { throw 'The root must never be removable.' }
    if (Test-RemovableCodexRuntime $old $fixture '1.2.3.4-r2' @()) { throw 'An outside path must never be removable.' }
    if (Test-RemovableCodexRuntime $fixture (Join-Path $fixture 'user-data') '1.2.3.4-r2' @()) { throw 'Non-runtime paths must never be removable.' }
    [IO.File]::WriteAllText((Join-Path $old 'installed.json'), '{}')
    if (Test-RemovableCodexRuntime $fixture $old '1.2.3.4-r2' @()) { throw 'Missing ownership metadata must be rejected.' }
    [pscustomobject]@{ ok=$true; selectedProtected=$true; activeProtected=$true; pathAndOwnershipChecked=$true } | ConvertTo-Json
} finally {
    # Exact, non-recursive fixture teardown cannot reach unrelated content.
    Remove-Item -LiteralPath $exe, (Join-Path $old 'installed.json') -Force
    [IO.Directory]::Delete((Join-Path $old 'app'))
    [IO.Directory]::Delete($old)
    [IO.Directory]::Delete($fixture)
}

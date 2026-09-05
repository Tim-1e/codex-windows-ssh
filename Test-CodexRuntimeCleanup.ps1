$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Remove-OldCodexRuntimes.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Cleanup script syntax is invalid.' }
foreach ($name in @('Test-RemovableCodexRuntime', 'Remove-UnlockedCodexRuntime')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codex-cleanup-test-' + [guid]::NewGuid().ToString('N'))
$old = Join-Path $fixture '1.2.3.4-r1'
$exe = Join-Path $old 'app\ChatGPT.exe'
$lockedFile = Join-Path $old 'app\a-locked.pak'
$freeFile = Join-Path $old 'app\z-removable.pak'
$lock = $null
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
    Remove-Item -LiteralPath $exe
    if (-not (Test-RemovableCodexRuntime $fixture $old '1.2.3.4-r2' @())) { throw 'Owned partial cleanup should be retryable.' }
    [IO.File]::WriteAllBytes($exe, [byte[]]@())
    [IO.File]::WriteAllText($lockedFile, 'locked bytes')
    [IO.File]::WriteAllText($freeFile, 'reclaim these bytes')
    $lock = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $partial = Remove-UnlockedCodexRuntime $fixture $old '1.2.3.4-r2' @()
    if ($partial.removed -or -not (Test-Path -LiteralPath $lockedFile)) { throw 'The locked file should be deferred.' }
    if (Test-Path -LiteralPath $freeFile) { throw 'A locked file prevented another file from being deleted.' }
    if (Test-Path -LiteralPath $exe) { throw 'An unlocked runtime executable was not reclaimed.' }
    if ($partial.remainingFiles -ne 2 -or $partial.remainingBytes -le 0) { throw 'Partial cleanup counts are incorrect.' }
    if (-not (Test-RemovableCodexRuntime $fixture $old '1.2.3.4-r2' @())) { throw 'Partial cleanup lost its ownership record.' }
    $lock.Dispose(); $lock = $null
    $retry = Remove-UnlockedCodexRuntime $fixture $old '1.2.3.4-r2' @()
    if (-not $retry.removed -or (Test-Path -LiteralPath $old)) { throw 'The unlocked remainder was not removed on retry.' }
    New-Item -ItemType Directory -Path (Split-Path -Parent $exe) -Force | Out-Null
    [IO.File]::WriteAllBytes($exe, [byte[]]@())
    [IO.File]::WriteAllText((Join-Path $old 'installed.json'), '{}')
    if (Test-RemovableCodexRuntime $fixture $old '1.2.3.4-r2' @()) { throw 'Missing ownership metadata must be rejected.' }
    [pscustomobject]@{ ok=$true; selectedProtected=$true; activeProtected=$true; pathAndOwnershipChecked=$true; lockedFilesDeferred=$true; unlockedFilesReclaimed=$true; partialCleanupRetry=$true } | ConvertTo-Json
} finally {
    if ($lock) { $lock.Dispose() }
    # Exact, non-recursive fixture teardown cannot reach unrelated content.
    foreach ($path in @($exe, $lockedFile, $freeFile, (Join-Path $old 'installed.json'))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    foreach ($path in @((Join-Path $old 'app'), $old, $fixture)) {
        if (Test-Path -LiteralPath $path) { [IO.Directory]::Delete($path) }
    }
}

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Update-Codex-Windows-SSH.ps1')
function Assert-Throws([scriptblock]$Action) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw 'Expected unsafe input to be rejected.' }
}
Assert-UpdateManifest ([pscustomobject]@{schemaVersion=1;packageIdentity='OpenAI.Codex';storeProductId='9PLM9XGG6VKS';buildVersion='99.1.2.3'})
Assert-Throws { Assert-UpdateManifest ([pscustomobject]@{schemaVersion=1;packageIdentity='Other';storeProductId='9PLM9XGG6VKS';buildVersion='99.1.2.3'}) }
Assert-Throws { Assert-UpdateManifest ([pscustomobject]@{schemaVersion=99;packageIdentity='OpenAI.Codex';storeProductId='9PLM9XGG6VKS';buildVersion='99.1.2.3'}) }
Assert-OfficialUrl 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' | Out-Null
foreach ($url in @('http://persistent.oaistatic.com/codex-app-prod/a', 'https://evil.example/codex-app-prod/a',
    'https://persistent.oaistatic.com.evil.example/codex-app-prod/a', 'https://user@persistent.oaistatic.com/codex-app-prod/a',
    'https://persistent.oaistatic.com:8443/codex-app-prod/a', 'https://persistent.oaistatic.com/other/a')) {
    Assert-Throws { Assert-OfficialUrl $url }
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codex-update-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $installRoot = $fixture
    $updateEventsPath = Join-Path $fixture 'events.log'
    # Invoke the actual installer callback from a different script scope.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Install-Codex-Windows-SSH.ps1'), [ref]$tokens, [ref]$errors)
    $progressFunction = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-InstallProgress' }, $false)
    & ([scriptblock]::Create($progressFunction.Extent.Text + '; $ShowProgress=$false; $ProgressCallback={param($percent,$message) Write-UpdateEvent building $message $percent}; Write-InstallProgress 45 "scope regression"'))
    $event = Get-Content -LiteralPath $updateEventsPath -Raw | ConvertFrom-Json
    if ($event.percent -ne 45 -or $event.message -ne 'scope regression') { throw 'Installer progress callback lost its parent context.' }
    $updateEventsPath = $fixture # A directory cannot be appended as a log file.
    Write-UpdateEvent cleanup 'Logging failure must not stop cleanup.'
    $updateEventsPath = $null
    [IO.File]::WriteAllText((Join-Path $fixture 'current.version'), '..\unrelated')
    Assert-Throws { Get-SelectedRuntime }
    Assert-Throws { Remove-UpdateWorkspace $fixture }
    $owned = Join-Path $fixture ('.update-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $owned | Out-Null
    [IO.File]::WriteAllText((Join-Path $owned 'download.msix'), 'not a signed package')
    Assert-Throws { Expand-VerifiedPackage (Join-Path $owned 'download.msix') (Join-Path $owned 'extract') @{} }
    if (Test-Path -LiteralPath (Join-Path $owned 'extract')) { throw 'An untrusted archive was extracted.' }
    if ((Get-Content -LiteralPath (Join-Path $fixture 'current.version') -Raw) -ne '..\unrelated') { throw 'Failure changed the active pointer.' }
    Remove-UpdateWorkspace $owned
    if (Test-Path -LiteralPath $owned) { throw 'Owned temporary download was not cleaned.' }
} finally {
    if ([IO.Path]::GetDirectoryName($fixture) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or
        [IO.Path]::GetFileName($fixture) -notmatch '^codex-update-test-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
Write-Host 'Updater trust boundaries, signature rejection, pointer preservation and temporary cleanup passed.'

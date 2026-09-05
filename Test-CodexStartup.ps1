[CmdletBinding()]
param([Parameter(Mandatory)][string]$RuntimeRoot, [int]$TimeoutSeconds = 45)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runtime = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot 'ChatGPT.exe'))
$versionRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($RuntimeRoot))
$profile = Join-Path $versionRoot ('.startup-' + [guid]::NewGuid().ToString('N'))
$marker = Join-Path $profile 'ready.json'
New-Item -ItemType Directory -Path $profile | Out-Null
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName=$runtime; $start.WorkingDirectory=$profile
$start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.WindowStyle='Hidden'
$start.ArgumentList.Add('--user-data-dir=' + (Join-Path $profile 'profile'))
$start.Environment['CODEX_ELECTRON_USER_DATA_PATH'] = Join-Path $profile 'profile'
$start.Environment['CODEX_HOME'] = Join-Path $profile 'codex-home'
$start.Environment['CODEX_WINDOWS_SSH_STARTUP_PROBE'] = $marker
$start.Environment['CODEX_SPARKLE_ENABLED'] = 'false'
$process = $null
$owned = @{}
function Save-ProbeProcessTree {
    $snapshot = @(Get-CimInstance Win32_Process)
    $rootProcess = $snapshot | Where-Object { $_.ProcessId -eq $process.Id -and $_.ExecutablePath -eq $runtime -and $_.CommandLine.Contains($profile) }
    if ($rootProcess) { $owned[[int]$rootProcess.ProcessId] = $rootProcess }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($item in $snapshot) {
            if (-not $owned.ContainsKey([int]$item.ProcessId) -and $owned.ContainsKey([int]$item.ParentProcessId) -and
                $item.CreationDate -ge $owned[[int]$item.ParentProcessId].CreationDate) {
                $owned[[int]$item.ProcessId] = $item; $changed = $true
            }
        }
    }
}
try {
    $process = [Diagnostics.Process]::Start($start)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Save-ProbeProcessTree
        $process.Refresh()
        if ($process.HasExited) { throw "Desktop exited during startup validation ($($process.ExitCode))." }
        if (Test-Path -LiteralPath $marker) {
            $ready = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
            if ($ready.status -ne 'ready' -or $ready.pid -ne $process.Id -or -not $ready.pageLoaded) { throw 'Desktop startup probe returned an invalid result.' }
            Start-Sleep -Milliseconds 1800
            $process.Refresh()
            if ($process.HasExited) { throw 'Desktop crashed after its first page loaded.' }
            return [pscustomobject]@{ status='passed'; pageLoaded=$true; isolatedProfile=$true; processId=$process.Id }
        }
        Start-Sleep -Milliseconds 200
    }
    throw 'Desktop did not load its initial page within the startup timeout.'
} finally {
    if ($process) { Save-ProbeProcessTree }
    if ($process -and -not $process.HasExited) {
        # Kill only the exact process that this probe created and its descendants.
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)"
        if (-not $current -or $current.ExecutablePath -ne $runtime -or -not $current.CommandLine.Contains($profile)) {
            throw 'Startup process ownership could not be verified; no process was killed.'
        }
        $process.Kill($true)
        [void]$process.WaitForExit(10000)
    }
    foreach ($item in $owned.Values) {
        $remaining = Get-CimInstance Win32_Process -Filter "ProcessId=$($item.ProcessId)"
        if ($remaining -and $remaining.CreationDate -eq $item.CreationDate) {
            Stop-Process -Id $item.ProcessId -Force -ErrorAction Stop
        }
    }
    if ($process) { $process.Dispose() }
    $full = [IO.Path]::GetFullPath($profile)
    if ([IO.Path]::GetDirectoryName($full) -ne $versionRoot -or [IO.Path]::GetFileName($full) -notmatch '^\.startup-[a-f0-9]{32}$') { throw 'Unsafe startup profile cleanup path.' }
    $items = @(Get-Item -LiteralPath $full) + @(Get-ChildItem -LiteralPath $full -Recurse -Force)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Refusing to remove startup profile with reparse points.' }
    Remove-Item -LiteralPath $full -Recurse -Force
}

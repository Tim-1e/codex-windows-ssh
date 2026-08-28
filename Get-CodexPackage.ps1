Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$package = Get-AppxPackage -Name 'OpenAI.Codex' |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $package) {
    throw 'OpenAI Codex is not installed for the current Windows user.'
}

[pscustomobject]@{
    version = $package.Version.ToString()
    installLocation = $package.InstallLocation
    packageFullName = $package.PackageFullName
} | ConvertTo-Json -Compress

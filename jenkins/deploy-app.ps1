<#
.SYNOPSIS
    Mirrors a published build to a deploy target with robocopy.

.DESCRIPTION
    Used by the Jenkins pipeline (see ../Jenkinsfile) to deploy one application.
    Behaviour matches the GitHub Actions deploy steps in
    .github/workflows/deploy-applications.yml:

      * Optional `net use` authentication when the target is a remote UNC share.
      * robocopy /MIR, so the target becomes an exact mirror of the build,
        EXCEPT for the files/folders listed in -ExcludeFiles / -ExcludeDirs,
        which are neither overwritten nor purged (appsettings.json, uploads, ...).
      * For a Windows Service target, the service is stopped before the copy and
        started again afterwards, so locked binaries can be replaced.

    robocopy exit codes below 8 mean success (files copied / nothing to do);
    8 and above are real failures.
#>
[CmdletBinding()]
param(
    # Folder holding the `dotnet publish` output.
    [Parameter(Mandatory = $true)] [string] $Source,

    # Deploy target: a local path (D:\...) or a UNC share (\server\share\...).
    [Parameter(Mandatory = $true)] [string] $Destination,

    # Human readable name, used in log lines only.
    [string] $AppName = 'application',

    # Files preserved on the target. Separated by new lines, commas or
    # semicolons; robocopy wildcards allowed.
    [string] $ExcludeFiles = '',

    # Folders preserved on the target (relative to $Destination).
    [string] $ExcludeDirs = '',

    # Windows Service to stop before the copy and start after it. Empty = none.
    [string] $ServiceName = '',

    # Credentials for a remote UNC share. Leave empty for local paths.
    [string] $DeployUser = '',
    [string] $DeployPassword = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Destination)) {
    throw "No deploy path configured for $AppName."
}
if (-not (Test-Path -LiteralPath $Source)) {
    throw "Build output not found at '$Source'."
}

$source = (Resolve-Path -LiteralPath $Source).Path
$dest   = $Destination.TrimEnd('\')

function Split-List([string] $value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return @() }
    return $value -split '[\r\n,;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

# Authenticate to the share root (\server\share) when deploying remotely.
$mappedRoot = $null
if ($dest -like '\*' -and -not [string]::IsNullOrWhiteSpace($DeployUser)) {
    $parts = $dest.TrimStart('\').Split('\')
    $mappedRoot = "\$($parts[0])\$($parts[1])"
    Write-Host "Connecting to $mappedRoot as $DeployUser ..."
    net use $mappedRoot /user:$DeployUser $DeployPassword | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not authenticate to $mappedRoot (net use exit $LASTEXITCODE)." }
}

$stoppedService = $null
try {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    # A running service keeps its binaries locked - stop it before copying.
    if (-not [string]::IsNullOrWhiteSpace($ServiceName)) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Warning "Service '$ServiceName' not found on this machine - copying without stopping it."
        }
        else {
            $stoppedService = $svc
            if ($svc.Status -ne 'Stopped') {
                Write-Host "Stopping service $ServiceName ..."
                Stop-Service -Name $ServiceName -Force
                (Get-Service -Name $ServiceName).WaitForStatus('Stopped', '00:01:00')
            }
        }
    }

    $excludeFiles = Split-List $ExcludeFiles
    # robocopy matches /XD against full paths, so anchor them at the target.
    $excludeDirs  = Split-List $ExcludeDirs | ForEach-Object { Join-Path $dest $_ }

    $roboArgs = @('/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:3', '/W:5')
    if ($excludeFiles) { $roboArgs += '/XF'; $roboArgs += $excludeFiles }
    if ($excludeDirs)  { $roboArgs += '/XD'; $roboArgs += $excludeDirs }

    Write-Host "Mirroring $source -> $dest"
    if ($excludeFiles) { Write-Host "  preserving files: $($excludeFiles -join ', ')" }
    if ($excludeDirs)  { Write-Host "  preserving dirs : $($excludeDirs  -join ', ')" }

    robocopy $source $dest @roboArgs
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $dest (exit $LASTEXITCODE)." }

    if ($stoppedService) {
        Write-Host "Starting service $ServiceName ..."
        Start-Service -Name $ServiceName
        (Get-Service -Name $ServiceName).WaitForStatus('Running', '00:01:00')
    }

    Write-Host "Deployed $AppName to $dest"
}
finally {
    if ($mappedRoot) { net use $mappedRoot /delete /y | Out-Null }
}

# robocopy leaves a non-zero code behind even on success; the throw above is the
# real failure signal, so end the script cleanly.
exit 0

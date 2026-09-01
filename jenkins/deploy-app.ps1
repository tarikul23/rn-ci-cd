<#
.SYNOPSIS
    Mirrors a published application folder onto a deploy target.

.DESCRIPTION
    The deploy half of the Jenkins pipeline (see Jenkinsfile -> deployApp).
    Behaviour is deliberately identical to the "Deploy *" steps in
    .github/workflows/deploy-applications.yml so a Jenkins deploy and an Actions
    deploy leave the same bytes on disk:

      * robocopy /MIR  - the target becomes an exact copy of the publish output,
                         so files dropped from the build are removed from the
                         server as well.
      * /XF, /XD       - except the excluded files and folders, which are left
                         untouched. This is what preserves the server's own
                         appsettings.json and its uploads/ folder through a /MIR.
      * -ServiceName   - stopped before the copy and started after, because a
                         running service holds its own .dll files open.
      * -DeployUser    - only used for a UNC target: authenticates the share,
                         and the connection is always dropped again in finally.

    robocopy's exit codes are a bit field, not a status: 0-7 mean success (bit
    0 = files copied, bit 1 = extra files removed, bit 2 = mismatched...), and
    only 8 and above are real failures. The script ends with `exit 0` so the
    informational codes do not fail the Jenkins stage.

.EXAMPLE
    .\jenkins\deploy-app.ps1 -Source 'publish/web' -Destination 'D:\DevOps\dev\web' `
        -AppName 'Dashboard Web' -ExcludeFiles 'appsettings.json,appsettings.*.json' `
        -ExcludeDirs 'uploads' -ServiceName ''
#>
[CmdletBinding()]
param(
    # Publish output to copy from, relative to the Jenkins workspace or absolute.
    [string]$Source,
    # Folder on the target server. Local path or UNC share.
    [string]$Destination,
    # Display name, used only in the log lines.
    [string]$AppName,
    # Comma/semicolon/newline separated. Preserved on the target, never deleted.
    [string]$ExcludeFiles = '',
    # Same, for folders. Resolved against $Destination before robocopy sees them.
    [string]$ExcludeDirs = '',
    # Windows Service to stop around the copy. Empty for the web applications.
    [string]$ServiceName = '',
    # Credentials for a UNC $Destination. Passed from Jenkins as $env: values so
    # the password never appears in the command line Jenkins echoes to the log.
    [string]$DeployUser = '',
    [string]$DeployPassword = ''
)

$ErrorActionPreference = 'Stop'

# Validated here rather than with [Parameter(Mandatory)]: a mandatory parameter
# that arrives empty makes PowerShell prompt, and a prompt under -NonInteractive
# hangs the agent until the stage times out.
if ([string]::IsNullOrWhiteSpace($Source))      { throw 'deploy-app.ps1: -Source is required.' }
if ([string]::IsNullOrWhiteSpace($Destination)) { throw 'deploy-app.ps1: -Destination is required.' }
if ([string]::IsNullOrWhiteSpace($AppName))     { $AppName = 'application' }

if (-not (Test-Path -LiteralPath $Source)) {
    throw "deploy-app.ps1: source '$Source' does not exist. The publish stage should have created it and stashed it for this agent."
}

$sourcePath = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')
$destPath   = $Destination.TrimEnd('\')

# Split a Jenkins setting into a list: commas, semicolons and newlines all work,
# so the value reads the same whether it came from a properties file or from a
# multi-line Jenkins global property.
function Split-Setting([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return @() }
    return @($value -split '[\r\n,;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

Write-Host "Deploying $AppName"
Write-Host "  from : $sourcePath"
Write-Host "  to   : $destPath"

# A UNC target needs the share authenticated first. Only the \server\share root
# is mapped; the deeper path is left to robocopy.
$mappedRoot = $null
if ($destPath -like '\*' -and $DeployUser) {
    $parts = $destPath.TrimStart('\').Split('\')
    $mappedRoot = "\$($parts[0])\$($parts[1])"
    Write-Host "  auth : $mappedRoot as $DeployUser"
    net use $mappedRoot /user:$DeployUser $DeployPassword | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not connect to $mappedRoot as $DeployUser (net use exit $LASTEXITCODE)." }
}

try {
    New-Item -ItemType Directory -Force -Path $destPath | Out-Null

    # Stop the service before the copy: a running service keeps its binaries
    # locked and robocopy would fail on every .dll it tries to replace.
    $service = $null
    if ($ServiceName) {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Host "  note : service '$ServiceName' not found on $env:COMPUTERNAME - copying files only."
        }
        elseif ($service.Status -ne 'Stopped') {
            Write-Host "  stop : $ServiceName"
            Stop-Service -Name $ServiceName -Force
            (Get-Service -Name $ServiceName).WaitForStatus('Stopped', '00:01:00')
        }
    }

    $excludeFileList = Split-Setting $ExcludeFiles
    # robocopy matches /XD against full paths, so anchor each one to the target.
    $excludeDirList  = Split-Setting $ExcludeDirs | ForEach-Object { Join-Path $destPath $_ }

    $roboArgs = @('/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:3', '/W:5')
    if ($excludeFileList) {
        Write-Host "  keep : $($excludeFileList -join ', ')"
        $roboArgs += '/XF'; $roboArgs += $excludeFileList
    }
    if ($excludeDirList) {
        Write-Host "  keep : $($excludeDirList -join ', ')"
        $roboArgs += '/XD'; $roboArgs += $excludeDirList
    }

    robocopy $sourcePath $destPath @roboArgs
    $roboExit = $LASTEXITCODE
    if ($roboExit -ge 8) { throw "robocopy failed for '$destPath' (exit $roboExit)." }

    if ($service) {
        Write-Host "  start: $ServiceName"
        Start-Service -Name $ServiceName
    }

    Write-Host "Deployed $AppName to $destPath (robocopy $roboExit)"
}
finally {
    if ($mappedRoot) { net use $mappedRoot /delete /y | Out-Null }
}

# robocopy's 1-7 are successes; do not let them fail the stage.
exit 0

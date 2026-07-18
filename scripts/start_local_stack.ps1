#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Build,
    [ValidateRange(30, 900)]
    [int]$ReadyTimeoutSeconds = 300,
    [ValidateRange(0, 65535)]
    [int]$AppPort = 0,
    [ValidateRange(0, 65535)]
    [int]$WebPort = 0,
    [ValidateRange(0, 65535)]
    [int]$LiveKitPort = 0,
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$transcriptStarted = $false
if ($LogPath) {
    $logDirectory = Split-Path -Parent $LogPath
    if ($logDirectory) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }
    Start-Transcript -Path $LogPath -Append | Out-Null
    $transcriptStarted = $true
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot

function Resolve-LocalPort {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [int]$ExplicitValue,
        [Parameter(Mandatory)]
        [int]$DefaultValue
    )

    if ($ExplicitValue -gt 0) {
        return $ExplicitValue
    }

    $environmentValue = [Environment]::GetEnvironmentVariable($Name)
    $parsedValue = 0
    if ($environmentValue -and [int]::TryParse($environmentValue, [ref]$parsedValue)) {
        return $parsedValue
    }

    $envFile = Join-Path $repositoryRoot ".env"
    if (Test-Path -LiteralPath $envFile -PathType Leaf) {
        $match = Select-String -LiteralPath $envFile -Pattern "^\s*$Name\s*=\s*(\d+)\s*$" |
            Select-Object -Last 1
        if ($match) {
            return [int]$match.Matches[0].Groups[1].Value
        }
    }

    return $DefaultValue
}

$resolvedAppPort = Resolve-LocalPort -Name "APP_PORT" -ExplicitValue $AppPort -DefaultValue 4000
$resolvedWebPort = Resolve-LocalPort -Name "WEB_PORT" -ExplicitValue $WebPort -DefaultValue 5173
$resolvedLiveKitPort = Resolve-LocalPort -Name "LIVEKIT_SIGNAL_PORT" -ExplicitValue $LiveKitPort -DefaultValue 7880
$readyUri = "http://127.0.0.1:$resolvedAppPort/health/ready"
$statusUri = "http://127.0.0.1:$resolvedAppPort/api/v1/status"
$webUri = "http://127.0.0.1:$resolvedWebPort/app/"
$liveKitUri = "http://127.0.0.1:$resolvedLiveKitPort/"

try {
    $machineState = (& podman machine inspect --format "{{.State}}" 2>$null | Select-Object -First 1)
    if ($machineState -ne "running") {
        Write-Host "Starting the Podman machine..."
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & podman machine start
        $machineStartExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorActionPreference
        if ($machineStartExitCode -ne 0) {
            Write-Warning "Podman machine start returned $machineStartExitCode; another startup task may be starting it. Waiting for readiness."
        }
    }

    $podmanDeadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        & podman info --format "{{.Host.Arch}}" *> $null
        if ($LASTEXITCODE -eq 0) {
            break
        }
        if ([DateTime]::UtcNow -ge $podmanDeadline) {
            throw "Podman did not become ready within 90 seconds"
        }
        Start-Sleep -Seconds 2
    } while ($true)

    Push-Location $repositoryRoot
    try {
        $composeArguments = @("compose", "up", "-d")
        if ($Build) {
            $composeArguments += "--build"
        } else {
            $composeArguments += "--no-build"
        }
        & podman @composeArguments
        if ($LASTEXITCODE -ne 0) {
            throw "podman compose up failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }

    $readyDeadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
    do {
        try {
            $readyResponse = Invoke-WebRequest -UseBasicParsing -Uri $readyUri -TimeoutSec 10
            $statusResponse = Invoke-RestMethod -Uri $statusUri -TimeoutSec 10
            $webResponse = Invoke-WebRequest -UseBasicParsing -Uri $webUri -TimeoutSec 10
            $liveKitResponse = Invoke-WebRequest -UseBasicParsing -Uri $liveKitUri -TimeoutSec 10
            if (
                $readyResponse.StatusCode -eq 200 -and
                $webResponse.StatusCode -eq 200 -and
                $liveKitResponse.StatusCode -eq 200 -and
                $statusResponse.capabilities.audio_calls -eq $true
            ) {
                Write-Host "K-Comms is ready: $readyUri"
                Write-Host "K-Comms web client is reachable: $webUri"
                Write-Host "K-Comms audio/video media plane is reachable: $liveKitUri"
                exit 0
            }
        }
        catch {
            Write-Verbose "Waiting for K-Comms readiness: $($_.Exception.Message)"
        }

        if ([DateTime]::UtcNow -ge $readyDeadline) {
            throw "K-Comms did not become ready within $ReadyTimeoutSeconds seconds"
        }
        Start-Sleep -Seconds 3
    } while ($true)
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}

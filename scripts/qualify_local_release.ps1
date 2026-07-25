[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:BaseUri = "http://127.0.0.1:4188"
$script:ExpectedContentSecurityPolicy =
    "default-src 'self'; base-uri 'self'; frame-ancestors 'none'; " +
    "form-action 'self'; object-src 'none'; script-src 'self'; " +
    "style-src 'self'; img-src 'self' data: blob:; font-src 'self'; " +
    "connect-src 'self' http://127.0.0.1:4188 ws://127.0.0.1:4188 " +
    "ws://127.0.0.1:7980 http://127.0.0.1:5900"

function Assert-Condition {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Context is missing required property '$Name'"
    }
    $property.Value
}

function Assert-PropertyValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][string]$Context
    )

    $observed = Get-RequiredProperty -Object $Object -Name $Name -Context $Context
    if ($observed -ne $Expected) {
        throw (
            "$Context property '$Name' must be '$Expected'; " +
            "observed '$observed'"
        )
    }
}

function Assert-LivenessPayload {
    param([Parameter(Mandatory)]$Payload)

    Assert-PropertyValue `
        -Object $Payload `
        -Name "status" `
        -Expected "ok" `
        -Context "/health/live"
}

function Assert-ReadinessPayload {
    param([Parameter(Mandatory)]$Payload)

    Assert-PropertyValue `
        -Object $Payload `
        -Name "status" `
        -Expected "ready" `
        -Context "/health/ready"
    $checks = Get-RequiredProperty `
        -Object $Payload `
        -Name "checks" `
        -Context "/health/ready"
    foreach ($checkName in @("database", "runtime")) {
        $check = Get-RequiredProperty `
            -Object $checks `
            -Name $checkName `
            -Context "/health/ready checks"
        Assert-PropertyValue `
            -Object $check `
            -Name "status" `
            -Expected "ok" `
            -Context "/health/ready check '$checkName'"
    }

    $objectStorage = Get-RequiredProperty `
        -Object $checks `
        -Name "object_storage" `
        -Context "/health/ready checks"
    Assert-PropertyValue `
        -Object $objectStorage `
        -Name "status" `
        -Expected "configured" `
        -Context "/health/ready check 'object_storage'"
}

function Assert-StatusPayload {
    param([Parameter(Mandatory)]$Payload)

    Assert-PropertyValue `
        -Object $Payload `
        -Name "service" `
        -Expected "k-comms" `
        -Context "/api/v1/status"
    Assert-PropertyValue `
        -Object $Payload `
        -Name "status" `
        -Expected "operational" `
        -Context "/api/v1/status"

    $capabilities = Get-RequiredProperty `
        -Object $Payload `
        -Name "capabilities" `
        -Context "/api/v1/status"
    foreach ($capability in @(
        "administration",
        "audio_calls",
        "video_calls",
        "guest_links",
        "realtime"
    )) {
        Assert-PropertyValue `
            -Object $capabilities `
            -Name $capability `
            -Expected $true `
            -Context "/api/v1/status capabilities"
    }
}

function Assert-AppContract {
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$ContentType,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$ContentSecurityPolicy
    )

    Assert-Condition `
        -Condition ($StatusCode -eq 200) `
        -Message "/app/ must return HTTP 200; observed $StatusCode"
    Assert-Condition `
        -Condition ($ContentType -match "^text/html(?:;|$)") `
        -Message "/app/ must return text/html; observed '$ContentType'"
    Assert-Condition `
        -Condition ($Content -match '<div\s+id=["'']root["'']') `
        -Message "/app/ does not contain the packaged client root"
    Assert-Condition `
        -Condition ($Content -match '<script[^>]+src=["'']/app/assets/') `
        -Message "/app/ does not reference a built /app/assets/ JavaScript bundle"
    Assert-Condition `
        -Condition (
            $Content -notmatch 'src=["'']/src/' -and
            $Content -notmatch '/@vite/client'
        ) `
        -Message "/app/ references a source/Vite development asset"
    Assert-Condition `
        -Condition ($ContentSecurityPolicy -ceq $script:ExpectedContentSecurityPolicy) `
        -Message (
            "/app/ Content-Security-Policy does not match the sealed release policy. " +
            "Observed: '$ContentSecurityPolicy'"
        )
    Assert-Condition `
        -Condition (
            $ContentSecurityPolicy -notmatch "'unsafe-inline'" -and
            $ContentSecurityPolicy -notmatch "'unsafe-eval'" -and
            $ContentSecurityPolicy -notmatch "(^|[\s;])\*([\s;]|$)"
        ) `
        -Message "/app/ Content-Security-Policy contains an unsafe source expression"
}

function Invoke-JsonEndpointCheck {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$Validator
    )

    $uri = "$script:BaseUri$Path"
    try {
        $response = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri $uri `
            -Method Get `
            -TimeoutSec 15
    }
    catch {
        throw "GET $uri failed: $($_.Exception.Message)"
    }

    Assert-Condition `
        -Condition ($response.StatusCode -eq 200) `
        -Message "GET $uri must return HTTP 200; observed $($response.StatusCode)"
    try {
        $payload = $response.Content | ConvertFrom-Json
    }
    catch {
        throw "GET $uri did not return valid JSON: $($_.Exception.Message)"
    }
    & $Validator $payload
    Write-Host "PASS $Path"
}

function Assert-SealedReleaseIsRunning {
    $manager = Join-Path $PSScriptRoot "manage_local_release.ps1"
    Assert-Condition `
        -Condition (Test-Path -LiteralPath $manager -PathType Leaf) `
        -Message "Local release manager is missing: $manager"

    # The release manager reports its receipt through Write-Host. PowerShell
    # 5.1 sends that to the information stream, so merge every stream before
    # evaluating the machine-relevant status lines.
    $statusOutput = (& $manager -Action Status *>&1 | Out-String)
    Assert-Condition `
        -Condition ($statusOutput -match "Application:\s+http://127\.0\.0\.1:4188/app/") `
        -Message "The recorded immutable release does not own http://127.0.0.1:4188/app/"
    Assert-Condition `
        -Condition ($statusOutput -match "Observed application state:\s+running") `
        -Message "The recorded immutable release application is not running"
    Assert-Condition `
        -Condition ($statusOutput -match "Observed application health:\s+healthy") `
        -Message "The recorded immutable release application is not healthy"
    Assert-Condition `
        -Condition ($statusOutput -match "Observed image matches receipt:\s+True") `
        -Message "The running application image does not match the sealed release receipt"
    Write-Host "PASS sealed release receipt and running image"
}

function Assert-PackagedApp {
    $uri = "$script:BaseUri/app/"
    try {
        $response = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri $uri `
            -Method Get `
            -TimeoutSec 15
    }
    catch {
        throw "GET $uri failed: $($_.Exception.Message)"
    }

    $contentType = @($response.Headers["Content-Type"]) -join ", "
    $contentSecurityPolicy =
        @($response.Headers["Content-Security-Policy"]) -join ", "
    Assert-AppContract `
        -StatusCode $response.StatusCode `
        -ContentType $contentType `
        -Content $response.Content `
        -ContentSecurityPolicy $contentSecurityPolicy
    Write-Host "PASS /app/ packaged assets and strict Content-Security-Policy"
}

function Invoke-GuestSpec {
    param([Parameter(Mandatory)][string]$Playwright)

    [Environment]::SetEnvironmentVariable(
        "K_COMMS_LIVE_GUEST_E2E",
        "true",
        "Process"
    )
    [Environment]::SetEnvironmentVariable(
        "K_COMMS_LIVE_GUEST_BASE_URL",
        $script:BaseUri,
        "Process"
    )

    Write-Host "Running sealed guest communication qualification..."
    & $Playwright `
        "test" `
        "e2e/live-guest-communication.spec.ts" `
        "--project=chromium" `
        "--workers=1"
    if ($LASTEXITCODE -ne 0) {
        throw "Sealed guest communication qualification failed with exit code $LASTEXITCODE"
    }
    Write-Host "PASS sealed guest communication qualification"
}

function Invoke-MediaSpec {
    param(
        [Parameter(Mandatory)][ValidateSet("audio", "video")][string]$Kind,
        [Parameter(Mandatory)][string]$Playwright
    )

    if ($Kind -eq "audio") {
        [Environment]::SetEnvironmentVariable(
            "K_COMMS_LIVE_AUDIO_E2E",
            "true",
            "Process"
        )
        [Environment]::SetEnvironmentVariable(
            "K_COMMS_LIVE_VIDEO_E2E",
            "false",
            "Process"
        )
        [Environment]::SetEnvironmentVariable(
            "K_COMMS_LIVE_AUDIO_BASE_URL",
            $script:BaseUri,
            "Process"
        )
        $spec = "e2e/live-audio.spec.ts"
    }
    else {
        [Environment]::SetEnvironmentVariable(
            "K_COMMS_LIVE_AUDIO_E2E",
            "false",
            "Process"
        )
        [Environment]::SetEnvironmentVariable(
            "K_COMMS_LIVE_VIDEO_E2E",
            "true",
            "Process"
        )
        [Environment]::SetEnvironmentVariable(
            "K_COMMS_LIVE_VIDEO_BASE_URL",
            $script:BaseUri,
            "Process"
        )
        $spec = "e2e/live-video.spec.ts"
    }

    Write-Host "Running real $Kind media qualification..."
    & $Playwright `
        "test" `
        $spec `
        "--project=chromium" `
        "--workers=1"
    if ($LASTEXITCODE -ne 0) {
        throw "Real $Kind media qualification failed with exit code $LASTEXITCODE"
    }
    Write-Host "PASS real $Kind media qualification"
}

function Invoke-PackagedReleaseQualification {
    Assert-SealedReleaseIsRunning
    Invoke-JsonEndpointCheck -Path "/health/live" -Validator ${function:Assert-LivenessPayload}
    Invoke-JsonEndpointCheck -Path "/health/ready" -Validator ${function:Assert-ReadinessPayload}
    Invoke-JsonEndpointCheck -Path "/api/v1/status" -Validator ${function:Assert-StatusPayload}
    Assert-PackagedApp

    $webRoot = Join-Path $script:RepositoryRoot "clients\web"
    $playwright = Join-Path $webRoot "node_modules\.bin\playwright.cmd"
    Assert-Condition `
        -Condition (Test-Path -LiteralPath $playwright -PathType Leaf) `
        -Message (
            "Playwright is not installed at $playwright. " +
            "Run npm ci in clients/web before qualification."
        )

    $environmentNames = @(
        "K_COMMS_EXTERNAL_E2E_SERVER",
        "K_COMMS_E2E_BASE_URL",
        "K_COMMS_LIVE_GUEST_E2E",
        "K_COMMS_LIVE_GUEST_BASE_URL",
        "K_COMMS_LIVE_AUDIO_E2E",
        "K_COMMS_LIVE_AUDIO_BASE_URL",
        "K_COMMS_LIVE_VIDEO_E2E",
        "K_COMMS_LIVE_VIDEO_BASE_URL"
    )
    $previousEnvironment = @{}
    foreach ($name in $environmentNames) {
        $previousEnvironment[$name] =
            [Environment]::GetEnvironmentVariable($name, "Process")
    }

    try {
        [Environment]::SetEnvironmentVariable(
            "K_COMMS_EXTERNAL_E2E_SERVER",
            "true",
            "Process"
        )
        [Environment]::SetEnvironmentVariable(
            "K_COMMS_E2E_BASE_URL",
            $script:BaseUri,
            "Process"
        )
        Push-Location $webRoot
        try {
            Invoke-GuestSpec -Playwright $playwright
            Invoke-MediaSpec -Kind "audio" -Playwright $playwright
            Invoke-MediaSpec -Kind "video" -Playwright $playwright
        }
        finally {
            Pop-Location
        }
    }
    finally {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $previousEnvironment[$name],
                "Process"
            )
        }
    }

    Write-Host (
        "Packaged local release qualification passed at " +
        "$script:BaseUri/app/."
    )
}

function Invoke-SelfTest {
    Assert-LivenessPayload ([PSCustomObject]@{status = "ok"})
    Assert-ReadinessPayload ([PSCustomObject]@{
        status = "ready"
        checks = [PSCustomObject]@{
            database = [PSCustomObject]@{status = "ok"}
            runtime = [PSCustomObject]@{status = "ok"}
            object_storage = [PSCustomObject]@{status = "configured"}
        }
    })
    Assert-StatusPayload ([PSCustomObject]@{
        service = "k-comms"
        status = "operational"
        capabilities = [PSCustomObject]@{
            administration = $true
            audio_calls = $true
            video_calls = $true
            guest_links = $true
            realtime = $true
        }
    })
    Assert-AppContract `
        -StatusCode 200 `
        -ContentType "text/html; charset=utf-8" `
        -Content (
            '<div id="root"></div>' +
            '<script type="module" src="/app/assets/index-test.js"></script>'
        ) `
        -ContentSecurityPolicy $script:ExpectedContentSecurityPolicy

    $unsafePolicyRejected = $false
    try {
        Assert-AppContract `
            -StatusCode 200 `
            -ContentType "text/html" `
            -Content (
                '<div id="root"></div>' +
                '<script type="module" src="/app/assets/index-test.js"></script>'
            ) `
            -ContentSecurityPolicy (
                $script:ExpectedContentSecurityPolicy + "; script-src 'unsafe-inline'"
            )
    }
    catch {
        $unsafePolicyRejected = $true
    }
    Assert-Condition `
        -Condition $unsafePolicyRejected `
        -Message "Self-test accepted a weakened Content-Security-Policy"
    Write-Host "Packaged local release qualifier self-test passed."
}

try {
    if ($SelfTest) {
        Invoke-SelfTest
    }
    else {
        Invoke-PackagedReleaseQualification
    }
}
catch {
    Write-Error "Packaged local release qualification failed: $($_.Exception.Message)"
    exit 1
}

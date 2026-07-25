[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$LanTextOnly,
    [ValidateNotNullOrEmpty()][string]$BaseUri = "http://127.0.0.1:4188"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot

function Resolve-SealedBaseUri {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -cne $Value.Trim()) {
        throw "BaseUri must not contain leading or trailing whitespace"
    }

    $originPattern =
        "^(?i:http)://" +
        "(?<host>(?:[0-9]{1,3}\.){3}[0-9]{1,3})" +
        "(?::(?<port>[0-9]{1,5}))?/?$"
    $originMatch = [regex]::Match($Value, $originPattern)
    if (-not $originMatch.Success) {
        throw (
            "BaseUri must be an HTTP origin containing only an IPv4 address " +
            "and optional port, with no credentials, path, query, or fragment"
        )
    }

    $octets = @(
        $originMatch.Groups["host"].Value.Split(".") |
            ForEach-Object { [int]$_ }
    )
    if (@($octets | Where-Object { $_ -lt 0 -or $_ -gt 255 }).Count -ne 0) {
        throw "BaseUri contains an invalid IPv4 address"
    }

    $canonicalHost = ($octets -join ".")
    if ($originMatch.Groups["host"].Value -cne $canonicalHost) {
        throw "BaseUri must use the canonical dotted-decimal IPv4 form"
    }

    $isLoopback = $octets[0] -eq 127
    $isPrivate =
        $octets[0] -eq 10 -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168)
    if (-not ($isLoopback -or $isPrivate)) {
        throw "BaseUri IPv4 address must be loopback or RFC1918 private space"
    }

    $port = 80
    $hasPort = $originMatch.Groups["port"].Success
    if ($hasPort) {
        $port = [int]$originMatch.Groups["port"].Value
        if ($port -lt 1 -or $port -gt 65535) {
            throw "BaseUri port must be between 1 and 65535"
        }
    }

    if ($hasPort) {
        "http://${canonicalHost}:$port"
    }
    else {
        "http://$canonicalHost"
    }
}

function New-ExpectedContentSecurityPolicy {
    param(
        [Parameter(Mandatory)][string]$AppOrigin,
        [Parameter(Mandatory)][string]$AppWebSocketOrigin,
        [Parameter(Mandatory)][string]$LiveKitOrigin,
        [Parameter(Mandatory)][string]$MinioOrigin
    )

    "default-src 'self'; base-uri 'self'; frame-ancestors 'none'; " +
        "form-action 'self'; object-src 'none'; script-src 'self'; " +
        "style-src 'self'; img-src 'self' data: blob:; font-src 'self'; " +
        "connect-src 'self' $AppOrigin $AppWebSocketOrigin " +
        "$LiveKitOrigin $MinioOrigin"
}

function Resolve-QualificationMode {
    param(
        [Parameter(Mandatory)][Uri]$Origin,
        [switch]$LanTextOnly
    )

    $hostAddress = [Net.IPAddress]::Parse($Origin.Host)
    $isLoopback = [Net.IPAddress]::IsLoopback($hostAddress)
    if ($LanTextOnly -and $isLoopback) {
        throw (
            "-LanTextOnly is valid only for a non-loopback RFC1918 BaseUri. " +
            "Loopback qualification must include the real audio and video gates."
        )
    }
    if (-not $isLoopback -and -not $LanTextOnly) {
        throw (
            "Plain HTTP RFC1918 qualification requires -LanTextOnly. Browser " +
            "audio and video media cannot be qualified or claimed on this origin."
        )
    }
    [PSCustomObject]@{
        IsLoopback = $isLoopback
        LanTextOnly = [bool]$LanTextOnly
    }
}

$script:RequestedBaseUri = Resolve-SealedBaseUri -Value $BaseUri
$script:BaseUri = $script:RequestedBaseUri
$script:BaseUriObject = [Uri]$script:BaseUri
$script:QualificationMode = Resolve-QualificationMode `
    -Origin $script:BaseUriObject `
    -LanTextOnly:$LanTextOnly
$script:ExpectedContentSecurityPolicy = ""

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

function Get-RequiredReceiptPort {
    param(
        [Parameter(Mandatory)]$Ports,
        [Parameter(Mandatory)][string]$Name
    )

    $rawValue = Get-RequiredProperty `
        -Object $Ports `
        -Name $Name `
        -Context "sealed release receipt ports"
    $port = 0
    if (
        $rawValue -is [bool] -or
        -not [int]::TryParse(
            [string]$rawValue,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$port
        ) -or
        $port -lt 1 -or
        $port -gt 65535
    ) {
        throw (
            "sealed release receipt ports property '$Name' must be an integer " +
            "between 1 and 65535; observed '$rawValue'"
        )
    }
    return $port
}

function Resolve-SealedReceiptQualificationTarget {
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$RequestedBaseUri
    )

    $ports = Get-RequiredProperty `
        -Object $Receipt `
        -Name "ports" `
        -Context "sealed release receipt"
    $appPort = Get-RequiredReceiptPort -Ports $ports -Name "app"
    $liveKitSignalPort =
        Get-RequiredReceiptPort -Ports $ports -Name "livekitSignal"
    $liveKitTcpPort =
        Get-RequiredReceiptPort -Ports $ports -Name "livekitTcp"
    $liveKitUdpPort =
        Get-RequiredReceiptPort -Ports $ports -Name "livekitUdp"
    $minioPort = Get-RequiredReceiptPort -Ports $ports -Name "minio"

    $schemaVersionProperty = $Receipt.PSObject.Properties["schemaVersion"]
    $schemaVersion =
        if ($null -eq $schemaVersionProperty) {
            1
        }
        else {
            [int]$schemaVersionProperty.Value
        }
    $networkProperty = $Receipt.PSObject.Properties["network"]
    if ($schemaVersion -ge 4 -and $null -eq $networkProperty) {
        throw "schema-v4+ sealed release receipt is missing required property 'network'"
    }

    $publicHost = "127.0.0.1"
    $networkPublicAppUrl = $null
    $podmanBindAddress = "127.0.0.1"
    $exposureMode = "loopback"
    if ($null -ne $networkProperty) {
        $network = $networkProperty.Value
        $bindAddress = [string](Get-RequiredProperty `
            -Object $network `
            -Name "bindAddress" `
            -Context "sealed release receipt network")
        $publicHost = [string](Get-RequiredProperty `
            -Object $network `
            -Name "publicHost" `
            -Context "sealed release receipt network")
        $networkPublicAppUrl = [string](Get-RequiredProperty `
            -Object $network `
            -Name "publicAppUrl" `
            -Context "sealed release receipt network")
        if ($bindAddress -cne $publicHost) {
            throw (
                "sealed release receipt network bindAddress must equal publicHost; " +
                "observed '$bindAddress' and '$publicHost'"
            )
        }
        if ($schemaVersion -ge 5) {
            $podmanBindAddress = [string](Get-RequiredProperty `
                -Object $network `
                -Name "podmanBindAddress" `
                -Context "sealed release receipt network")
            $exposureMode = [string](Get-RequiredProperty `
                -Object $network `
                -Name "exposureMode" `
                -Context "sealed release receipt network")
        }
    }

    $publicAddress = [Net.IPAddress]::Parse($publicHost)
    $isLoopback = [Net.IPAddress]::IsLoopback($publicAddress)
    if ($schemaVersion -lt 5 -and -not $isLoopback) {
        throw (
            "schema-v3/v4 sealed release receipts are accepted only for loopback; " +
            "private-LAN qualification requires a schema-v5 forwarder receipt"
        )
    }
    if ($schemaVersion -ge 5) {
        if ($podmanBindAddress -cne "127.0.0.1") {
            throw (
                "schema-v5 sealed release receipt network podmanBindAddress must " +
                "be exactly '127.0.0.1'; observed '$podmanBindAddress'"
            )
        }
        $expectedExposureMode =
            if ($isLoopback) { "loopback" } else { "lan-forwarder" }
        if ($exposureMode -cne $expectedExposureMode) {
            throw (
                "schema-v5 sealed release receipt network exposureMode must be " +
                "'$expectedExposureMode'; observed '$exposureMode'"
            )
        }
    }

    $forwarderRequired = $false
    $forwarderProperty = $Receipt.PSObject.Properties["forwarder"]
    if ($schemaVersion -ge 5) {
        if ($null -eq $forwarderProperty) {
            throw (
                "schema-v5 sealed release receipt is missing required property " +
                "'forwarder'"
            )
        }
        $forwarder = $forwarderProperty.Value
        $requiredValue = Get-RequiredProperty `
            -Object $forwarder `
            -Name "required" `
            -Context "sealed release receipt forwarder"
        if ($requiredValue -isnot [bool]) {
            throw (
                "sealed release receipt forwarder required property must be Boolean"
            )
        }
        $forwarderRequired = [bool]$requiredValue
        if ($forwarderRequired -ne (-not $isLoopback)) {
            throw (
                "sealed release receipt forwarder requirement does not match its " +
                "loopback or private-LAN exposure mode"
            )
        }
        if ($forwarderRequired) {
            $forwarderListeners = $null
            foreach ($name in @(
                "scriptPath",
                "scriptSha256",
                "configPath",
                "configSha256",
                "statusPath",
                "stdoutLogPath",
                "stderrLogPath",
                "readinessToken",
                "listeners"
            )) {
                $value = Get-RequiredProperty `
                    -Object $forwarder `
                    -Name $name `
                    -Context "sealed release receipt forwarder"
                if (
                    $name -ne "listeners" -and
                    [string]::IsNullOrWhiteSpace([string]$value)
                ) {
                    throw (
                        "sealed release receipt forwarder property '$name' must " +
                        "not be empty"
                    )
                }
                if ($name -eq "listeners") {
                    $forwarderListeners = @($value)
                }
            }
            foreach ($hashName in @("scriptSha256", "configSha256")) {
                $hashValue = [string](Get-RequiredProperty `
                    -Object $forwarder `
                    -Name $hashName `
                    -Context "sealed release receipt forwarder")
                if ($hashValue -notmatch "^[0-9a-fA-F]{64}$") {
                    throw (
                        "sealed release receipt forwarder property '$hashName' " +
                        "must be a SHA-256 digest"
                    )
                }
            }
            $expectedForwarderListeners = @(
                [PSCustomObject]@{
                    name = "app"
                    protocol = "tcp"
                    publicPort = $appPort
                    targetHost = "127.0.0.1"
                    targetPort = $appPort
                }
                [PSCustomObject]@{
                    name = "minio"
                    protocol = "tcp"
                    publicPort = $minioPort
                    targetHost = "127.0.0.1"
                    targetPort = $minioPort
                }
                [PSCustomObject]@{
                    name = "livekitSignal"
                    protocol = "tcp"
                    publicPort = $liveKitSignalPort
                    targetHost = "127.0.0.1"
                    targetPort = $liveKitSignalPort
                }
                [PSCustomObject]@{
                    name = "livekitTcp"
                    protocol = "tcp"
                    publicPort = $liveKitTcpPort
                    targetHost = "127.0.0.1"
                    targetPort = $liveKitTcpPort
                }
                [PSCustomObject]@{
                    name = "livekitUdp"
                    protocol = "udp"
                    publicPort = $liveKitUdpPort
                    targetHost = "127.0.0.1"
                    targetPort = $liveKitUdpPort
                }
            )
            if (
                $null -eq $forwarderListeners -or
                $forwarderListeners.Count -ne
                    $expectedForwarderListeners.Count
            ) {
                throw (
                    "sealed release receipt forwarder must contain the exact " +
                    "five-listener application/object/media contract"
                )
            }
            for (
                $index = 0;
                $index -lt $expectedForwarderListeners.Count;
                $index++
            ) {
                foreach ($propertyName in @(
                    "name",
                    "protocol",
                    "publicPort",
                    "targetHost",
                    "targetPort"
                )) {
                    $actualValue = Get-RequiredProperty `
                        -Object $forwarderListeners[$index] `
                        -Name $propertyName `
                        -Context "sealed release receipt forwarder listener $index"
                    $expectedValue =
                        $expectedForwarderListeners[$index].$propertyName
                    if ([string]$actualValue -cne [string]$expectedValue) {
                        throw (
                            "sealed release receipt forwarder listener $index " +
                            "property '$propertyName' does not match the exact " +
                            "loopback-forwarding contract"
                        )
                    }
                }
            }
        }
    }

    $appOrigin =
        Resolve-SealedBaseUri -Value "http://$publicHost`:$appPort"
    if ($RequestedBaseUri -cne $appOrigin) {
        throw (
            "Requested BaseUri '$RequestedBaseUri' does not match sealed release " +
            "origin '$appOrigin'"
        )
    }
    if (
        $null -ne $networkPublicAppUrl -and
        $networkPublicAppUrl -cne $appOrigin
    ) {
        throw (
            "sealed release receipt network publicAppUrl must be '$appOrigin'; " +
            "observed '$networkPublicAppUrl'"
        )
    }

    $topLevelPublicAppUrlProperty =
        $Receipt.PSObject.Properties["publicAppUrl"]
    if (
        $schemaVersion -ge 4 -and
        (
            $null -eq $topLevelPublicAppUrlProperty -or
            [string]::IsNullOrWhiteSpace(
                [string]$topLevelPublicAppUrlProperty.Value
            )
        )
    ) {
        throw (
            "schema-v4 sealed release receipt is missing required property " +
            "'publicAppUrl'"
        )
    }
    if (
        $null -ne $topLevelPublicAppUrlProperty -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$topLevelPublicAppUrlProperty.Value
        ) -and
        [string]$topLevelPublicAppUrlProperty.Value -cne $appOrigin
    ) {
        throw (
            "sealed release receipt publicAppUrl must be '$appOrigin'; observed " +
            "'$($topLevelPublicAppUrlProperty.Value)'"
        )
    }

    [PSCustomObject]@{
        AppOrigin = $appOrigin
        AppWebSocketOrigin = "ws://$publicHost`:$appPort"
        LiveKitOrigin = "ws://$publicHost`:$liveKitSignalPort"
        MinioOrigin = "http://$publicHost`:$minioPort"
        AppPort = $appPort
        LiveKitSignalPort = $liveKitSignalPort
        MinioPort = $minioPort
        SchemaVersion = $schemaVersion
        IsLoopback = $isLoopback
        ExposureMode = $exposureMode
        ForwarderRequired = $forwarderRequired
    }
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
        "instant_rooms",
        "realtime"
    )) {
        Assert-PropertyValue `
            -Object $capabilities `
            -Name $capability `
            -Expected $true `
            -Context "/api/v1/status capabilities"
    }
}

function Assert-InstantRoomUnavailablePayload {
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)]$Payload
    )

    Assert-Condition `
        -Condition ($StatusCode -eq 404) `
        -Message (
            "POST /api/v1/instant-rooms/preview with an unknown token must " +
            "return HTTP 404; observed $StatusCode"
        )
    $errorPayload = Get-RequiredProperty `
        -Object $Payload `
        -Name "error" `
        -Context "/api/v1/instant-rooms/preview"
    Assert-PropertyValue `
        -Object $errorPayload `
        -Name "code" `
        -Expected "instant_room_unavailable" `
        -Context "/api/v1/instant-rooms/preview error"
}

function Get-HttpFailureResponse {
    param([Parameter(Mandatory)]$ErrorRecord)

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        throw "HTTP request failed without a response: $($ErrorRecord.Exception.Message)"
    }

    # Windows PowerShell consumes and closes the response stream while building
    # ErrorDetails. Prefer that preserved body; PowerShell 7 may otherwise
    # expose only a disposed HttpContent instance here.
    $content = $null
    $errorDetailsProperty = $ErrorRecord.PSObject.Properties["ErrorDetails"]
    if (
        $null -ne $errorDetailsProperty -and
        $null -ne $errorDetailsProperty.Value -and
        -not [string]::IsNullOrWhiteSpace($errorDetailsProperty.Value.Message)
    ) {
        $content = $errorDetailsProperty.Value.Message
    }

    $contentProperty = $response.PSObject.Properties["Content"]
    if (
        [string]::IsNullOrWhiteSpace($content) -and
        $null -ne $contentProperty -and
        $null -ne $contentProperty.Value
    ) {
        $httpContent = $contentProperty.Value
        if ($httpContent -is [string]) {
            $content = $httpContent
        }
        elseif ($null -ne $httpContent.PSObject.Methods["ReadAsStringAsync"]) {
            $content = $httpContent.ReadAsStringAsync().GetAwaiter().GetResult()
        }
    }
    if ([string]::IsNullOrWhiteSpace($content)) {
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        try {
            $content = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
            $stream.Dispose()
        }
    }

    [PSCustomObject]@{
        StatusCode = [int]$response.StatusCode
        Content = $content
    }
}

function Invoke-InstantRoomEndpointCheck {
    $path = "/api/v1/instant-rooms/preview"
    $uri = "$script:BaseUri$path"
    $body = @{
        # A valid 256-bit Base64URL shape that is intentionally not issued by
        # the service. This proves the uniform no-write unavailable contract.
        token = ("A" * 43)
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri $uri `
            -Method Post `
            -Headers @{Origin = $script:BaseUri} `
            -ContentType "application/json" `
            -Body $body `
            -TimeoutSec 15
        $observed = [PSCustomObject]@{
            StatusCode = [int]$response.StatusCode
            Content = $response.Content
        }
    }
    catch {
        $observed = Get-HttpFailureResponse -ErrorRecord $_
    }

    try {
        $payload = $observed.Content | ConvertFrom-Json
    }
    catch {
        throw "POST $uri did not return valid JSON: $($_.Exception.Message)"
    }
    Assert-InstantRoomUnavailablePayload `
        -StatusCode $observed.StatusCode `
        -Payload $payload
    Write-Host "PASS $path no-write unavailable contract"
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

function Assert-ForwarderStatusContract {
    param(
        [Parameter(Mandatory)][string]$StatusOutput,
        [Parameter(Mandatory)]$Target
    )

    if ($Target.ForwarderRequired) {
        Assert-Condition `
            -Condition (
                $StatusOutput -match "(?m)^Forwarder:\s+ready\s*$"
            ) `
            -Message (
                "The private-LAN forwarder is not currently ready according to " +
                "the release manager"
            )
        Assert-Condition `
            -Condition (
                $StatusOutput -match
                    "(?m)^Observed forwarder matches receipt:\s+True\s*$"
            ) `
            -Message (
                "The current private-LAN forwarder identity or listener set does " +
                "not match the sealed release receipt"
            )
        Assert-Condition `
            -Condition (
                $StatusOutput -match
                    "(?m)^Observed forwarder configuration hash matches receipt:\s+True\s*$"
            ) `
            -Message (
                "The current private-LAN forwarder configuration hash does not " +
                "match the sealed release receipt"
            )
    }
    else {
        Assert-Condition `
            -Condition (
                $StatusOutput -match "(?m)^Forwarder:\s+not-required\s*$"
            ) `
            -Message (
                "Loopback qualification requires Status to report that no LAN " +
                "forwarder is active or required"
            )
        Assert-Condition `
            -Condition (
                $StatusOutput -notmatch "(?m)^Forwarder:\s+ready\s*$"
            ) `
            -Message "Loopback qualification must not rely on a LAN forwarder"
    }
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
    $applicationMatch = [regex]::Match(
        $statusOutput,
        "(?m)^Application:\s+(?<uri>http://[^\r\n]+/app/)\s*$"
    )
    Assert-Condition `
        -Condition $applicationMatch.Success `
        -Message "The recorded immutable release status does not expose its application URL"
    Assert-Condition `
        -Condition ($statusOutput -match "Observed application state:\s+running") `
        -Message "The recorded immutable release application is not running"
    Assert-Condition `
        -Condition ($statusOutput -match "Observed application health:\s+healthy") `
        -Message "The recorded immutable release application is not healthy"
    Assert-Condition `
        -Condition ($statusOutput -match "Observed image matches receipt:\s+True") `
        -Message "The running application image does not match the sealed release receipt"
    Assert-Condition `
        -Condition (
            $statusOutput -match
                "(?m)^Observed network topology matches receipt:\s+True\s*$"
        ) `
        -Message (
            "The current interface, address state, or Windows network profile " +
            "does not match the sealed release receipt"
        )

    $receiptMatch = [regex]::Match(
        $statusOutput,
        "(?m)^Receipt:\s+(?<path>[^\r\n]+)\s*$"
    )
    Assert-Condition `
        -Condition $receiptMatch.Success `
        -Message "The recorded immutable release status does not expose its receipt"
    $receiptPath = $receiptMatch.Groups["path"].Value.Trim()
    Assert-Condition `
        -Condition (Test-Path -LiteralPath $receiptPath -PathType Leaf) `
        -Message "The recorded immutable release receipt is missing: $receiptPath"
    try {
        $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
    }
    catch {
        throw "The recorded immutable release receipt is invalid: $($_.Exception.Message)"
    }

    $target = Resolve-SealedReceiptQualificationTarget `
        -Receipt $receipt `
        -RequestedBaseUri $script:RequestedBaseUri
    Assert-ForwarderStatusContract `
        -StatusOutput $statusOutput `
        -Target $target
    $script:BaseUri = $target.AppOrigin
    $script:BaseUriObject = [Uri]$script:BaseUri
    $script:QualificationMode = Resolve-QualificationMode `
        -Origin $script:BaseUriObject `
        -LanTextOnly:$LanTextOnly
    $script:ExpectedContentSecurityPolicy =
        New-ExpectedContentSecurityPolicy `
            -AppOrigin $target.AppOrigin `
            -AppWebSocketOrigin $target.AppWebSocketOrigin `
            -LiveKitOrigin $target.LiveKitOrigin `
            -MinioOrigin $target.MinioOrigin

    $expectedApplicationUri = "$($target.AppOrigin)/app/"
    Assert-Condition `
        -Condition (
            $applicationMatch.Groups["uri"].Value -ceq
                $expectedApplicationUri
        ) `
        -Message (
            "The recorded immutable release does not own $expectedApplicationUri; " +
            "status reports '$($applicationMatch.Groups["uri"].Value)'"
        )

    $environmentFile = Get-RequiredProperty `
        -Object $receipt `
        -Name "environmentFile" `
        -Context "sealed release receipt"
    if (Test-Path -LiteralPath $environmentFile -PathType Leaf) {
        $publicUrlLine = @(
            Get-Content -LiteralPath $environmentFile |
                Where-Object { $_ -match "^PUBLIC_APP_URL=" }
        )
        if ($publicUrlLine.Count -gt 0) {
            Assert-Condition `
                -Condition ($publicUrlLine.Count -eq 1) `
                -Message "The sealed release environment defines PUBLIC_APP_URL more than once"
            $deployedPublicUrl =
                $publicUrlLine[0].Substring("PUBLIC_APP_URL=".Length)
            Assert-Condition `
                -Condition ($deployedPublicUrl -ceq $script:BaseUri) `
                -Message (
                    "The sealed release environment PUBLIC_APP_URL must be " +
                    "'$script:BaseUri'; observed '$deployedPublicUrl'"
                )
        }
    }
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
    Invoke-InstantRoomEndpointCheck
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
            if ($script:QualificationMode.LanTextOnly) {
                Write-Warning (
                    "LAN text-only qualification intentionally skipped audio and " +
                    "video. Media was NOT qualified for this release origin."
                )
            }
            else {
                Invoke-MediaSpec -Kind "audio" -Playwright $playwright
                Invoke-MediaSpec -Kind "video" -Playwright $playwright
            }
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

    if ($script:QualificationMode.LanTextOnly) {
        Write-Host (
            "Packaged LAN text-only qualification passed at " +
            "$script:BaseUri/app/. Audio and video media were NOT qualified."
        )
    }
    else {
        Write-Host (
            "Packaged local release qualification passed at " +
            "$script:BaseUri/app/, including audio and video media."
        )
    }
}

function Invoke-SelfTest {
    Assert-Condition `
        -Condition (
            (Resolve-SealedBaseUri -Value "http://127.0.0.1:4188") -ceq
            "http://127.0.0.1:4188"
        ) `
        -Message "Self-test could not resolve the default loopback origin"
    Assert-Condition `
        -Condition (
            (Resolve-SealedBaseUri -Value "http://192.168.50.12:4188/") -ceq
            "http://192.168.50.12:4188"
        ) `
        -Message "Self-test could not resolve an RFC1918 LAN origin"
    $lanTextMode = Resolve-QualificationMode `
        -Origin ([Uri]"http://192.168.50.12:4188") `
        -LanTextOnly
    Assert-Condition `
        -Condition (
            $lanTextMode.LanTextOnly -and
            -not $lanTextMode.IsLoopback
        ) `
        -Message "Self-test could not select explicit LAN text-only qualification"
    $lanMediaClaimRejected = $false
    try {
        $null = Resolve-QualificationMode `
            -Origin ([Uri]"http://192.168.50.12:4188")
    }
    catch {
        $lanMediaClaimRejected =
            $_.Exception.Message -match "requires -LanTextOnly"
    }
    Assert-Condition `
        -Condition $lanMediaClaimRejected `
        -Message "Self-test allowed a browser-media claim on plain RFC1918 HTTP"
    $loopbackTextOnlyRejected = $false
    try {
        $null = Resolve-QualificationMode `
            -Origin ([Uri]"http://127.0.0.1:4188") `
            -LanTextOnly
    }
    catch {
        $loopbackTextOnlyRejected = $true
    }
    Assert-Condition `
        -Condition $loopbackTextOnlyRejected `
        -Message "Self-test accepted text-only qualification on loopback"
    $customPorts = [PSCustomObject]@{
        app = 4288
        livekitSignal = 8980
        livekitTcp = 8981
        livekitUdp = 8982
        minio = 6900
    }
    $customReceipt = [PSCustomObject]@{
        schemaVersion = 5
        publicAppUrl = "http://192.168.50.12:4288"
        ports = $customPorts
        network = [PSCustomObject]@{
            bindAddress = "192.168.50.12"
            publicHost = "192.168.50.12"
            publicAppUrl = "http://192.168.50.12:4288"
            podmanBindAddress = "127.0.0.1"
            exposureMode = "lan-forwarder"
        }
        forwarder = [PSCustomObject]@{
            required = $true
            scriptPath = "C:\retained\lan_release_forwarder.mjs"
            scriptSha256 = ("a" * 64)
            configPath = "C:\retained\lan-forwarder.config.json"
            configSha256 = ("b" * 64)
            statusPath = "C:\retained\lan-forwarder.ready.json"
            stdoutLogPath = "C:\retained\lan-forwarder.out.log"
            stderrLogPath = "C:\retained\lan-forwarder.err.log"
            readinessToken = "self-test-readiness-token"
            listeners = @(
                [PSCustomObject]@{
                    name = "app"
                    protocol = "tcp"
                    publicPort = 4288
                    targetHost = "127.0.0.1"
                    targetPort = 4288
                }
                [PSCustomObject]@{
                    name = "minio"
                    protocol = "tcp"
                    publicPort = 6900
                    targetHost = "127.0.0.1"
                    targetPort = 6900
                }
                [PSCustomObject]@{
                    name = "livekitSignal"
                    protocol = "tcp"
                    publicPort = 8980
                    targetHost = "127.0.0.1"
                    targetPort = 8980
                }
                [PSCustomObject]@{
                    name = "livekitTcp"
                    protocol = "tcp"
                    publicPort = 8981
                    targetHost = "127.0.0.1"
                    targetPort = 8981
                }
                [PSCustomObject]@{
                    name = "livekitUdp"
                    protocol = "udp"
                    publicPort = 8982
                    targetHost = "127.0.0.1"
                    targetPort = 8982
                }
            )
        }
    }
    $customTarget = Resolve-SealedReceiptQualificationTarget `
        -Receipt $customReceipt `
        -RequestedBaseUri "http://192.168.50.12:4288"
    $legacyLanReceipt = (
        $customReceipt |
            ConvertTo-Json -Depth 6 |
            ConvertFrom-Json
    )
    $legacyLanReceipt.schemaVersion = 4
    $legacyLanRejected = $false
    try {
        $null = Resolve-SealedReceiptQualificationTarget `
            -Receipt $legacyLanReceipt `
            -RequestedBaseUri "http://192.168.50.12:4288"
    }
    catch {
        $legacyLanRejected =
            $_.Exception.Message -match "accepted only for loopback"
    }
    Assert-Condition `
        -Condition $legacyLanRejected `
        -Message "Self-test accepted a pre-schema-v5 private-LAN receipt"

    $directPodmanReceipt = (
        $customReceipt |
            ConvertTo-Json -Depth 6 |
            ConvertFrom-Json
    )
    $directPodmanReceipt.network.podmanBindAddress = "192.168.50.12"
    $directPodmanRejected = $false
    try {
        $null = Resolve-SealedReceiptQualificationTarget `
            -Receipt $directPodmanReceipt `
            -RequestedBaseUri "http://192.168.50.12:4288"
    }
    catch {
        $directPodmanRejected =
            $_.Exception.Message -match "podmanBindAddress"
    }
    Assert-Condition `
        -Condition $directPodmanRejected `
        -Message "Self-test accepted direct RFC1918 Podman publication evidence"
    $expectedLanPolicy =
        New-ExpectedContentSecurityPolicy `
            -AppOrigin $customTarget.AppOrigin `
            -AppWebSocketOrigin $customTarget.AppWebSocketOrigin `
            -LiveKitOrigin $customTarget.LiveKitOrigin `
            -MinioOrigin $customTarget.MinioOrigin
    foreach ($expectedSource in @(
        "http://192.168.50.12:4288",
        "ws://192.168.50.12:4288",
        "ws://192.168.50.12:8980",
        "http://192.168.50.12:6900"
    )) {
        Assert-Condition `
            -Condition ($expectedLanPolicy.Contains($expectedSource)) `
            -Message "Self-test CSP is missing '$expectedSource'"
    }
    foreach ($defaultSource in @(
        "http://192.168.50.12:4188",
        "ws://192.168.50.12:7980",
        "http://192.168.50.12:5900"
    )) {
        Assert-Condition `
            -Condition (-not $expectedLanPolicy.Contains($defaultSource)) `
            -Message (
                "Self-test CSP retained hard-coded default source '$defaultSource'"
            )
    }
    foreach ($portContract in @(
        @("app", 4288),
        @("livekitSignal", 8980),
        @("livekitTcp", 8981),
        @("livekitUdp", 8982),
        @("minio", 6900)
    )) {
        Assert-Condition `
            -Condition (
                (Get-RequiredReceiptPort `
                    -Ports $customPorts `
                    -Name $portContract[0]) -eq $portContract[1]
            ) `
            -Message (
                "Self-test did not preserve receipt port $($portContract[0])"
            )
    }
    $mismatchedBaseUriRejected = $false
    try {
        $null = Resolve-SealedReceiptQualificationTarget `
            -Receipt $customReceipt `
            -RequestedBaseUri "http://192.168.50.12:4188"
    }
    catch {
        $mismatchedBaseUriRejected =
            $_.Exception.Message -match
                "does not match sealed release origin"
    }
    Assert-Condition `
        -Condition $mismatchedBaseUriRejected `
        -Message "Self-test accepted a BaseUri that differs from the sealed receipt"

    $mismatchedReceipt = (
        $customReceipt |
            ConvertTo-Json -Depth 6 |
            ConvertFrom-Json
    )
    $mismatchedReceipt.network.publicAppUrl =
        "http://192.168.50.12:4388"
    $mismatchedReceiptRejected = $false
    try {
        $null = Resolve-SealedReceiptQualificationTarget `
            -Receipt $mismatchedReceipt `
            -RequestedBaseUri "http://192.168.50.12:4288"
    }
    catch {
        $mismatchedReceiptRejected = $true
    }
    Assert-Condition `
        -Condition $mismatchedReceiptRejected `
        -Message "Self-test accepted inconsistent sealed receipt origins"
    Assert-ForwarderStatusContract `
        -StatusOutput (
            "Forwarder: ready`n" +
            "Observed forwarder matches receipt: True`n" +
            "Observed forwarder configuration hash matches receipt: True`n"
        ) `
        -Target $customTarget
    foreach ($invalidForwarderStatus in @(
        (
            "Forwarder: not-ready`n" +
            "Observed forwarder matches receipt: True`n" +
            "Observed forwarder configuration hash matches receipt: True`n"
        ),
        (
            "Forwarder: ready`n" +
            "Observed forwarder matches receipt: False`n" +
            "Observed forwarder configuration hash matches receipt: True`n"
        ),
        (
            "Forwarder: ready`n" +
            "Observed forwarder matches receipt: True`n" +
            "Observed forwarder configuration hash matches receipt: False`n"
        )
    )) {
        $invalidForwarderStatusRejected = $false
        try {
            Assert-ForwarderStatusContract `
                -StatusOutput $invalidForwarderStatus `
                -Target $customTarget
        }
        catch {
            $invalidForwarderStatusRejected = $true
        }
        Assert-Condition `
            -Condition $invalidForwarderStatusRejected `
            -Message (
                "Self-test accepted incomplete or false LAN forwarder Status " +
                "evidence"
            )
    }

    $loopbackReceipt = [PSCustomObject]@{
        schemaVersion = 5
        publicAppUrl = "http://127.0.0.1:4188"
        ports = [PSCustomObject]@{
            app = 4188
            livekitSignal = 7980
            livekitTcp = 7981
            livekitUdp = 7982
            minio = 5900
        }
        network = [PSCustomObject]@{
            bindAddress = "127.0.0.1"
            publicHost = "127.0.0.1"
            publicAppUrl = "http://127.0.0.1:4188"
            podmanBindAddress = "127.0.0.1"
            exposureMode = "loopback"
        }
        forwarder = [PSCustomObject]@{required = $false}
    }
    $loopbackTarget = Resolve-SealedReceiptQualificationTarget `
        -Receipt $loopbackReceipt `
        -RequestedBaseUri "http://127.0.0.1:4188"
    Assert-ForwarderStatusContract `
        -StatusOutput "Forwarder: not-required`n" `
        -Target $loopbackTarget
    $legacyLoopbackTarget = Resolve-SealedReceiptQualificationTarget `
        -Receipt ([PSCustomObject]@{
            schemaVersion = 4
            publicAppUrl = "http://127.0.0.1:4188"
            ports = $loopbackReceipt.ports
            network = [PSCustomObject]@{
                bindAddress = "127.0.0.1"
                publicHost = "127.0.0.1"
                publicAppUrl = "http://127.0.0.1:4188"
            }
        }) `
        -RequestedBaseUri "http://127.0.0.1:4188"
    Assert-Condition `
        -Condition (
            -not $legacyLoopbackTarget.ForwarderRequired -and
            $legacyLoopbackTarget.IsLoopback
        ) `
        -Message "Self-test rejected compatible schema-v4 loopback evidence"

    $selfTestOrigin = [Uri]$script:BaseUri
    $selfTestHost = $selfTestOrigin.Host
    $script:ExpectedContentSecurityPolicy =
        New-ExpectedContentSecurityPolicy `
            -AppOrigin $script:BaseUri `
            -AppWebSocketOrigin (
                "ws://$selfTestHost`:$($selfTestOrigin.Port)"
            ) `
            -LiveKitOrigin "ws://$selfTestHost`:7980" `
            -MinioOrigin "http://$selfTestHost`:5900"
    foreach ($invalidOrigin in @(
        "https://192.168.50.12:4188",
        "http://example.test:4188",
        "http://8.8.8.8:4188",
        "http://192.168.50.12:4188/app/",
        "http://192.168.50.12:4188?debug=true",
        "http://192.168.050.12:4188"
    )) {
        $invalidOriginRejected = $false
        try {
            $null = Resolve-SealedBaseUri -Value $invalidOrigin
        }
        catch {
            $invalidOriginRejected = $true
        }
        Assert-Condition `
            -Condition $invalidOriginRejected `
            -Message "Self-test accepted invalid BaseUri '$invalidOrigin'"
    }

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
            instant_rooms = $true
            realtime = $true
        }
    })
    Assert-InstantRoomUnavailablePayload `
        -StatusCode 404 `
        -Payload ([PSCustomObject]@{
            error = [PSCustomObject]@{
                code = "instant_room_unavailable"
                detail = "This instant communication room is unavailable"
            }
        })
    $failureResponse = Get-HttpFailureResponse `
        -ErrorRecord ([PSCustomObject]@{
            Exception = [PSCustomObject]@{
                Response = [PSCustomObject]@{
                    StatusCode = 404
                }
            }
            ErrorDetails = [PSCustomObject]@{
                Message = (
                    '{"error":{"code":"instant_room_unavailable",' +
                    '"detail":"This instant communication room is unavailable"}}'
                )
            }
        })
    Assert-InstantRoomUnavailablePayload `
        -StatusCode $failureResponse.StatusCode `
        -Payload ($failureResponse.Content | ConvertFrom-Json)
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

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

function Read-SealedEnvironmentValues {
    param([Parameter(Mandatory)][string]$Path)

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }
        $match = [regex]::Match($line, "^(?<name>[A-Z][A-Z0-9_]*)=(?<value>.*)$")
        Assert-Condition `
            -Condition $match.Success `
            -Message "The sealed release environment contains an invalid entry"
        $name = $match.Groups["name"].Value
        Assert-Condition `
            -Condition (-not $values.ContainsKey($name)) `
            -Message "The sealed release environment defines $name more than once"
        $values[$name] = $match.Groups["value"].Value
    }
    $values
}

function New-QualificationSecret {
    $bytes = New-Object byte[] 48
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
    }
    finally {
        $random.Dispose()
    }
    [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function New-QualificationAppHostPort {
    $listener = [Net.Sockets.TcpListener]::new(
        [Net.IPAddress]::Loopback,
        0
    )
    try {
        $listener.Start()
        [int]$listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Get-QualificationAppContainerName {
    param([Parameter(Mandatory)][string]$QualificationId)

    Assert-Condition `
        -Condition ($QualificationId -cmatch "^[0-9a-f]{32}$") `
        -Message "qualification app id is invalid"
    "k-comms-qualification-app-$QualificationId"
}

function Get-QualificationClientAddress {
    param([Parameter(Mandatory)][string]$QualificationId)

    Assert-Condition `
        -Condition ($QualificationId -cmatch "^[0-9a-f]{32}$") `
        -Message "qualification client id is invalid"
    $first = $QualificationId.Substring(0, 4)
    $second = $QualificationId.Substring(4, 4)
    "2001:db8:{0}:{1}::1" -f $first, $second
}

function Get-QualificationComposeEnvironmentNames {
    param([Parameter(Mandatory)]$ReleaseContext)

    $names = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in $ReleaseContext.Environment.Keys) {
        $null = $names.Add([string]$name)
    }
    $composeText =
        Get-Content -Raw -LiteralPath $ReleaseContext.ComposeSourcePath
    foreach (
        $match in [regex]::Matches(
            $composeText,
            "\$\{(?<name>[A-Z][A-Z0-9_]*)"
        )
    ) {
        $null = $names.Add($match.Groups["name"].Value)
    }
    Write-Output -NoEnumerate $names
}

function Invoke-WithSealedQualificationEnvironment {
    param(
        [Parameter(Mandatory)]$ReleaseContext,
        [Parameter(Mandatory)][hashtable]$Overrides,
        [Parameter(Mandatory)][scriptblock]$Command
    )

    $names = Get-QualificationComposeEnvironmentNames `
        -ReleaseContext $ReleaseContext
    foreach ($name in $Overrides.Keys) {
        $null = $names.Add([string]$name)
    }
    $previous = @{}
    foreach ($name in $names) {
        $previous[$name] =
            [Environment]::GetEnvironmentVariable($name, "Process")
    }

    try {
        foreach ($name in $names) {
            $value =
                if ($Overrides.ContainsKey($name)) {
                    [string]$Overrides[$name]
                }
                elseif ($ReleaseContext.Environment.ContainsKey($name)) {
                    [string]$ReleaseContext.Environment[$name]
                }
                else {
                    $null
                }
            [Environment]::SetEnvironmentVariable(
                $name,
                $value,
                "Process"
            )
        }
        & $Command
    }
    finally {
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $previous[$name],
                "Process"
            )
        }
    }
}

function Enter-QualificationOperationLock {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$ComposeProject
    )

    $mutex =
        New-Object Threading.Mutex(
            $false,
            "Local\KComms.LocalRelease.$ComposeProject"
        )
    $mutexOwned = $false
    try {
        try {
            $mutexOwned = $mutex.WaitOne(0)
        }
        catch [Threading.AbandonedMutexException] {
            $mutexOwned = $true
        }
        if (-not $mutexOwned) {
            throw (
                "Another local-release operation is already using Compose " +
                "project $ComposeProject"
            )
        }

        $lockPath = Join-Path $StateRoot "operation.lock"
        try {
            $stream = [IO.File]::Open(
                $lockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        }
        catch {
            throw (
                "Another local-release operation is already using state " +
                "directory $StateRoot"
            )
        }

        $payload = [Text.Encoding]::UTF8.GetBytes(
            "pid=$PID`nproject=$ComposeProject`noperation=qualification`n" +
            "started=$([DateTime]::UtcNow.ToString('o'))`n"
        )
        $stream.SetLength(0)
        $stream.Write($payload, 0, $payload.Length)
        $stream.Flush()

        [PSCustomObject]@{
            Stream = $stream
            Mutex = $mutex
            MutexOwned = $mutexOwned
        }
    }
    catch {
        if ($mutexOwned) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
        throw
    }
}

function Exit-QualificationOperationLock {
    param([Parameter(Mandatory)]$Lock)

    if ($Lock.Stream) {
        $Lock.Stream.Dispose()
    }
    if ($Lock.MutexOwned) {
        $Lock.Mutex.ReleaseMutex()
    }
    $Lock.Mutex.Dispose()
}

function Resolve-QualificationStateRoot {
    param([Parameter(Mandatory)][string]$ReceiptPath)

    $receiptFullPath = [IO.Path]::GetFullPath($ReceiptPath)
    $candidateDirectory = Split-Path -Parent $receiptFullPath
    $historyDirectory = Split-Path -Parent $candidateDirectory
    Assert-Condition `
        -Condition (
            (Split-Path -Leaf $historyDirectory) -ceq "history"
        ) `
        -Message "The retained receipt is not inside the release history directory"
    $stateRoot = Split-Path -Parent $historyDirectory
    Assert-Condition `
        -Condition (
            -not [string]::IsNullOrWhiteSpace($stateRoot) -and
            (Test-Path -LiteralPath $stateRoot -PathType Container)
        ) `
        -Message "The retained receipt does not identify an existing release state root"
    [IO.Path]::GetFullPath($stateRoot)
}

function Test-QualificationPathEquals {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $Left.Equals(
        $Right,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Resolve-CanonicalQualificationPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Context
    )

    Assert-Condition `
        -Condition ([IO.Path]::IsPathRooted($Path)) `
        -Message "$Context must be an absolute path"
    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-Condition `
        -Condition (Test-QualificationPathEquals -Left $Path -Right $fullPath) `
        -Message "$Context must be canonical and must not contain traversal"
    $fullPath
}

function Assert-QualificationPathsAreNotReparsePoints {
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$Context
    )

    foreach ($path in $Paths) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        ) {
            throw "$Context must not traverse a reparse point: $path"
        }
    }
}

function Assert-QualificationSha256 {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Context
    )

    Assert-Condition `
        -Condition ($Value -cmatch "^[0-9a-f]{64}$") `
        -Message "$Context must be a lowercase SHA-256 digest"
    $Value
}

function Get-QualificationFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($stream)
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
    ([BitConverter]::ToString($digest)).Replace("-", "").ToLowerInvariant()
}

function Resolve-QualificationReleaseContext {
    param(
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][string]$StateRoot
    )

    $stateRootFull = Resolve-CanonicalQualificationPath `
        -Path $StateRoot `
        -Context "qualification release state root"
    $receiptFullPath = Resolve-CanonicalQualificationPath `
        -Path $ReceiptPath `
        -Context "qualification release receipt path"
    $candidateDirectory = Split-Path -Parent $receiptFullPath
    $historyDirectory = Split-Path -Parent $candidateDirectory
    $expectedHistoryDirectory = Join-Path $stateRootFull "history"
    Assert-Condition `
        -Condition (
            (Split-Path -Leaf $receiptFullPath) -ceq "deployment.json" -and
            (Test-QualificationPathEquals `
                -Left $historyDirectory `
                -Right $expectedHistoryDirectory)
        ) `
        -Message (
            "qualification release receipt must be the deployment.json file " +
            "of one direct retained history candidate"
        )
    foreach ($path in @(
        $stateRootFull,
        $expectedHistoryDirectory,
        $candidateDirectory,
        $receiptFullPath
    )) {
        Assert-Condition `
            -Condition (Test-Path -LiteralPath $path) `
            -Message "qualification retained path is missing: $path"
    }
    Assert-QualificationPathsAreNotReparsePoints `
        -Paths @(
            $stateRootFull,
            $expectedHistoryDirectory,
            $candidateDirectory,
            $receiptFullPath
        ) `
        -Context "qualification retained receipt"

    try {
        $receiptText = Get-Content -Raw -LiteralPath $receiptFullPath
        $receipt = $receiptText | ConvertFrom-Json
    }
    catch {
        throw (
            "The retained qualification release receipt is invalid: " +
            "$($_.Exception.Message)"
        )
    }
    $receiptSha256 =
        Get-QualificationFileSha256 -Path $receiptFullPath
    $recordedReceiptPath = [string](Get-RequiredProperty `
        -Object $receipt `
        -Name "receiptPath" `
        -Context "retained qualification release receipt")
    Assert-Condition `
        -Condition (
            Test-QualificationPathEquals `
                -Left $recordedReceiptPath `
                -Right $receiptFullPath
        ) `
        -Message (
            "retained qualification release receiptPath does not identify " +
            "the exact retained receipt"
        )

    $projectName = [string](Get-RequiredProperty `
        -Object $receipt `
        -Name "projectName" `
        -Context "retained qualification release receipt")
    Assert-Condition `
        -Condition ($projectName -cmatch "^[a-z0-9][a-z0-9_-]*$") `
        -Message "retained qualification release projectName is invalid"
    $revision = [string](Get-RequiredProperty `
        -Object $receipt `
        -Name "revision" `
        -Context "retained qualification release receipt")
    Assert-Condition `
        -Condition ($revision -cmatch "^[0-9a-f]{40}$") `
        -Message "retained qualification release revision is invalid"
    $imageReference = [string](Get-RequiredProperty `
        -Object $receipt `
        -Name "imageReference" `
        -Context "retained qualification release receipt")
    Assert-Condition `
        -Condition (
            $imageReference -cmatch
                "^localhost/k-comms:[a-z0-9][a-z0-9._-]{0,127}$"
        ) `
        -Message "retained qualification release imageReference is invalid"
    $imageId = [string](Get-RequiredProperty `
        -Object $receipt `
        -Name "imageId" `
        -Context "retained qualification release receipt")
    Assert-Condition `
        -Condition ($imageId -cmatch "^(?:sha256:)?[0-9a-f]{64}$") `
        -Message "retained qualification release imageId is invalid"

    $environmentFile = [string](Get-RequiredProperty `
        -Object $receipt `
        -Name "environmentFile" `
        -Context "retained qualification release receipt")
    $environmentFullPath = Resolve-CanonicalQualificationPath `
        -Path $environmentFile `
        -Context "retained qualification release environmentFile"
    $expectedEnvironmentPath = Join-Path $candidateDirectory "release.env"
    Assert-Condition `
        -Condition (
            Test-QualificationPathEquals `
                -Left $environmentFullPath `
                -Right $expectedEnvironmentPath
        ) `
        -Message (
            "retained qualification release environmentFile must be the exact " +
            "candidate release.env"
        )
    Assert-Condition `
        -Condition (
            Test-Path -LiteralPath $environmentFullPath -PathType Leaf
        ) `
        -Message (
            "retained qualification release environment is missing: " +
            $environmentFullPath
        )
    $environmentSha256 = [string](Get-RequiredProperty `
        -Object $receipt `
        -Name "environmentSha256" `
        -Context "retained qualification release receipt")
    $null = Assert-QualificationSha256 `
        -Value $environmentSha256 `
        -Context "retained qualification release environmentSha256"
    $observedEnvironmentSha256 =
        Get-QualificationFileSha256 -Path $environmentFullPath
    Assert-Condition `
        -Condition ($observedEnvironmentSha256 -ceq $environmentSha256) `
        -Message (
            "retained qualification release environment hash does not match " +
            "its receipt"
        )

    $composeSourcePath = [string](Get-RequiredProperty `
        -Object $receipt `
        -Name "composeSourcePath" `
        -Context "retained qualification release receipt")
    $composeFullPath = Resolve-CanonicalQualificationPath `
        -Path $composeSourcePath `
        -Context "retained qualification release composeSourcePath"
    $expectedComposePath = Join-Path $candidateDirectory "compose.source.yaml"
    Assert-Condition `
        -Condition (
            Test-QualificationPathEquals `
                -Left $composeFullPath `
                -Right $expectedComposePath
        ) `
        -Message (
            "retained qualification release composeSourcePath must be the " +
            "exact candidate compose.source.yaml"
        )
    Assert-Condition `
        -Condition (Test-Path -LiteralPath $composeFullPath -PathType Leaf) `
        -Message (
            "retained qualification release Compose source is missing: " +
            $composeFullPath
        )
    $composeSourceSha256 = [string](Get-RequiredProperty `
        -Object $receipt `
        -Name "composeSourceSha256" `
        -Context "retained qualification release receipt")
    $null = Assert-QualificationSha256 `
        -Value $composeSourceSha256 `
        -Context "retained qualification release composeSourceSha256"
    $observedComposeSha256 =
        Get-QualificationFileSha256 -Path $composeFullPath
    Assert-Condition `
        -Condition ($observedComposeSha256 -ceq $composeSourceSha256) `
        -Message (
            "retained qualification release Compose source hash does not " +
            "match its receipt"
        )
    Assert-QualificationPathsAreNotReparsePoints `
        -Paths @($environmentFullPath, $composeFullPath) `
        -Context "qualification retained assets"

    $environment = Read-SealedEnvironmentValues -Path $environmentFullPath
    $expectedEnvironment = [ordered]@{
        K_COMMS_RELEASE_PROJECT = $projectName
        K_COMMS_RELEASE_IMAGE = $imageReference
        K_COMMS_RELEASE_REVISION = $revision
    }
    foreach ($expected in $expectedEnvironment.GetEnumerator()) {
        Assert-Condition `
            -Condition (
                $environment.ContainsKey($expected.Key) -and
                [string]$environment[$expected.Key] -ceq
                    [string]$expected.Value
            ) `
            -Message (
                "retained qualification release environment does not match " +
                "its receipt for $($expected.Key)"
            )
    }

    [PSCustomObject]@{
        StateRoot = $stateRootFull
        CandidateDirectory = $candidateDirectory
        Receipt = $receipt
        ReceiptPath = $receiptFullPath
        ReceiptSha256 = $receiptSha256
        ProjectName = $projectName
        Revision = $revision
        ImageReference = $imageReference
        ImageId = $imageId
        EnvironmentFile = $environmentFullPath
        EnvironmentSha256 = $environmentSha256
        Environment = $environment
        ComposeSourcePath = $composeFullPath
        ComposeSourceSha256 = $composeSourceSha256
    }
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
    Assert-PropertyValue `
        -Object $capabilities `
        -Name "bootstrap" `
        -Expected $false `
        -Context "/api/v1/status capabilities"
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

function Assert-SecureTransportRequiredPayload {
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)]$Payload
    )

    Assert-Condition `
        -Condition ($StatusCode -eq 426) `
        -Message (
            "POST /api/v1/sessions on a plain HTTP LAN release must return " +
            "HTTP 426; observed $StatusCode"
        )
    $errorPayload = Get-RequiredProperty `
        -Object $Payload `
        -Name "error" `
        -Context "/api/v1/sessions"
    Assert-PropertyValue `
        -Object $errorPayload `
        -Name "code" `
        -Expected "secure_transport_required" `
        -Context "/api/v1/sessions error"
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

function Invoke-LanSecureTransportBoundaryCheck {
    if (-not $script:QualificationMode.LanTextOnly) {
        return
    }

    $path = "/api/v1/sessions"
    $uri = "$script:BaseUri$path"
    $body = @{
        tenant_slug = "qualification-only"
        email = "qualification@example.invalid"
        password = "invalid-credential"
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri $uri `
            -Method Post `
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
    Assert-SecureTransportRequiredPayload `
        -StatusCode $observed.StatusCode `
        -Payload $payload
    Write-Host "PASS $path secure-transport boundary"
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
    $qualificationStateRoot =
        Resolve-QualificationStateRoot -ReceiptPath $receiptPath
    $releaseContext = Resolve-QualificationReleaseContext `
        -ReceiptPath $receiptPath `
        -StateRoot $qualificationStateRoot
    $receipt = $releaseContext.Receipt

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
    $script:LiveProvisionBaseUri = "http://127.0.0.1:$($target.AppPort)"
    $script:SealedReleaseContext = $releaseContext
    $script:SealedReleaseEnvironmentFile = $releaseContext.EnvironmentFile
    $script:SealedReleaseEnvironment = $releaseContext.Environment
    $script:SealedReleaseComposeSourcePath =
        $releaseContext.ComposeSourcePath
    $script:SealedReleaseProjectName = $releaseContext.ProjectName
    $script:SealedReleaseReceiptPath = $releaseContext.ReceiptPath
    $script:SealedReleaseImageId = $releaseContext.ImageId
    $script:QualificationStateRoot = $releaseContext.StateRoot
    $script:QualificationCleanupReceiptPath =
        Join-Path `
            $script:QualificationStateRoot `
            "qualification-cleanup.json"
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

function Invoke-InstantRoomSpec {
    param([Parameter(Mandatory)][string]$Playwright)

    [Environment]::SetEnvironmentVariable(
        "K_COMMS_LIVE_INSTANT_ROOM_E2E",
        "true",
        "Process"
    )
    [Environment]::SetEnvironmentVariable(
        "K_COMMS_LIVE_INSTANT_ROOM_QUALIFICATION_APP_ORIGIN",
        $script:LiveQualificationAppOrigin,
        "Process"
    )
    [Environment]::SetEnvironmentVariable(
        "K_COMMS_LIVE_INSTANT_ROOM_PUBLIC_ORIGIN",
        $script:BaseUri,
        "Process"
    )
    [Environment]::SetEnvironmentVariable(
        "K_COMMS_LIVE_INSTANT_ROOM_TENANT_SLUG",
        $script:LiveOwnerTenantSlug,
        "Process"
    )
    [Environment]::SetEnvironmentVariable(
        "K_COMMS_LIVE_INSTANT_ROOM_CLIENT_ADDRESS",
        $script:LiveQualificationClientAddress,
        "Process"
    )

    $mode = "anonymous instant-room text"
    Write-Host "Running $mode qualification..."
    & $Playwright `
        "test" `
        "e2e/live-instant-room.spec.ts" `
        "--project=chromium" `
        "--workers=1"
    if ($LASTEXITCODE -ne 0) {
        throw "$mode qualification failed with exit code $LASTEXITCODE"
    }
    Write-Host "PASS $mode qualification"
}

function Invoke-QualificationTenantOperation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("create", "delete")]
        [string]$Action,
        [Parameter(Mandatory)]$ReleaseContext,
        [Parameter(Mandatory)][string]$QualificationId,
        [string]$Password = ""
    )

    Assert-QualificationReleaseImageIdentity -ReleaseContext $ReleaseContext
    $overrides = @{
        K_COMMS_QUALIFICATION_ACTION = $Action
        K_COMMS_QUALIFICATION_ID = $QualificationId
        K_COMMS_QUALIFICATION_PASSWORD = $Password
        K_COMMS_QUALIFICATION_CONFIRMATION =
            "local-release-qualification-tenant-v1"
        ALLOW_BOOTSTRAP = "false"
    }

    $result = Invoke-WithSealedQualificationEnvironment `
        -ReleaseContext $ReleaseContext `
        -Overrides $overrides `
        -Command {
            $output = @(
                & podman compose `
                    --env-file $ReleaseContext.EnvironmentFile `
                    --file $ReleaseContext.ComposeSourcePath `
                    --project-name $ReleaseContext.ProjectName `
                    run --rm --no-deps --pull never qualification 2>&1
            )
            [PSCustomObject]@{
                ExitCode = $LASTEXITCODE
                Output = $output
            }
        }
    if ($result.ExitCode -ne 0) {
        throw (
            "Isolated qualification tenant $Action failed with exit code " +
            "$($result.ExitCode). $($result.Output -join [Environment]::NewLine)"
        )
    }
    Write-Host "PASS isolated qualification tenant $Action"
}

function Get-FixedInstantRoomTenantFingerprint {
    param([Parameter(Mandatory)]$ReleaseContext)

    Assert-QualificationReleaseImageIdentity -ReleaseContext $ReleaseContext
    $overrides = @{
        PODMAN_COMPOSE_WARNING_LOGS = "false"
        K_COMMS_RUNTIME_PURPOSE = "one_shot"
        K_COMMS_INSTANT_ROOM_FINGERPRINT_CONFIRMATION =
            "fixed-instant-room-tenant-fingerprint-v1"
        ALLOW_BOOTSTRAP = "false"
    }
    $result = Invoke-WithSealedQualificationEnvironment `
        -ReleaseContext $ReleaseContext `
        -Overrides $overrides `
        -Command {
            $output = @(
                & podman compose `
                    --env-file $ReleaseContext.EnvironmentFile `
                    --file $ReleaseContext.ComposeSourcePath `
                    --project-name $ReleaseContext.ProjectName `
                    run --rm --no-deps --pull never qualification `
                    eval `
                    "CommsCore.Release.instant_room_tenant_fingerprint()" `
                    2>&1
            )
            [PSCustomObject]@{
                ExitCode = $LASTEXITCODE
                Output = $output
            }
        }
    Assert-Condition `
        -Condition ($result.ExitCode -eq 0) `
        -Message "The fixed instant-room tenant fingerprint command failed"
    $pattern =
        "^K_COMMS_INSTANT_ROOM_TENANT_FINGERPRINT_V1 " +
        "tenant_present=(?:true|false) " +
        "users=[0-9]+ sessions=[0-9]+ devices=[0-9]+ " +
        "conversations=[0-9]+ memberships=[0-9]+ messages=[0-9]+ " +
        "guest_links=[0-9]+ guest_admissions=[0-9]+ " +
        "ephemeral_rooms=[0-9]+ ephemeral_presence_leases=[0-9]+ " +
        "ephemeral_join_receipts=[0-9]+ audit_events=[0-9]+ " +
        "outbox_events=[0-9]+ calls=[0-9]+ call_participants=[0-9]+ " +
        "fingerprint_sha256=[0-9a-f]{64}$"
    $fingerprints = @(
        $result.Output |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -cmatch $pattern }
    )
    Assert-Condition `
        -Condition ($fingerprints.Count -eq 1) `
        -Message (
            "The fixed instant-room tenant fingerprint output was missing " +
            "or ambiguous"
        )
    [string]$fingerprints[0]
}

function Assert-QualificationReleaseImageIdentity {
    param([Parameter(Mandatory)]$ReleaseContext)

    $output = @(
        & podman image inspect $ReleaseContext.ImageReference 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        throw (
            "The originating qualification image is unavailable: " +
            "$($output -join [Environment]::NewLine)"
        )
    }
    try {
        $images = @(
            ($output -join [Environment]::NewLine) | ConvertFrom-Json
        )
    }
    catch {
        throw (
            "The originating qualification image inspection is invalid: " +
            "$($_.Exception.Message)"
        )
    }
    Assert-Condition `
        -Condition ($images.Count -eq 1) `
        -Message "The originating qualification image inspection was ambiguous"
    $image = $images[0]
    Assert-Condition `
        -Condition (
            [string]$image.Id -ceq [string]$ReleaseContext.ImageId
        ) `
        -Message (
            "The originating qualification image tag no longer resolves to " +
            "the marker-bound image ID"
        )
    $labels =
        if ($image.Config -and $image.Config.Labels) {
            $image.Config.Labels
        }
        else {
            $image.Labels
        }
    $revisionProperty =
        if ($labels) {
            $labels.PSObject.Properties["org.opencontainers.image.revision"]
        }
        else {
            $null
        }
    Assert-Condition `
        -Condition (
            $null -ne $revisionProperty -and
            [string]$revisionProperty.Value -ceq
                [string]$ReleaseContext.Revision
        ) `
        -Message (
            "The originating qualification image revision label does not " +
            "match its retained receipt"
        )
}

function Get-OriginReleaseAppProxyCidr {
    param([Parameter(Mandatory)]$ReleaseContext)

    $containerIds = @(
        & podman ps `
            --filter "label=com.docker.compose.project=$($ReleaseContext.ProjectName)" `
            --filter "label=com.docker.compose.service=app" `
            --filter "status=running" `
            --format "{{.ID}}" 2>$null
    )
    Assert-Condition `
        -Condition ($LASTEXITCODE -eq 0 -and $containerIds.Count -eq 1) `
        -Message (
            "The originating release must have exactly one running Compose " +
            "app container before creating an isolated qualification app"
        )
    $output = @(& podman container inspect $containerIds[0] 2>&1)
    Assert-Condition `
        -Condition ($LASTEXITCODE -eq 0) `
        -Message "The originating release app container could not be inspected"
    try {
        $containers = @(
            ($output -join [Environment]::NewLine) | ConvertFrom-Json
        )
    }
    catch {
        throw "The originating release app inspection was invalid"
    }
    Assert-Condition `
        -Condition ($containers.Count -eq 1) `
        -Message "The originating release app inspection was ambiguous"
    $container = $containers[0]
    $observedImageId = ([string]$container.Image).Replace("sha256:", "")
    $expectedImageId =
        ([string]$ReleaseContext.ImageId).Replace("sha256:", "")
    Assert-Condition `
        -Condition (
            $observedImageId -ceq $expectedImageId -and
            [string]$container.ImageName -ceq
                [string]$ReleaseContext.ImageReference
        ) `
        -Message (
            "The originating release app does not match the marker-bound image"
        )

    $networkProperties =
        @($container.NetworkSettings.Networks.PSObject.Properties)
    Assert-Condition `
        -Condition ($networkProperties.Count -eq 1) `
        -Message (
            "The originating release app must use exactly one Compose network"
        )
    $gateway = [string]$networkProperties[0].Value.Gateway
    $gatewayAddress = $null
    Assert-Condition `
        -Condition (
            [Net.IPAddress]::TryParse($gateway, [ref]$gatewayAddress) -and
            $gatewayAddress.AddressFamily -eq
                [Net.Sockets.AddressFamily]::InterNetwork -and
            $gatewayAddress.ToString() -ceq $gateway
        ) `
        -Message (
            "The originating release Compose network gateway is not one " +
            "canonical IPv4 address"
        )
    "$gateway/32"
}

function Get-LiveQualificationAppInspection {
    param([Parameter(Mandatory)][string]$ContainerName)

    & podman container exists $ContainerName *> $null
    $existsExitCode = $LASTEXITCODE
    if ($existsExitCode -eq 1) {
        return $null
    }
    Assert-Condition `
        -Condition ($existsExitCode -eq 0) `
        -Message (
            "Could not determine whether isolated qualification app " +
            "$ContainerName exists"
        )
    $output = @(& podman container inspect $ContainerName 2>&1)
    Assert-Condition `
        -Condition ($LASTEXITCODE -eq 0) `
        -Message "Could not inspect isolated qualification app $ContainerName"
    try {
        $containers = @(
            ($output -join [Environment]::NewLine) | ConvertFrom-Json
        )
    }
    catch {
        throw "The isolated qualification app inspection was invalid"
    }
    Assert-Condition `
        -Condition ($containers.Count -eq 1) `
        -Message "The isolated qualification app inspection was ambiguous"
    $containers[0]
}

function Get-QualificationContainerEnvironmentValue {
    param(
        [Parameter(Mandatory)][object[]]$Environment,
        [Parameter(Mandatory)][string]$Name
    )

    $prefix = "$Name="
    $matches = @(
        $Environment |
            Where-Object { [string]$_ -clike "$prefix*" }
    )
    Assert-Condition `
        -Condition ($matches.Count -eq 1) `
        -Message (
            "The isolated qualification app must define $Name exactly once"
        )
    ([string]$matches[0]).Substring($prefix.Length)
}

function Assert-QualificationAppContainerIdentity {
    param(
        [Parameter(Mandatory)]$Inspection,
        [Parameter(Mandatory)]$CleanupContext
    )

    $containerName = ([string]$Inspection.Name).TrimStart("/")
    Assert-Condition `
        -Condition (
            $containerName -ceq $CleanupContext.AppContainerName
        ) `
        -Message "The isolated qualification app name does not match its marker"
    Assert-Condition `
        -Condition ([string]$Inspection.Id -cmatch "^[0-9a-f]{64}$") `
        -Message "The isolated qualification app container ID is invalid"

    $observedImageId =
        ([string]$Inspection.Image).Replace("sha256:", "")
    $expectedImageId =
        ([string]$CleanupContext.ReleaseContext.ImageId).Replace("sha256:", "")
    Assert-Condition `
        -Condition (
            $observedImageId -ceq $expectedImageId -and
            [string]$Inspection.Config.Image -ceq
                [string]$CleanupContext.ReleaseContext.ImageReference
        ) `
        -Message (
            "The isolated qualification app image does not match its " +
            "originating release"
        )

    $labels = $Inspection.Config.Labels
    $expectedLabels = [ordered]@{
        "com.docker.compose.project" =
            $CleanupContext.ReleaseContext.ProjectName
        "com.docker.compose.service" = "app"
        "com.k-comms.qualification.app" = "true"
        "com.k-comms.qualification.id" =
            $CleanupContext.QualificationId
        "com.k-comms.qualification.nonce" = $CleanupContext.AppNonce
        "com.k-comms.qualification.receipt-sha256" =
            $CleanupContext.ReleaseContext.ReceiptSha256
        "com.k-comms.qualification.environment-sha256" =
            $CleanupContext.ReleaseContext.EnvironmentSha256
        "com.k-comms.qualification.compose-sha256" =
            $CleanupContext.ReleaseContext.ComposeSourceSha256
        "com.k-comms.qualification.revision" =
            $CleanupContext.ReleaseContext.Revision
    }
    foreach ($label in $expectedLabels.GetEnumerator()) {
        $observed = Get-RequiredProperty `
            -Object $labels `
            -Name $label.Key `
            -Context "isolated qualification app labels"
        Assert-Condition `
            -Condition ([string]$observed -ceq [string]$label.Value) `
            -Message (
                "The isolated qualification app label '$($label.Key)' " +
                "does not match its marker"
            )
    }
    $oneOff = Get-RequiredProperty `
        -Object $labels `
        -Name "com.docker.compose.oneoff" `
        -Context "isolated qualification app labels"
    Assert-Condition `
        -Condition ([string]$oneOff -ieq "true") `
        -Message (
            "The isolated qualification app is not labeled as a Compose " +
            "one-off container"
        )
    foreach ($pathLabel in ([ordered]@{
        "com.docker.compose.project.config_files" =
            $CleanupContext.ReleaseContext.ComposeSourcePath
        "com.docker.compose.project.environment_file" =
            $CleanupContext.ReleaseContext.EnvironmentFile
    }).GetEnumerator()) {
        $observedPath = [string](Get-RequiredProperty `
            -Object $labels `
            -Name $pathLabel.Key `
            -Context "isolated qualification app labels")
        Assert-Condition `
            -Condition (
                Test-QualificationPathEquals `
                    -Left ([IO.Path]::GetFullPath($observedPath)) `
                    -Right ([string]$pathLabel.Value)
            ) `
            -Message (
                "The isolated qualification app label '$($pathLabel.Key)' " +
                "does not identify its originating retained asset"
            )
    }
    $imageRevision = Get-RequiredProperty `
        -Object $labels `
        -Name "org.opencontainers.image.revision" `
        -Context "isolated qualification app labels"
    Assert-Condition `
        -Condition (
            [string]$imageRevision -ceq
                [string]$CleanupContext.ReleaseContext.Revision
        ) `
        -Message (
            "The isolated qualification app OCI revision label does not " +
            "match its marker"
        )

    $expectedEnvironment = [ordered]@{
        K_COMMS_ROLE = "edge"
        K_COMMS_RUNTIME_PURPOSE = "application"
        K_COMMS_LOCAL_RELEASE = "true"
        ALLOW_BOOTSTRAP = "false"
        INSTANT_ROOM_TENANT_SLUG =
            "k-comms-qualification-$($CleanupContext.QualificationId)"
        PUBLIC_APP_URL = $CleanupContext.PublicAppUrl
        CORS_ORIGINS = $CleanupContext.AppOrigin
        TRUSTED_PROXY_CIDRS = $CleanupContext.AppTrustedProxyCidr
        K_COMMS_QUALIFICATION_APP_ORIGIN = $CleanupContext.AppOrigin
        K_COMMS_QUALIFICATION_APP_CONFIRMATION =
            "local-release-qualification-app-v1"
    }
    $containerEnvironment = @($Inspection.Config.Env)
    foreach ($expected in $expectedEnvironment.GetEnumerator()) {
        $observed = Get-QualificationContainerEnvironmentValue `
            -Environment $containerEnvironment `
            -Name $expected.Key
        Assert-Condition `
            -Condition ([string]$observed -ceq [string]$expected.Value) `
            -Message (
                "The isolated qualification app environment '$($expected.Key)' " +
                "does not match its marker"
            )
    }

    $portProperties =
        @($Inspection.NetworkSettings.Ports.PSObject.Properties)
    Assert-Condition `
        -Condition (
            $portProperties.Count -eq 1 -and
            $portProperties[0].Name -ceq "4000/tcp"
        ) `
        -Message (
            "The isolated qualification app must publish only container TCP " +
            "port 4000"
        )
    $bindings = @($portProperties[0].Value)
    Assert-Condition `
        -Condition (
            $bindings.Count -eq 1 -and
            [string]$bindings[0].HostIp -ceq "127.0.0.1" -and
            [string]$bindings[0].HostPort -ceq
                [string]$CleanupContext.AppHostPort
        ) `
        -Message (
            "The isolated qualification app port binding does not match its " +
            "exact loopback marker"
        )

    Assert-Condition `
        -Condition (
            [bool]$Inspection.HostConfig.ReadonlyRootfs -and
            [string]$Inspection.Config.User -ceq "10001:10001" -and
            @($Inspection.EffectiveCaps).Count -eq 0 -and
            @($Inspection.HostConfig.SecurityOpt) -ccontains
                "no-new-privileges" -and
            $null -ne
                $Inspection.HostConfig.Tmpfs.PSObject.Properties["/tmp"] -and
            [string]$Inspection.HostConfig.RestartPolicy.Name -in @("", "no")
        ) `
        -Message (
            "The isolated qualification app did not inherit the hardened " +
            "non-restarting app service contract"
        )
}

function Assert-LiveQualificationAppRuntime {
    param(
        [Parameter(Mandatory)]$Inspection,
        [Parameter(Mandatory)]$CleanupContext
    )

    Assert-QualificationAppContainerIdentity `
        -Inspection $Inspection `
        -CleanupContext $CleanupContext
    Assert-Condition `
        -Condition (
            [bool]$Inspection.State.Running -and
            [string]$Inspection.State.Health.Status -ceq "healthy"
        ) `
        -Message "The isolated qualification app is not running and healthy"

    $portOutput = @(& podman port $Inspection.Id "4000/tcp" 2>&1)
    Assert-Condition `
        -Condition (
            $LASTEXITCODE -eq 0 -and
            $portOutput.Count -eq 1 -and
            [string]$portOutput[0] -ceq
                "127.0.0.1:$($CleanupContext.AppHostPort)"
        ) `
        -Message (
            "The isolated qualification app did not report its exact " +
            "loopback-only publication"
        )
    $listeners = @(
        Get-NetTCPConnection `
            -LocalPort $CleanupContext.AppHostPort `
            -State Listen `
            -ErrorAction SilentlyContinue
    )
    Assert-Condition `
        -Condition (
            $listeners.Count -gt 0 -and
            @(
                $listeners |
                    Where-Object {
                        [string]$_.LocalAddress -cne "127.0.0.1"
                    }
            ).Count -eq 0
        ) `
        -Message (
            "The isolated qualification app host port is not exclusively " +
            "listening on 127.0.0.1"
        )

    $healthUri = "$($CleanupContext.AppOrigin)/health/ready"
    try {
        $response = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri $healthUri `
            -Method Get `
            -TimeoutSec 15
        $payload = $response.Content | ConvertFrom-Json
    }
    catch {
        throw "The isolated qualification app readiness probe failed"
    }
    Assert-Condition `
        -Condition ($response.StatusCode -eq 200) `
        -Message "The isolated qualification app readiness status was not 200"
    Assert-ReadinessPayload -Payload $payload

    $runtime = Get-RequiredProperty `
        -Object (Get-RequiredProperty `
            -Object $payload `
            -Name "checks" `
            -Context "isolated qualification app readiness") `
        -Name "runtime" `
        -Context "isolated qualification app readiness checks"
    Assert-PropertyValue `
        -Object $runtime `
        -Name "role" `
        -Expected "edge" `
        -Context "isolated qualification app runtime"
    Assert-PropertyValue `
        -Object $runtime `
        -Name "jobs" `
        -Expected "disabled" `
        -Context "isolated qualification app runtime"
}

function Start-LiveQualificationApp {
    param([Parameter(Mandatory)]$CleanupContext)

    Assert-QualificationReleaseImageIdentity `
        -ReleaseContext $CleanupContext.ReleaseContext
    $existing = Get-LiveQualificationAppInspection `
        -ContainerName $CleanupContext.AppContainerName
    Assert-Condition `
        -Condition ($null -eq $existing) `
        -Message (
            "Refusing to replace an existing isolated qualification app " +
            "container"
        )

    $overrides = @{
        PODMAN_COMPOSE_WARNING_LOGS = "false"
        K_COMMS_ROLE = "edge"
        K_COMMS_RUNTIME_PURPOSE = "application"
        K_COMMS_LOCAL_RELEASE = "true"
        ALLOW_BOOTSTRAP = "false"
        INSTANT_ROOM_TENANT_SLUG =
            "k-comms-qualification-$($CleanupContext.QualificationId)"
        PUBLIC_APP_URL = $CleanupContext.PublicAppUrl
        CORS_ORIGINS = $CleanupContext.AppOrigin
        TRUSTED_PROXY_CIDRS = $CleanupContext.AppTrustedProxyCidr
        K_COMMS_QUALIFICATION_APP_ORIGIN = $CleanupContext.AppOrigin
        K_COMMS_QUALIFICATION_APP_CONFIRMATION =
            "local-release-qualification-app-v1"
    }
    $result = Invoke-WithSealedQualificationEnvironment `
        -ReleaseContext $CleanupContext.ReleaseContext `
        -Overrides $overrides `
        -Command {
            $output = @(
                & podman compose `
                    --env-file $CleanupContext.ReleaseContext.EnvironmentFile `
                    --file $CleanupContext.ReleaseContext.ComposeSourcePath `
                    --project-name $CleanupContext.ReleaseContext.ProjectName `
                    run --detach --no-deps --pull never `
                    --name $CleanupContext.AppContainerName `
                    --publish "127.0.0.1:$($CleanupContext.AppHostPort):4000" `
                    --env "K_COMMS_ROLE=edge" `
                    --env "K_COMMS_RUNTIME_PURPOSE=application" `
                    --env "K_COMMS_LOCAL_RELEASE=true" `
                    --env "ALLOW_BOOTSTRAP=false" `
                    --env (
                        "INSTANT_ROOM_TENANT_SLUG=" +
                        "k-comms-qualification-$($CleanupContext.QualificationId)"
                    ) `
                    --env "PUBLIC_APP_URL=$($CleanupContext.PublicAppUrl)" `
                    --env "CORS_ORIGINS=$($CleanupContext.AppOrigin)" `
                    --env (
                        "TRUSTED_PROXY_CIDRS=" +
                        $CleanupContext.AppTrustedProxyCidr
                    ) `
                    --env (
                        "K_COMMS_QUALIFICATION_APP_ORIGIN=" +
                        $CleanupContext.AppOrigin
                    ) `
                    --env (
                        "K_COMMS_QUALIFICATION_APP_CONFIRMATION=" +
                        "local-release-qualification-app-v1"
                    ) `
                    --label "com.k-comms.qualification.app=true" `
                    --label (
                        "com.k-comms.qualification.id=" +
                        $CleanupContext.QualificationId
                    ) `
                    --label (
                        "com.k-comms.qualification.nonce=" +
                        $CleanupContext.AppNonce
                    ) `
                    --label (
                        "com.k-comms.qualification.receipt-sha256=" +
                        $CleanupContext.ReleaseContext.ReceiptSha256
                    ) `
                    --label (
                        "com.k-comms.qualification.environment-sha256=" +
                        $CleanupContext.ReleaseContext.EnvironmentSha256
                    ) `
                    --label (
                        "com.k-comms.qualification.compose-sha256=" +
                        $CleanupContext.ReleaseContext.ComposeSourceSha256
                    ) `
                    --label (
                        "com.k-comms.qualification.revision=" +
                        $CleanupContext.ReleaseContext.Revision
                    ) `
                    app 2>&1
            )
            [PSCustomObject]@{
                ExitCode = $LASTEXITCODE
                Output = $output
            }
        }
    Assert-Condition `
        -Condition ($result.ExitCode -eq 0) `
        -Message (
            "The isolated qualification app could not be started from the " +
            "originating app service"
        )

    for ($attempt = 0; $attempt -lt 45; $attempt++) {
        $inspection = Get-LiveQualificationAppInspection `
            -ContainerName $CleanupContext.AppContainerName
        if ($null -ne $inspection) {
            Assert-QualificationAppContainerIdentity `
                -Inspection $inspection `
                -CleanupContext $CleanupContext
            if (
                [bool]$inspection.State.Running -and
                [string]$inspection.State.Health.Status -ceq "healthy"
            ) {
                Assert-LiveQualificationAppRuntime `
                    -Inspection $inspection `
                    -CleanupContext $CleanupContext
                Write-Host "PASS isolated qualification app"
                return
            }
            if (-not [bool]$inspection.State.Running) {
                throw (
                    "The isolated qualification app stopped before becoming " +
                    "healthy"
                )
            }
        }
        Start-Sleep -Seconds 2
    }
    throw "The isolated qualification app did not become healthy in time"
}

function Remove-LiveQualificationApp {
    param([Parameter(Mandatory)]$CleanupContext)

    $inspection = Get-LiveQualificationAppInspection `
        -ContainerName $CleanupContext.AppContainerName
    if ($null -eq $inspection) {
        Write-Host "PASS isolated qualification app already absent"
        return
    }
    Assert-QualificationAppContainerIdentity `
        -Inspection $inspection `
        -CleanupContext $CleanupContext
    $output = @(& podman rm --force --time 10 $inspection.Id 2>&1)
    Assert-Condition `
        -Condition ($LASTEXITCODE -eq 0) `
        -Message "The verified isolated qualification app could not be removed"
    $remaining = Get-LiveQualificationAppInspection `
        -ContainerName $CleanupContext.AppContainerName
    Assert-Condition `
        -Condition ($null -eq $remaining) `
        -Message (
            "The isolated qualification app still exists after verified removal"
        )
    Write-Host "PASS isolated qualification app removal"
}

function Write-QualificationCleanupReceipt {
    param(
        [Parameter(Mandatory)]$ReleaseContext,
        [Parameter(Mandatory)][string]$QualificationId,
        [Parameter(Mandatory)][string]$AppContainerName,
        [Parameter(Mandatory)][string]$AppNonce,
        [Parameter(Mandatory)][int]$AppHostPort,
        [Parameter(Mandatory)][string]$AppOrigin,
        [Parameter(Mandatory)][string]$AppTrustedProxyCidr,
        [Parameter(Mandatory)][string]$ClientAddress,
        [Parameter(Mandatory)][string]$PublicAppUrl,
        [Parameter(Mandatory)][string]$CleanupReceiptPath
    )

    Assert-Condition `
        -Condition ($QualificationId -cmatch "^[0-9a-f]{32}$") `
        -Message "qualification cleanup id is invalid"
    $tenantSlug = "k-comms-qualification-$QualificationId"
    Assert-Condition `
        -Condition (
            $AppContainerName -ceq
                (Get-QualificationAppContainerName `
                    -QualificationId $QualificationId) -and
            $AppNonce -cmatch "^[0-9a-f]{32}$" -and
            $AppHostPort -ge 1024 -and
            $AppHostPort -le 65535 -and
            $AppOrigin -ceq "http://127.0.0.1:$AppHostPort" -and
            $AppTrustedProxyCidr -cmatch
                "^(?:[0-9]{1,3}\.){3}[0-9]{1,3}/32$" -and
            $ClientAddress -ceq
                (Get-QualificationClientAddress `
                    -QualificationId $QualificationId)
        ) `
        -Message "qualification app cleanup identity is invalid"
    $sealedAppOrigin = Resolve-SealedBaseUri -Value $AppOrigin
    $sealedPublicAppUrl = Resolve-SealedBaseUri -Value $PublicAppUrl
    Assert-Condition `
        -Condition (
            $sealedAppOrigin -ceq $AppOrigin -and
            $sealedPublicAppUrl -ceq $PublicAppUrl -and
            ([Uri]$sealedPublicAppUrl).Port -ne $AppHostPort -and
            $ReleaseContext.Environment.ContainsKey("PUBLIC_APP_URL") -and
            [string]$ReleaseContext.Environment["PUBLIC_APP_URL"] -ceq
                $PublicAppUrl
        ) `
        -Message (
            "qualification app origins do not match the originating sealed " +
            "release"
        )
    $expectedCleanupPath =
        Join-Path $ReleaseContext.StateRoot "qualification-cleanup.json"
    Assert-Condition `
        -Condition (
            Test-QualificationPathEquals `
                -Left ([IO.Path]::GetFullPath($CleanupReceiptPath)) `
                -Right $expectedCleanupPath
        ) `
        -Message (
            "qualification cleanup receipt must remain at the exact release " +
            "state root"
        )
    Assert-Condition `
        -Condition (-not (Test-Path -LiteralPath $CleanupReceiptPath)) `
        -Message (
            "A qualification cleanup receipt already exists and must be " +
            "recovered before creating another tenant"
        )
    $receipt = [ordered]@{
        schemaVersion = 3
        kind = "k-comms-qualification-cleanup"
        qualificationId = $QualificationId
        tenantSlug = $tenantSlug
        qualificationAppContainerName = $AppContainerName
        qualificationAppNonce = $AppNonce
        qualificationAppHostPort = $AppHostPort
        qualificationAppOrigin = $AppOrigin
        qualificationAppTrustedProxyCidr = $AppTrustedProxyCidr
        qualificationClientAddress = $ClientAddress
        publicAppUrl = $PublicAppUrl
        projectName = $ReleaseContext.ProjectName
        receiptPath = $ReleaseContext.ReceiptPath
        receiptSha256 = $ReleaseContext.ReceiptSha256
        environmentFile = $ReleaseContext.EnvironmentFile
        environmentSha256 = $ReleaseContext.EnvironmentSha256
        composeSourcePath = $ReleaseContext.ComposeSourcePath
        composeSourceSha256 = $ReleaseContext.ComposeSourceSha256
        imageReference = $ReleaseContext.ImageReference
        imageId = $ReleaseContext.ImageId
        revision = $ReleaseContext.Revision
        createdAt = [DateTime]::UtcNow.ToString("o")
    }
    $temporaryPath =
        "$CleanupReceiptPath.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            ($receipt | ConvertTo-Json -Depth 4),
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item `
            -LiteralPath $temporaryPath `
            -Destination $CleanupReceiptPath `
            -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Remove-LiveQualificationResources {
    param(
        [Parameter(Mandatory)]$CleanupContext,
        [Parameter(Mandatory)][string]$CleanupReceiptPath,
        [scriptblock]$AppCleanupAction,
        [scriptblock]$TenantCleanupAction
    )

    if ($CleanupContext.SchemaVersion -ge 3) {
        if ($AppCleanupAction) {
            & $AppCleanupAction $CleanupContext
        }
        else {
            Remove-LiveQualificationApp -CleanupContext $CleanupContext
        }
    }
    if ($TenantCleanupAction) {
        & $TenantCleanupAction $CleanupContext
    }
    else {
        Invoke-QualificationTenantOperation `
            -Action "delete" `
            -ReleaseContext $CleanupContext.ReleaseContext `
            -QualificationId $CleanupContext.QualificationId
    }
    if (Test-Path -LiteralPath $CleanupReceiptPath) {
        Remove-Item -LiteralPath $CleanupReceiptPath -Force
    }
}

function Resolve-QualificationCleanupReceipt {
    param(
        [Parameter(Mandatory)][string]$CleanupReceiptPath,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$ExpectedProjectName
    )

    try {
        $receipt =
            Get-Content -Raw -LiteralPath $CleanupReceiptPath |
                ConvertFrom-Json
    }
    catch {
        throw "The retained qualification cleanup receipt is invalid"
    }
    $schemaVersionProperty =
        $receipt.PSObject.Properties["schemaVersion"]
    Assert-Condition `
        -Condition (
            $null -ne $schemaVersionProperty -and
            $schemaVersionProperty.Value -is [int] -and
            [int]$schemaVersionProperty.Value -in @(2, 3) -and
            [string]$receipt.kind -ceq "k-comms-qualification-cleanup"
        ) `
        -Message "The retained qualification cleanup receipt schema is invalid"
    $schemaVersion = [int]$schemaVersionProperty.Value
    $expectedProperties = @(
        "schemaVersion",
        "kind",
        "qualificationId",
        "projectName",
        "receiptPath",
        "receiptSha256",
        "environmentFile",
        "environmentSha256",
        "composeSourcePath",
        "composeSourceSha256",
        "imageReference",
        "imageId",
        "revision",
        "createdAt"
    )
    if ($schemaVersion -eq 3) {
        $expectedProperties += @(
            "tenantSlug",
            "qualificationAppContainerName",
            "qualificationAppNonce",
            "qualificationAppHostPort",
            "qualificationAppOrigin",
            "qualificationAppTrustedProxyCidr",
            "qualificationClientAddress",
            "publicAppUrl"
        )
    }
    $observedProperties = @($receipt.PSObject.Properties.Name)
    Assert-Condition `
        -Condition (
            $observedProperties.Count -eq $expectedProperties.Count -and
            @(
                $expectedProperties |
                    Where-Object { $observedProperties -cnotcontains $_ }
            ).Count -eq 0 -and
            @(
                $observedProperties |
                    Where-Object { $expectedProperties -cnotcontains $_ }
            ).Count -eq 0
        ) `
        -Message (
            "The retained qualification cleanup receipt must contain only " +
            "the exact schema-v$schemaVersion properties"
        )
    $qualificationId = [string]$receipt.qualificationId
    Assert-Condition `
        -Condition ($qualificationId -cmatch "^[0-9a-f]{32}$") `
        -Message "The retained qualification cleanup receipt id is invalid"
    try {
        $createdAt = [DateTime]::ParseExact(
            [string]$receipt.createdAt,
            "o",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    }
    catch {
        throw "The retained qualification cleanup receipt timestamp is invalid"
    }
    Assert-Condition `
        -Condition ($createdAt.Kind -eq [DateTimeKind]::Utc) `
        -Message (
            "The retained qualification cleanup receipt timestamp must be UTC"
        )

    $releaseContext = Resolve-QualificationReleaseContext `
        -ReceiptPath ([string]$receipt.receiptPath) `
        -StateRoot $StateRoot
    Assert-Condition `
        -Condition (
            $releaseContext.ProjectName -ceq $ExpectedProjectName
        ) `
        -Message (
            "The retained qualification cleanup receipt belongs to another " +
            "Compose project"
        )
    $expectedBindings = [ordered]@{
        projectName = $releaseContext.ProjectName
        receiptPath = $releaseContext.ReceiptPath
        receiptSha256 = $releaseContext.ReceiptSha256
        environmentFile = $releaseContext.EnvironmentFile
        environmentSha256 = $releaseContext.EnvironmentSha256
        composeSourcePath = $releaseContext.ComposeSourcePath
        composeSourceSha256 = $releaseContext.ComposeSourceSha256
        imageReference = $releaseContext.ImageReference
        imageId = $releaseContext.ImageId
        revision = $releaseContext.Revision
    }
    foreach ($binding in $expectedBindings.GetEnumerator()) {
        Assert-Condition `
            -Condition (
                [string]$receipt.($binding.Key) -ceq
                    [string]$binding.Value
            ) `
            -Message (
                "The retained qualification cleanup receipt does not match " +
                "its originating release for $($binding.Key)"
            )
    }

    $tenantSlug = $null
    $appContainerName = $null
    $appNonce = $null
    $appHostPort = $null
    $appOrigin = $null
    $appTrustedProxyCidr = $null
    $clientAddress = $null
    $publicAppUrl = $null
    if ($schemaVersion -eq 3) {
        $tenantSlug = [string]$receipt.tenantSlug
        $appContainerName =
            [string]$receipt.qualificationAppContainerName
        $appNonce = [string]$receipt.qualificationAppNonce
        $appHostPortValue = $receipt.qualificationAppHostPort
        $appOrigin = [string]$receipt.qualificationAppOrigin
        $appTrustedProxyCidr =
            [string]$receipt.qualificationAppTrustedProxyCidr
        $clientAddress = [string]$receipt.qualificationClientAddress
        $publicAppUrl = [string]$receipt.publicAppUrl
        $proxyParts = $appTrustedProxyCidr.Split("/")
        $proxyAddress = $null
        Assert-Condition `
            -Condition (
                $tenantSlug -ceq
                    "k-comms-qualification-$qualificationId" -and
                $appContainerName -ceq
                    (Get-QualificationAppContainerName `
                        -QualificationId $qualificationId) -and
                $appNonce -cmatch "^[0-9a-f]{32}$" -and
                $appHostPortValue -is [int] -and
                [int]$appHostPortValue -ge 1024 -and
                [int]$appHostPortValue -le 65535 -and
                $appOrigin -ceq
                    "http://127.0.0.1:$appHostPortValue" -and
                $proxyParts.Count -eq 2 -and
                $proxyParts[1] -ceq "32" -and
                [Net.IPAddress]::TryParse(
                    $proxyParts[0],
                    [ref]$proxyAddress
                ) -and
                $proxyAddress.AddressFamily -eq
                    [Net.Sockets.AddressFamily]::InterNetwork -and
                $proxyAddress.ToString() -ceq $proxyParts[0] -and
                $clientAddress -ceq
                    (Get-QualificationClientAddress `
                        -QualificationId $qualificationId)
            ) `
            -Message (
                "The retained qualification cleanup receipt app identity " +
                "is invalid"
            )
        $appHostPort = [int]$appHostPortValue
        $sealedAppOrigin = Resolve-SealedBaseUri -Value $appOrigin
        $sealedPublicAppUrl =
            Resolve-SealedBaseUri -Value $publicAppUrl
        Assert-Condition `
            -Condition (
                $sealedAppOrigin -ceq $appOrigin -and
                $sealedPublicAppUrl -ceq $publicAppUrl -and
                ([Uri]$publicAppUrl).Port -ne $appHostPort -and
                $releaseContext.Environment.ContainsKey("PUBLIC_APP_URL") -and
                [string]$releaseContext.Environment["PUBLIC_APP_URL"] -ceq
                    $publicAppUrl
            ) `
            -Message (
                "The retained qualification cleanup receipt origins do not " +
                "match the originating release"
            )
    }

    [PSCustomObject]@{
        SchemaVersion = $schemaVersion
        QualificationId = $qualificationId
        TenantSlug = $tenantSlug
        AppContainerName = $appContainerName
        AppNonce = $appNonce
        AppHostPort = $appHostPort
        AppOrigin = $appOrigin
        AppTrustedProxyCidr = $appTrustedProxyCidr
        ClientAddress = $clientAddress
        PublicAppUrl = $publicAppUrl
        ReleaseContext = $releaseContext
    }
}

function Recover-StaleLiveQualificationResources {
    param(
        [Parameter(Mandatory)][string]$CleanupReceiptPath,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$ExpectedProjectName,
        [scriptblock]$AppCleanupAction,
        [scriptblock]$TenantCleanupAction
    )

    if (-not (
        Test-Path `
            -LiteralPath $CleanupReceiptPath `
            -PathType Leaf
    )) {
        return
    }
    $cleanupFullPath = Resolve-CanonicalQualificationPath `
        -Path $CleanupReceiptPath `
        -Context "qualification cleanup receipt path"
    $expectedCleanupPath =
        Join-Path ([IO.Path]::GetFullPath($StateRoot)) "qualification-cleanup.json"
    Assert-Condition `
        -Condition (
            Test-QualificationPathEquals `
                -Left $cleanupFullPath `
                -Right $expectedCleanupPath
        ) `
        -Message (
            "qualification cleanup receipt is outside the exact release " +
            "state root"
        )
    Assert-QualificationPathsAreNotReparsePoints `
        -Paths @($cleanupFullPath) `
        -Context "qualification cleanup receipt"
    $recovery = Resolve-QualificationCleanupReceipt `
        -CleanupReceiptPath $cleanupFullPath `
        -StateRoot $StateRoot `
        -ExpectedProjectName $ExpectedProjectName
    Remove-LiveQualificationResources `
        -CleanupContext $recovery `
        -CleanupReceiptPath $cleanupFullPath `
        -AppCleanupAction $AppCleanupAction `
        -TenantCleanupAction $TenantCleanupAction
    Write-Host "PASS stale isolated qualification resource recovery"
}

function Initialize-LiveQualificationResources {
    $script:LiveQualificationId = [Guid]::NewGuid().ToString("N")
    $script:LiveOwnerTenantSlug =
        "k-comms-qualification-$($script:LiveQualificationId)"
    $script:LiveOwnerEmail =
        "k-comms-qualification-owner+$($script:LiveQualificationId)@example.test"
    $script:LiveOwnerPassword = New-QualificationSecret
    $script:LiveQualificationAppContainerName =
        Get-QualificationAppContainerName `
            -QualificationId $script:LiveQualificationId
    $script:LiveQualificationAppNonce =
        [Guid]::NewGuid().ToString("N")
    $script:LiveQualificationAppHostPort =
        New-QualificationAppHostPort
    $script:LiveQualificationAppOrigin =
        "http://127.0.0.1:$($script:LiveQualificationAppHostPort)"
    $script:LiveQualificationAppTrustedProxyCidr =
        Get-OriginReleaseAppProxyCidr `
            -ReleaseContext $script:SealedReleaseContext
    $script:LiveQualificationClientAddress =
        Get-QualificationClientAddress `
            -QualificationId $script:LiveQualificationId
    Write-QualificationCleanupReceipt `
        -ReleaseContext $script:SealedReleaseContext `
        -QualificationId $script:LiveQualificationId `
        -AppContainerName $script:LiveQualificationAppContainerName `
        -AppNonce $script:LiveQualificationAppNonce `
        -AppHostPort $script:LiveQualificationAppHostPort `
        -AppOrigin $script:LiveQualificationAppOrigin `
        -AppTrustedProxyCidr `
            $script:LiveQualificationAppTrustedProxyCidr `
        -ClientAddress $script:LiveQualificationClientAddress `
        -PublicAppUrl $script:BaseUri `
        -CleanupReceiptPath $script:QualificationCleanupReceiptPath
    $script:LiveQualificationCleanupContext =
        Resolve-QualificationCleanupReceipt `
            -CleanupReceiptPath $script:QualificationCleanupReceiptPath `
            -StateRoot $script:QualificationStateRoot `
            -ExpectedProjectName $script:SealedReleaseProjectName
    Invoke-QualificationTenantOperation `
        -Action "create" `
        -ReleaseContext $script:SealedReleaseContext `
        -QualificationId $script:LiveQualificationId `
        -Password $script:LiveOwnerPassword
    Start-LiveQualificationApp `
        -CleanupContext $script:LiveQualificationCleanupContext
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
    Invoke-JsonEndpointCheck -Path "/health/live" -Validator ${function:Assert-LivenessPayload}
    Invoke-JsonEndpointCheck -Path "/health/ready" -Validator ${function:Assert-ReadinessPayload}
    Invoke-JsonEndpointCheck -Path "/api/v1/status" -Validator ${function:Assert-StatusPayload}
    Invoke-InstantRoomEndpointCheck
    Invoke-LanSecureTransportBoundaryCheck
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
        "K_COMMS_LIVE_INSTANT_ROOM_E2E",
        "K_COMMS_LIVE_INSTANT_ROOM_QUALIFICATION_APP_ORIGIN",
        "K_COMMS_LIVE_INSTANT_ROOM_PUBLIC_ORIGIN",
        "K_COMMS_LIVE_INSTANT_ROOM_TENANT_SLUG",
        "K_COMMS_LIVE_INSTANT_ROOM_CLIENT_ADDRESS",
        "K_COMMS_LIVE_GUEST_E2E",
        "K_COMMS_LIVE_GUEST_BASE_URL",
        "K_COMMS_LIVE_PROVISION_BASE_URL",
        "K_COMMS_LIVE_OWNER_TENANT_SLUG",
        "K_COMMS_LIVE_OWNER_EMAIL",
        "K_COMMS_LIVE_OWNER_PASSWORD",
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

    $cleanupEnabled = $false
    $fixedTenantFingerprintBefore = $null
    $primaryFailure = $null
    $cleanupFailure = $null
    $fingerprintFailure = $null
    try {
        try {
            Recover-StaleLiveQualificationResources `
                -CleanupReceiptPath $script:QualificationCleanupReceiptPath `
                -StateRoot $script:QualificationStateRoot `
                -ExpectedProjectName $script:SealedReleaseProjectName
            $cleanupEnabled = $true
            $fixedTenantFingerprintBefore =
                Get-FixedInstantRoomTenantFingerprint `
                    -ReleaseContext $script:SealedReleaseContext
            Initialize-LiveQualificationResources
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
            if (-not $script:QualificationMode.LanTextOnly) {
                [Environment]::SetEnvironmentVariable(
                    "K_COMMS_LIVE_PROVISION_BASE_URL",
                    $script:LiveProvisionBaseUri,
                    "Process"
                )
                [Environment]::SetEnvironmentVariable(
                    "K_COMMS_LIVE_OWNER_TENANT_SLUG",
                    $script:LiveOwnerTenantSlug,
                    "Process"
                )
                [Environment]::SetEnvironmentVariable(
                    "K_COMMS_LIVE_OWNER_EMAIL",
                    $script:LiveOwnerEmail,
                    "Process"
                )
                [Environment]::SetEnvironmentVariable(
                    "K_COMMS_LIVE_OWNER_PASSWORD",
                    $script:LiveOwnerPassword,
                    "Process"
                )
            }
            else {
                foreach ($name in @(
                    "K_COMMS_LIVE_PROVISION_BASE_URL",
                    "K_COMMS_LIVE_OWNER_TENANT_SLUG",
                    "K_COMMS_LIVE_OWNER_EMAIL",
                    "K_COMMS_LIVE_OWNER_PASSWORD"
                )) {
                    [Environment]::SetEnvironmentVariable(
                        $name,
                        $null,
                        "Process"
                    )
                }
            }
            Push-Location $webRoot
            try {
                Invoke-InstantRoomSpec -Playwright $playwright
                if ($script:QualificationMode.LanTextOnly) {
                    Write-Warning (
                        "LAN text-only qualification intentionally skipped " +
                        "sign-in, account conversion, account-authenticated " +
                        "guest links, audio, and video. Credential and media " +
                        "operations were NOT qualified for this release origin."
                    )
                }
                else {
                    Invoke-GuestSpec -Playwright $playwright
                    Invoke-MediaSpec -Kind "audio" -Playwright $playwright
                    Invoke-MediaSpec -Kind "video" -Playwright $playwright
                }
            }
            finally {
                Pop-Location
            }
        }
        catch {
            $primaryFailure = $_.Exception
        }

        try {
            if ($cleanupEnabled) {
                Recover-StaleLiveQualificationResources `
                    -CleanupReceiptPath `
                        $script:QualificationCleanupReceiptPath `
                    -StateRoot $script:QualificationStateRoot `
                    -ExpectedProjectName `
                        $script:SealedReleaseProjectName
            }
        }
        catch {
            $cleanupFailure = [InvalidOperationException]::new(
                "Mandatory isolated qualification resource cleanup failed",
                $_.Exception
            )
        }

        try {
            if ($null -ne $fixedTenantFingerprintBefore) {
                $fixedTenantFingerprintAfter =
                    Get-FixedInstantRoomTenantFingerprint `
                        -ReleaseContext $script:SealedReleaseContext
                Assert-Condition `
                    -Condition (
                        $fixedTenantFingerprintAfter -ceq
                            $fixedTenantFingerprintBefore
                    ) `
                    -Message (
                        "Qualification changed the fixed instant-room tenant " +
                        "graph"
                    )
                Write-Host "PASS fixed instant-room tenant graph unchanged"
            }
        }
        catch {
            $fingerprintFailure = [InvalidOperationException]::new(
                "Mandatory fixed instant-room tenant fingerprint check failed",
                $_.Exception
            )
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

    $failures = [Collections.Generic.List[Exception]]::new()
    foreach ($failure in @(
        $primaryFailure,
        $cleanupFailure,
        $fingerprintFailure
    )) {
        if ($null -ne $failure) {
            $failures.Add($failure)
        }
    }
    if ($failures.Count -eq 1) {
        throw $failures[0]
    }
    if ($failures.Count -gt 1) {
        throw [AggregateException]::new(
            (
                "Packaged release qualification failed and one or more " +
                "mandatory finalization checks also failed"
            ),
            $failures.ToArray()
        )
    }
}

function Write-QualificationSuccess {
    if ($script:QualificationMode.LanTextOnly) {
        Write-Host (
            "Packaged LAN text-only qualification passed at " +
            "$script:BaseUri/app/. Anonymous create/join/roster/text passed; " +
            "credential and media operations were NOT qualified."
        )
    }
    else {
        Write-Host (
            "Packaged local release qualification passed at " +
            "$script:BaseUri/app/, including audio and video media."
        )
    }
}

function Invoke-SerializedPackagedReleaseQualification {
    # The first read discovers the manager-owned state root and Compose project.
    # It is non-mutating and is repeated after taking the exact manager lock.
    Assert-SealedReleaseIsRunning
    $discoveredStateRoot = $script:QualificationStateRoot
    $discoveredProject = $script:SealedReleaseProjectName
    $operationLock = Enter-QualificationOperationLock `
        -StateRoot $discoveredStateRoot `
        -ComposeProject $discoveredProject
    try {
        Assert-SealedReleaseIsRunning
        Assert-Condition `
            -Condition (
                $script:QualificationStateRoot -ceq $discoveredStateRoot -and
                $script:SealedReleaseProjectName -ceq $discoveredProject
            ) `
            -Message (
                "The local-release state or Compose project changed while " +
                "qualification acquired its operation lock"
            )
        $lockedReceiptPath = $script:SealedReleaseReceiptPath
        $lockedImageId = $script:SealedReleaseImageId

        Invoke-PackagedReleaseQualification

        # Re-run the manager's receipt, image, topology, forwarder, and health
        # proof while the lock is still held, then bind the result to the exact
        # receipt and image that were selected before browser work began.
        Assert-SealedReleaseIsRunning
        Assert-Condition `
            -Condition (
                $script:SealedReleaseReceiptPath -ceq $lockedReceiptPath -and
                $script:SealedReleaseImageId -ceq $lockedImageId
            ) `
            -Message (
                "The retained release receipt or image changed during " +
                "qualification"
            )
        Write-QualificationSuccess
    }
    finally {
        Exit-QualificationOperationLock -Lock $operationLock
    }
}

function New-QualificationReleaseContextSelfTestFixture {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$CandidateName,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$RevisionCharacter,
        [Parameter(Mandatory)][string]$ImageCharacter,
        [switch]$WithoutQualificationService
    )

    $candidateDirectory =
        Join-Path (Join-Path $StateRoot "history") $CandidateName
    New-Item `
        -ItemType Directory `
        -Path $candidateDirectory `
        -Force | Out-Null
    $receiptPath = Join-Path $candidateDirectory "deployment.json"
    $environmentFile = Join-Path $candidateDirectory "release.env"
    $composeSourcePath = Join-Path $candidateDirectory "compose.source.yaml"
    $revision = $RevisionCharacter * 40
    $imageReference = "localhost/k-comms:selftest-$CandidateName"
    $imageId = "sha256:" + ($ImageCharacter * 64)
    [IO.File]::WriteAllText(
        $environmentFile,
        (
            "K_COMMS_RELEASE_PROJECT=$ProjectName`n" +
            "K_COMMS_RELEASE_IMAGE=$imageReference`n" +
            "K_COMMS_RELEASE_REVISION=$revision`n" +
            "PUBLIC_APP_URL=http://127.0.0.1:4188`n"
        ),
        [Text.UTF8Encoding]::new($false)
    )
    $composeText =
        if ($WithoutQualificationService) {
            (
                "services:`n  app:`n    image: $imageReference`n" +
                "    environment:`n" +
                "      SELFTEST_REFERENCED: `${SELFTEST_REFERENCED:-}`n"
            )
        }
        else {
            (
                "services:`n  qualification:`n" +
                "    image: $imageReference`n" +
                "  app:`n    image: $imageReference`n" +
                "    environment:`n" +
                "      SELFTEST_REFERENCED: `${SELFTEST_REFERENCED:-}`n"
            )
        }
    [IO.File]::WriteAllText(
        $composeSourcePath,
        $composeText,
        [Text.UTF8Encoding]::new($false)
    )
    $environmentSha256 =
        Get-QualificationFileSha256 -Path $environmentFile
    $composeSourceSha256 =
        Get-QualificationFileSha256 -Path $composeSourcePath
    $receipt = [ordered]@{
        schemaVersion = 5
        receiptPath = $receiptPath
        projectName = $ProjectName
        revision = $revision
        imageReference = $imageReference
        imageId = $imageId
        environmentFile = $environmentFile
        environmentSha256 = $environmentSha256
        composeSourcePath = $composeSourcePath
        composeSourceSha256 = $composeSourceSha256
    }
    [IO.File]::WriteAllText(
        $receiptPath,
        ($receipt | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false)
    )
    Resolve-QualificationReleaseContext `
        -ReceiptPath $receiptPath `
        -StateRoot $StateRoot
}

function Assert-QualificationLockAndStateSelfTest {
    $stateRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "k-comms-qualification-selftest-$([Guid]::NewGuid().ToString('N'))"
    $project = "k-comms-qualification-selftest-$([Guid]::NewGuid().ToString('N'))"
    $firstLock = $null
    try {
        $firstCandidate = Join-Path $stateRoot "history\candidate-a"
        $secondCandidate = Join-Path $stateRoot "history\candidate-b"
        New-Item -ItemType Directory -Path $firstCandidate -Force | Out-Null
        New-Item -ItemType Directory -Path $secondCandidate -Force | Out-Null
        $firstReceipt = Join-Path $firstCandidate "deployment.json"
        $secondReceipt = Join-Path $secondCandidate "deployment.json"

        $firstResolved =
            Resolve-QualificationStateRoot -ReceiptPath $firstReceipt
        $secondResolved =
            Resolve-QualificationStateRoot -ReceiptPath $secondReceipt
        Assert-Condition `
            -Condition (
                $firstResolved -ceq [IO.Path]::GetFullPath($stateRoot) -and
                $secondResolved -ceq $firstResolved -and
                (Join-Path $firstResolved "qualification-cleanup.json") -ceq
                    (Join-Path $secondResolved "qualification-cleanup.json")
            ) `
            -Message (
                "Self-test did not retain cleanup recovery across a receipt switch"
            )

        $originContext =
            New-QualificationReleaseContextSelfTestFixture `
                -StateRoot $stateRoot `
                -CandidateName "candidate-a" `
                -ProjectName $project `
                -RevisionCharacter "a" `
                -ImageCharacter "b"
        $currentContext =
            New-QualificationReleaseContextSelfTestFixture `
                -StateRoot $stateRoot `
                -CandidateName "candidate-b" `
                -ProjectName $project `
                -RevisionCharacter "c" `
                -ImageCharacter "d" `
                -WithoutQualificationService
        $cleanupReceiptPath =
            Join-Path $stateRoot "qualification-cleanup.json"
        $qualificationId = "e" * 32
        $appContainerName =
            Get-QualificationAppContainerName `
                -QualificationId $qualificationId
        $appNonce = "f" * 32
        $appHostPort = 49152
        $appOrigin = "http://127.0.0.1:$appHostPort"
        $appTrustedProxyCidr = "10.89.20.1/32"
        $clientAddress =
            Get-QualificationClientAddress `
                -QualificationId $qualificationId
        $publicAppUrl = "http://127.0.0.1:4188"
        $composeEnvironmentNames =
            Get-QualificationComposeEnvironmentNames `
                -ReleaseContext $originContext
        Assert-Condition `
            -Condition (
                $composeEnvironmentNames -is
                    [Collections.Generic.HashSet[string]] -and
                $composeEnvironmentNames.Contains("SELFTEST_REFERENCED") -and
                $composeEnvironmentNames.Add("SELFTEST_OVERRIDE")
            ) `
            -Message (
                "Self-test sealed Compose environment names were enumerated " +
                "or could not accept an override"
            )
        Write-QualificationCleanupReceipt `
            -ReleaseContext $originContext `
            -QualificationId $qualificationId `
            -AppContainerName $appContainerName `
            -AppNonce $appNonce `
            -AppHostPort $appHostPort `
            -AppOrigin $appOrigin `
            -AppTrustedProxyCidr $appTrustedProxyCidr `
            -ClientAddress $clientAddress `
            -PublicAppUrl $publicAppUrl `
            -CleanupReceiptPath $cleanupReceiptPath
        $cleanupText =
            Get-Content -Raw -LiteralPath $cleanupReceiptPath
        Assert-Condition `
            -Condition (
                $cleanupText -notmatch
                    "(?i)password|secret_key_base|database_url" -and
                $cleanupText -notmatch [Regex]::Escape(
                    $currentContext.ReceiptPath
                )
            ) `
            -Message (
                "Self-test cleanup receipt retained secrets or current-release " +
                "identity"
            )
        $recovery = Resolve-QualificationCleanupReceipt `
            -CleanupReceiptPath $cleanupReceiptPath `
            -StateRoot $stateRoot `
            -ExpectedProjectName $project
        Assert-Condition `
            -Condition (
                $recovery.SchemaVersion -eq 3 -and
                $recovery.QualificationId -ceq $qualificationId -and
                $recovery.TenantSlug -ceq
                    "k-comms-qualification-$qualificationId" -and
                $recovery.AppContainerName -ceq $appContainerName -and
                $recovery.AppNonce -ceq $appNonce -and
                $recovery.AppHostPort -eq $appHostPort -and
                $recovery.AppOrigin -ceq $appOrigin -and
                $recovery.AppTrustedProxyCidr -ceq
                    $appTrustedProxyCidr -and
                $recovery.ClientAddress -ceq $clientAddress -and
                $recovery.PublicAppUrl -ceq $publicAppUrl -and
                $recovery.ReleaseContext.ReceiptPath -ceq
                    $originContext.ReceiptPath -and
                $recovery.ReleaseContext.ComposeSourcePath -ceq
                    $originContext.ComposeSourcePath -and
                $recovery.ReleaseContext.ImageId -ceq
                    $originContext.ImageId -and
                $recovery.ReleaseContext.ReceiptPath -cne
                    $currentContext.ReceiptPath
            ) `
            -Message (
                "Self-test stale cleanup did not remain bound to the " +
                "originating retained release"
            )

        $fakeLabels = [ordered]@{
            "com.docker.compose.project" = $originContext.ProjectName
            "com.docker.compose.service" = "app"
            "com.docker.compose.oneoff" = "True"
            "com.docker.compose.project.config_files" =
                $originContext.ComposeSourcePath
            "com.docker.compose.project.environment_file" =
                $originContext.EnvironmentFile
            "com.k-comms.qualification.app" = "true"
            "com.k-comms.qualification.id" = $qualificationId
            "com.k-comms.qualification.nonce" = $appNonce
            "com.k-comms.qualification.receipt-sha256" =
                $originContext.ReceiptSha256
            "com.k-comms.qualification.environment-sha256" =
                $originContext.EnvironmentSha256
            "com.k-comms.qualification.compose-sha256" =
                $originContext.ComposeSourceSha256
            "com.k-comms.qualification.revision" =
                $originContext.Revision
            "org.opencontainers.image.revision" =
                $originContext.Revision
        }
        $fakeInspection = [PSCustomObject]@{
            Name = "/$appContainerName"
            Id = "1" * 64
            Image = "sha256:$($originContext.ImageId)"
            EffectiveCaps = @()
            Config = [PSCustomObject]@{
                Image = $originContext.ImageReference
                User = "10001:10001"
                Labels = [PSCustomObject]$fakeLabels
                Env = @(
                    "K_COMMS_ROLE=edge",
                    "K_COMMS_RUNTIME_PURPOSE=application",
                    "K_COMMS_LOCAL_RELEASE=true",
                    "ALLOW_BOOTSTRAP=false",
                    (
                        "INSTANT_ROOM_TENANT_SLUG=" +
                        "k-comms-qualification-$qualificationId"
                    ),
                    "PUBLIC_APP_URL=$publicAppUrl",
                    "CORS_ORIGINS=$appOrigin",
                    "TRUSTED_PROXY_CIDRS=$appTrustedProxyCidr",
                    "K_COMMS_QUALIFICATION_APP_ORIGIN=$appOrigin",
                    (
                        "K_COMMS_QUALIFICATION_APP_CONFIRMATION=" +
                        "local-release-qualification-app-v1"
                    )
                )
            }
            NetworkSettings = [PSCustomObject]@{
                Ports = [PSCustomObject]@{
                    "4000/tcp" = @(
                        [PSCustomObject]@{
                            HostIp = "127.0.0.1"
                            HostPort = [string]$appHostPort
                        }
                    )
                }
            }
            HostConfig = [PSCustomObject]@{
                ReadonlyRootfs = $true
                SecurityOpt = @("no-new-privileges")
                Tmpfs = [PSCustomObject]@{
                    "/tmp" = "rw,nosuid,nodev,noexec"
                }
                RestartPolicy = [PSCustomObject]@{Name = "no"}
            }
            State = [PSCustomObject]@{
                Running = $true
                Health = [PSCustomObject]@{Status = "healthy"}
            }
        }
        Assert-QualificationAppContainerIdentity `
            -Inspection $fakeInspection `
            -CleanupContext $recovery
        $decoyInspection =
            ($fakeInspection | ConvertTo-Json -Depth 12) |
                ConvertFrom-Json
        $decoyInspection.Config.Labels.PSObject.Properties[
            "com.k-comms.qualification.nonce"
        ].Value = "0" * 32
        $decoyRejected = $false
        try {
            Assert-QualificationAppContainerIdentity `
                -Inspection $decoyInspection `
                -CleanupContext $recovery
        }
        catch {
            $decoyRejected =
                $_.Exception.Message -clike "*qualification.nonce*"
        }
        Assert-Condition `
            -Condition $decoyRejected `
            -Message (
                "Self-test allowed a same-name decoy qualification app " +
                "container"
            )

        $switchedMarker = $cleanupText | ConvertFrom-Json
        $switchedMarker.receiptPath = $currentContext.ReceiptPath
        [IO.File]::WriteAllText(
            $cleanupReceiptPath,
            ($switchedMarker | ConvertTo-Json -Depth 4),
            [Text.UTF8Encoding]::new($false)
        )
        $switchedReceiptRejected = $false
        try {
            $null = Resolve-QualificationCleanupReceipt `
                -CleanupReceiptPath $cleanupReceiptPath `
                -StateRoot $stateRoot `
                -ExpectedProjectName $project
        }
        catch {
            $switchedReceiptRejected = $true
        }
        Assert-Condition `
            -Condition $switchedReceiptRejected `
            -Message (
                "Self-test accepted a cleanup marker switched to the current " +
                "receipt"
            )
        [IO.File]::WriteAllText(
            $cleanupReceiptPath,
            $cleanupText,
            [Text.UTF8Encoding]::new($false)
        )

        $originEnvironmentBytes =
            [IO.File]::ReadAllBytes($originContext.EnvironmentFile)
        try {
            [IO.File]::AppendAllText(
                $originContext.EnvironmentFile,
                "TAMPERED=true`n",
                [Text.UTF8Encoding]::new($false)
            )
            $tamperedEnvironmentRejected = $false
            try {
                $null = Resolve-QualificationCleanupReceipt `
                    -CleanupReceiptPath $cleanupReceiptPath `
                    -StateRoot $stateRoot `
                    -ExpectedProjectName $project
            }
            catch {
                $tamperedEnvironmentRejected = $true
            }
            Assert-Condition `
                -Condition $tamperedEnvironmentRejected `
                -Message (
                    "Self-test accepted a tampered originating release " +
                    "environment"
                )
        }
        finally {
            [IO.File]::WriteAllBytes(
                $originContext.EnvironmentFile,
                $originEnvironmentBytes
            )
        }

        $extraPropertyMarker = $cleanupText | ConvertFrom-Json
        $extraPropertyMarker |
            Add-Member -NotePropertyName "password" -NotePropertyValue "forbidden"
        [IO.File]::WriteAllText(
            $cleanupReceiptPath,
            ($extraPropertyMarker | ConvertTo-Json -Depth 4),
            [Text.UTF8Encoding]::new($false)
        )
        $extraPropertyRejected = $false
        try {
            $null = Resolve-QualificationCleanupReceipt `
                -CleanupReceiptPath $cleanupReceiptPath `
                -StateRoot $stateRoot `
                -ExpectedProjectName $project
        }
        catch {
            $extraPropertyRejected = $true
        }
        Assert-Condition `
            -Condition $extraPropertyRejected `
            -Message (
                "Self-test accepted an extra cleanup marker property"
            )
        [IO.File]::WriteAllText(
            $cleanupReceiptPath,
            $cleanupText,
            [Text.UTF8Encoding]::new($false)
        )

        $recoveryOrder = [Collections.Generic.List[string]]::new()
        $appCleanupAction = {
            param($context)
            Assert-Condition `
                -Condition (
                    $context.AppContainerName -ceq $appContainerName
                ) `
                -Message "Self-test crash recovery lost app identity"
            $recoveryOrder.Add("app")
        }.GetNewClosure()
        $tenantCleanupAction = {
            param($context)
            Assert-Condition `
                -Condition (
                    $context.QualificationId -ceq $qualificationId
                ) `
                -Message "Self-test crash recovery lost tenant identity"
            $recoveryOrder.Add("tenant")
        }.GetNewClosure()
        Recover-StaleLiveQualificationResources `
            -CleanupReceiptPath $cleanupReceiptPath `
            -StateRoot $stateRoot `
            -ExpectedProjectName $project `
            -AppCleanupAction $appCleanupAction `
            -TenantCleanupAction $tenantCleanupAction
        Assert-Condition `
            -Condition (
                $recoveryOrder.Count -eq 2 -and
                $recoveryOrder[0] -ceq "app" -and
                $recoveryOrder[1] -ceq "tenant" -and
                -not (Test-Path -LiteralPath $cleanupReceiptPath)
            ) `
            -Message (
                "Self-test crash recovery did not remove app, then tenant, " +
                "then marker"
            )

        $legacyMarker = $cleanupText | ConvertFrom-Json
        $legacyMarker.schemaVersion = 2
        foreach ($property in @(
            "tenantSlug",
            "qualificationAppContainerName",
            "qualificationAppNonce",
            "qualificationAppHostPort",
            "qualificationAppOrigin",
            "qualificationAppTrustedProxyCidr",
            "qualificationClientAddress",
            "publicAppUrl"
        )) {
            $legacyMarker.PSObject.Properties.Remove($property)
        }
        [IO.File]::WriteAllText(
            $cleanupReceiptPath,
            ($legacyMarker | ConvertTo-Json -Depth 4),
            [Text.UTF8Encoding]::new($false)
        )
        $legacyRecoveryOrder =
            [Collections.Generic.List[string]]::new()
        $legacyAppCleanupAction = {
            throw "Self-test schema-v2 recovery attempted app cleanup"
        }.GetNewClosure()
        $legacyTenantCleanupAction = {
            param($context)
            Assert-Condition `
                -Condition ($context.SchemaVersion -eq 2) `
                -Message "Self-test schema-v2 recovery lost legacy schema"
            $legacyRecoveryOrder.Add("tenant")
        }.GetNewClosure()
        Recover-StaleLiveQualificationResources `
            -CleanupReceiptPath $cleanupReceiptPath `
            -StateRoot $stateRoot `
            -ExpectedProjectName $project `
            -AppCleanupAction $legacyAppCleanupAction `
            -TenantCleanupAction $legacyTenantCleanupAction
        Assert-Condition `
            -Condition (
                $legacyRecoveryOrder.Count -eq 1 -and
                $legacyRecoveryOrder[0] -ceq "tenant" -and
                -not (Test-Path -LiteralPath $cleanupReceiptPath)
            ) `
            -Message (
                "Self-test did not preserve schema-v2 tenant-only recovery"
            )

        $randomAppPort = New-QualificationAppHostPort
        Assert-Condition `
            -Condition (
                $randomAppPort -ge 1024 -and
                $randomAppPort -le 65535 -and
                $randomAppPort -ne 4188
            ) `
            -Message (
                "Self-test did not allocate a disposable high loopback port"
            )

        $firstLock = Enter-QualificationOperationLock `
            -StateRoot $stateRoot `
            -ComposeProject $project
        $concurrentBlocked = $false
        try {
            $secondLock = Enter-QualificationOperationLock `
                -StateRoot $stateRoot `
                -ComposeProject $project
            Exit-QualificationOperationLock -Lock $secondLock
        }
        catch {
            $concurrentBlocked = $true
        }
        Assert-Condition `
            -Condition $concurrentBlocked `
            -Message "Self-test allowed concurrent qualification operations"
    }
    finally {
        if ($firstLock) {
            Exit-QualificationOperationLock -Lock $firstLock
        }
        if (Test-Path -LiteralPath $stateRoot) {
            Remove-Item -LiteralPath $stateRoot -Recurse -Force
        }
    }
}

function Invoke-SelfTest {
    Assert-QualificationLockAndStateSelfTest
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
            bootstrap = $false
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
    Assert-SecureTransportRequiredPayload `
        -StatusCode 426 `
        -Payload ([PSCustomObject]@{
            error = [PSCustomObject]@{
                code = "secure_transport_required"
                detail = "This operation requires a trusted HTTPS connection"
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
        Invoke-SerializedPackagedReleaseQualification
    }
}
catch {
    Write-Error "Packaged local release qualification failed: $($_.Exception.Message)"
    exit 1
}

#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet(
        "Deploy",
        "Start",
        "Rollback",
        "Status",
        "Stop",
        "Validate",
        "HealthCheck",
        "Supervise"
    )]
    [string]$Action = "Deploy",
    [string]$StateRoot = "",
    [ValidatePattern("^[a-z0-9][a-z0-9_-]*$")]
    [string]$ProjectName = "k-comms-release",
    [string]$BindAddress = "127.0.0.1",
    [switch]$AllowPublicNetworkProfile,
    [ValidateSet("auto", "cloudflare_trusted_edge")]
    [string]$ExposureProfile = "auto",
    [string]$AppHostname = "",
    [string]$MediaHostname = "",
    [string]$ObjectHostname = "",
    [string]$MediaNodeAddress = "",
    [string]$TrustedEdgeConfirmation = "",
    [string]$ExpectedReceiptPath = "",
    [string]$ExpectedCandidateId = "",
    [string]$ExpectedForwarderConfigSha256 = "",
    [ValidateRange(1024, 65535)]
    [int]$AppPort = 4188,
    [ValidateRange(1024, 65535)]
    [int]$MinioPort = 5900,
    [ValidateRange(1024, 65535)]
    [int]$MinioConsolePort = 5901,
    [ValidateRange(1024, 65535)]
    [int]$LiveKitSignalPort = 7980,
    [ValidateRange(1024, 65535)]
    [int]$LiveKitTcpPort = 7981,
    [ValidateRange(1024, 65535)]
    [int]$LiveKitUdpPort = 7982,
    [ValidateRange(30, 900)]
    [int]$ReadyTimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# Podman delegates Compose to an external provider on Windows. Its provider
# banner is written to stderr and otherwise contaminates captured machine output
# such as `compose ps --quiet`.
$env:PODMAN_COMPOSE_WARNING_LOGS = "false"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$composeFile = Join-Path $repositoryRoot "deploy\compose.local-release.yaml"
$lanForwarderSourceRelativePath = "scripts\lan_release_forwarder.mjs"
$podmanBindAddress = "127.0.0.1"
$cloudflareTrustedEdgeProfile = "cloudflare_trusted_edge"
$cloudflareTrustedEdgeConfirmation = "cloudflare-tunnel-v1"
$supportedReceiptSchemaVersion = 6
$lanForwarderSupervisorKind = "windows-scheduled-task-poll-v1"
$lanForwarderSupervisorIntervalSeconds = 60
$lanForwarderSupervisorStartDelaySeconds = 15
$lanForwarderSupervisorRepetitionDurationDays = 3650
$lanForwarderSupervisorNextRunGraceSeconds = 120
$retainedSupervisorManagerName = "manage_local_release.supervisor.ps1"
$currentPointerPath = $null
$stateOwnershipMarkerName = ".k-comms-local-release-state-v1.json"
$customStateRootRequested = -not [string]::IsNullOrWhiteSpace($StateRoot)

if (-not $StateRoot) {
    if (-not $env:LOCALAPPDATA) {
        throw "LOCALAPPDATA is required when -StateRoot is not provided"
    }
    $StateRoot = Join-Path $env:LOCALAPPDATA "K-Comms\local-release"
}

$StateRoot = [IO.Path]::GetFullPath($StateRoot)
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar
if (($StateRoot.TrimEnd("\", "/") + [IO.Path]::DirectorySeparatorChar).StartsWith(
        $repositoryPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "The local-release state directory must remain outside the repository because it contains secrets"
}
$currentPointerPath = Join-Path $StateRoot "current.json"

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [string]$WorkingDirectory = $repositoryRoot,
        [switch]$EchoOutput,
        [switch]$AllowFailure
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        Push-Location $WorkingDirectory
        try {
            $lines = & $FilePath @Arguments 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    $output = ($lines | ForEach-Object { "$_" }) -join [Environment]::NewLine
    if ($EchoOutput -and $output) {
        Write-Host $output
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $summary = if ($output) { $output } else { "no command output" }
        throw "$FilePath failed with exit code $exitCode`n$summary"
    }

    [PSCustomObject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function Get-ComposeInterpolationNames {
    param([Parameter(Mandatory)][string]$ComposePath)

    if (-not (Test-Path -LiteralPath $ComposePath -PathType Leaf)) {
        throw "Compose source is missing: $ComposePath"
    }
    $names = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $source = Get-Content -LiteralPath $ComposePath -Raw
    foreach ($match in [Regex]::Matches(
        $source,
        '\$\{(?<name>[A-Za-z_][A-Za-z0-9_]*)[^}]*\}'
    )) {
        $null = $names.Add($match.Groups["name"].Value)
    }
    return @($names | Sort-Object)
}

function Invoke-WithSealedComposeEnvironment {
    param(
        [Parameter(Mandatory)][string]$EnvironmentFile,
        [Parameter(Mandatory)][string]$ComposePath,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$SealPublicBootstrap
    )

    if (-not (Test-Path -LiteralPath $EnvironmentFile -PathType Leaf)) {
        throw "Compose environment file is missing: $EnvironmentFile"
    }
    $retainedEnvironment = Read-EnvironmentFile -Path $EnvironmentFile
    $names = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in Get-ComposeInterpolationNames -ComposePath $ComposePath) {
        $null = $names.Add($name)
    }
    foreach ($name in $retainedEnvironment.Keys) {
        if ([string]$name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Compose environment contains invalid variable name '$name'"
        }
        $null = $names.Add([string]$name)
    }
    $null = $names.Add("K_COMMS_PODMAN_BIND_ADDRESS")
    $null = $names.Add("ALLOW_BOOTSTRAP")

    $processEnvironment = [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    )
    $processEnvironmentNames =
        [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($existingName in $processEnvironment.Keys) {
        $processEnvironmentNames[[string]$existingName] =
            [string]$existingName
    }
    $snapshot = [ordered]@{}
    foreach ($name in $names) {
        $originalName =
            if ($processEnvironmentNames.ContainsKey($name)) {
                [string]$processEnvironmentNames[$name]
            }
            else {
                [string]$name
            }
        $snapshot[$name] = [PSCustomObject]@{
            Exists = $processEnvironmentNames.ContainsKey($name)
            Name = $originalName
            Value = [Environment]::GetEnvironmentVariable(
                $originalName,
                [EnvironmentVariableTarget]::Process
            )
        }
    }

    try {
        foreach ($name in $names) {
            $value =
                if ($retainedEnvironment.Contains($name)) {
                    [string]$retainedEnvironment[$name]
                }
                else {
                    $null
                }
            [Environment]::SetEnvironmentVariable(
                $name,
                $value,
                [EnvironmentVariableTarget]::Process
            )
        }
        [Environment]::SetEnvironmentVariable(
            "K_COMMS_PODMAN_BIND_ADDRESS",
            $podmanBindAddress,
            [EnvironmentVariableTarget]::Process
        )
        if ($SealPublicBootstrap) {
            [Environment]::SetEnvironmentVariable(
                "ALLOW_BOOTSTRAP",
                "false",
                [EnvironmentVariableTarget]::Process
            )
        }
        & $Action
    }
    finally {
        foreach ($name in $names) {
            $prior = $snapshot[$name]
            [Environment]::SetEnvironmentVariable(
                $(if ($prior.Exists) { [string]$prior.Name } else { $name }),
                $(if ($prior.Exists) { [string]$prior.Value } else { $null }),
                [EnvironmentVariableTarget]::Process
            )
        }
    }
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory)]
        [string]$EnvironmentFile,
        [Parameter(Mandatory)]
        [string]$ComposeProject,
        [string]$ComposePath = $composeFile,
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$EchoOutput,
        [switch]$AllowFailure,
        [switch]$SealPublicBootstrap
    )

    $composeArguments = @(
        "compose",
        "--project-name", $ComposeProject,
        "--env-file", $EnvironmentFile,
        "-f", $ComposePath
    ) + $Arguments

    Invoke-WithSealedComposeEnvironment `
        -EnvironmentFile $EnvironmentFile `
        -ComposePath $ComposePath `
        -SealPublicBootstrap:$SealPublicBootstrap `
        -Action {
            Invoke-NativeCommand `
                -FilePath "podman" `
                -Arguments $composeArguments `
                -EchoOutput:$EchoOutput `
                -AllowFailure:$AllowFailure
        }
}

function Assert-LiveKitImageFlags {
    $image = "docker.io/livekit/livekit-server:v1.12.0@sha256:b1281e66e35e8f9749ffbcf0fe6ab4d40d1438aa00f36c2ea7e6975e5e261e2e"
    $help = Invoke-NativeCommand `
        -FilePath "podman" `
        -Arguments @("run", "--rm", $image, "help-verbose")

    foreach ($flag in @("--rtc.tcp_port", "--udp-port")) {
        if ($help.Output -notmatch [Regex]::Escape($flag)) {
            throw "Pinned LiveKit image does not support required local-release flag $flag"
        }
    }
}

function Protect-StateDirectory {
    param([Parameter(Mandatory)][string]$Path)

    # Re-check the complete custom path immediately before changing ACLs. The
    # directory may have been created since the initial validation, and an
    # ancestor must not have been replaced with a junction in that interval.
    Assert-SafeStateRootPath -Path $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "The local-release state directory does not exist: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The local-release state directory must not be a reparse point: $Path"
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Invoke-NativeCommand `
        -FilePath "icacls.exe" `
        -Arguments @(
            $Path,
            "/inheritance:r",
            "/grant:r",
            "*${sid}:(OI)(CI)F"
        ) | Out-Null
}

function Get-StateOwnershipMarkerPath {
    param([Parameter(Mandatory)][string]$Path)
    Join-Path $Path $stateOwnershipMarkerName
}

function Assert-NoReparsePointAncestors {
    param([Parameter(Mandatory)][string]$Path)

    $current = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Path))
    while ($null -ne $current) {
        $attributes = $null
        try {
            # File.GetAttributes observes the path entry itself, including a
            # dangling link, instead of relying on DirectoryInfo.Exists (which
            # can report false when a reparse target is unavailable).
            $attributes = [IO.File]::GetAttributes($current.FullName)
        }
        catch {
            # PowerShell 5.1 wraps static .NET invocation failures in a
            # MethodInvocationException, so inspect the inner cause explicitly.
            $cause =
                if ($_.Exception.InnerException) {
                    $_.Exception.InnerException
                }
                else {
                    $_.Exception
                }
            if (
                $cause -is [IO.FileNotFoundException] -or
                $cause -is [IO.DirectoryNotFoundException]
            ) {
                $attributes = $null
            }
            else {
                throw (
                    "Could not safely inspect custom local-release state-root ancestor " +
                    "$($current.FullName): $($cause.Message)"
                )
            }
        }
        if (
            $null -ne $attributes -and
            ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        ) {
            throw (
                "A custom local-release state root must not traverse a reparse point " +
                "or junction: $($current.FullName)"
            )
        }
        $current = $current.Parent
    }
}

function Assert-SafeStateRootPath {
    param([Parameter(Mandatory)][string]$Path)

    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $dangerousPaths = @(
        [IO.Path]::GetPathRoot($canonicalPath),
        $env:USERPROFILE,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:TEMP,
        $repositoryRoot
    )
    foreach ($dangerousPath in $dangerousPaths) {
        if (-not $dangerousPath) {
            continue
        }
        $candidate = [IO.Path]::GetFullPath($dangerousPath).TrimEnd("\", "/")
        if ($canonicalPath.Equals($candidate, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to use a dangerous local-release state root: $Path"
        }
    }

    $statePrefix = $canonicalPath + [IO.Path]::DirectorySeparatorChar
    $canonicalRepository = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd("\", "/")
    if ($canonicalRepository.StartsWith($statePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The local-release state root must not contain the repository: $Path"
    }

    if ($customStateRootRequested) {
        Assert-NoReparsePointAncestors -Path $canonicalPath
    }
}

function Assert-OwnedStateDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedProject
    )

    Assert-SafeStateRootPath -Path $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "The local-release state directory does not exist: $Path"
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to use a reparse-point local-release state directory: $Path"
    }

    $markerPath = Get-StateOwnershipMarkerPath -Path $Path
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw (
            "Refusing to adopt or change ACLs on an existing unowned directory: $Path. " +
            "Choose a new empty path so K-Comms can create its ownership marker."
        )
    }

    $markerItem = Get-Item -LiteralPath $markerPath -Force
    if (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The local-release state ownership marker must be a regular file: $markerPath"
    }

    try {
        $marker = Read-JsonFile -Path $markerPath
    }
    catch {
        throw "The local-release state ownership marker is invalid: $markerPath"
    }

    $requiredProperties = @("schemaVersion", "kind", "canonicalPath", "projectName")
    foreach ($property in $requiredProperties) {
        if (-not $marker.PSObject.Properties[$property]) {
            throw "The local-release state ownership marker is missing $property`: $markerPath"
        }
    }

    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $markedPath = [IO.Path]::GetFullPath([string]$marker.canonicalPath).TrimEnd("\", "/")
    if (
        [int]$marker.schemaVersion -ne 1 -or
        [string]$marker.kind -ne "k-comms-local-release-state" -or
        -not $markedPath.Equals($canonicalPath, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$marker.projectName -ne $ExpectedProject
    ) {
        throw "The local-release state ownership marker does not match this path and project"
    }
}

function Initialize-OwnedStateDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedProject
    )

    Assert-SafeStateRootPath -Path $Path
    if (Test-Path -LiteralPath $Path) {
        Assert-OwnedStateDirectory -Path $Path -ExpectedProject $ExpectedProject
        Protect-StateDirectory -Path $Path
        return
    }

    New-Item -ItemType Directory -Path $Path | Out-Null
    # Validate again after creation and before writing the ownership marker.
    # This closes the gap where a custom ancestor could be replaced while the
    # previously non-existent state path was being created.
    Assert-SafeStateRootPath -Path $Path
    $markerPath = Get-StateOwnershipMarkerPath -Path $Path
    Write-JsonAtomic -Path $markerPath -Value ([ordered]@{
        schemaVersion = 1
        kind = "k-comms-local-release-state"
        canonicalPath = [IO.Path]::GetFullPath($Path)
        projectName = $ExpectedProject
        createdAt = [DateTime]::UtcNow.ToString("o")
    })
    Protect-StateDirectory -Path $Path
    Assert-OwnedStateDirectory -Path $Path -ExpectedProject $ExpectedProject
}

function Enter-ReleaseOperationLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ComposeProject
    )

    Assert-OwnedStateDirectory -Path $Path -ExpectedProject $ComposeProject
    $mutex = New-Object Threading.Mutex($false, "Local\KComms.LocalRelease.$ComposeProject")
    $mutexOwned = $false
    try {
        try {
            $mutexOwned = $mutex.WaitOne(0)
        }
        catch [Threading.AbandonedMutexException] {
            $mutexOwned = $true
        }
        if (-not $mutexOwned) {
            throw "Another local-release operation is already using Compose project $ComposeProject"
        }

        $lockPath = Join-Path $Path "operation.lock"
        try {
            $stream = [IO.File]::Open(
                $lockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        }
        catch {
            throw "Another local-release operation is already using state directory $Path"
        }

        $payload = [Text.Encoding]::UTF8.GetBytes(
            "pid=$PID`nproject=$ComposeProject`nstarted=$([DateTime]::UtcNow.ToString('o'))`n"
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

function Exit-ReleaseOperationLock {
    param([Parameter(Mandatory)]$Lock)

    if ($Lock.Stream) {
        $Lock.Stream.Dispose()
    }
    if ($Lock.MutexOwned) {
        $Lock.Mutex.ReleaseMutex()
    }
    $Lock.Mutex.Dispose()
}

function New-UrlSafeSecret {
    param([ValidateRange(24, 128)][int]$ByteCount = 48)

    $bytes = New-Object byte[] $ByteCount
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
    }
    finally {
        $random.Dispose()
    }
    [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function New-EncryptionKey {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
    }
    finally {
        $random.Dispose()
    }
    [Convert]::ToBase64String($bytes)
}

function Test-EncryptionKey {
    param([AllowEmptyString()][string]$Value)

    if ([Text.Encoding]::UTF8.GetByteCount($Value) -eq 32) {
        return $true
    }

    try {
        $decoded = [Convert]::FromBase64String($Value)
        $decoded.Length -eq 32
    }
    catch {
        $false
    }
}

function Resolve-StableEncryptionKey {
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return New-EncryptionKey
    }
    if (Test-EncryptionKey -Value $Value) {
        return $Value
    }

    # Releases before instant-room qualification generated these two values
    # as 48 random bytes encoded with unpadded Base64URL. The application has
    # never accepted that 64-character representation as an AES-256 key, so it
    # cannot have produced decryptable ciphertext and is safe to replace.
    if ($Value -match "^[A-Za-z0-9_-]{64}$") {
        return New-EncryptionKey
    }

    throw (
        "Retained $Name is invalid and does not match the known legacy " +
        "local-release format; restore the correct 32-byte key before deployment"
    )
}

function Read-EnvironmentFile {
    param([Parameter(Mandatory)][string]$Path)

    $values = [ordered]@{}
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }
        $separatorIndex = $line.IndexOf("=")
        if ($separatorIndex -le 0) {
            throw "Invalid environment line in $Path"
        }
        $key = $line.Substring(0, $separatorIndex)
        $value = $line.Substring($separatorIndex + 1)
        if (
            $value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$key] = $value.Replace('\"', '"')
    }
    $values
}

function Write-EnvironmentFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Collections.IDictionary]$Values
    )

    $lines = foreach ($entry in $Values.GetEnumerator()) {
        $value = [string]$entry.Value
        if ($value.Contains("`r") -or $value.Contains("`n") -or $value.Contains("`0")) {
            throw "Environment value $($entry.Key) contains a forbidden control character"
        }
        if ($value -match '[\s#"]') {
            $escaped = $value.Replace("\", "\\").Replace('"', '\"')
            "$($entry.Key)=`"$escaped`""
        }
        else {
            "$($entry.Key)=$value"
        }
    }
    [IO.File]::WriteAllLines(
        $Path,
        [string[]]$lines,
        (New-Object Text.UTF8Encoding($false))
    )
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText(
        $temporary,
        ($Value | ConvertTo-Json -Depth 12),
        (New-Object Text.UTF8Encoding($false))
    )
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-CurrentReceipt {
    if (-not (Test-Path -LiteralPath $StateRoot)) {
        return $null
    }
    Assert-OwnedStateDirectory -Path $StateRoot -ExpectedProject $ProjectName
    if (-not (Test-Path -LiteralPath $currentPointerPath -PathType Leaf)) {
        return $null
    }
    $pointer = Read-JsonFile -Path $currentPointerPath
    if (-not (Test-Path -LiteralPath $pointer.receiptPath -PathType Leaf)) {
        throw "Current local-release receipt is missing: $($pointer.receiptPath)"
    }
    $receipt = Read-JsonFile -Path $pointer.receiptPath
    $null = Assert-SupportedReceiptSchemaVersion -Receipt $receipt
    return $receipt
}

function Assert-SupervisorBootstrapRegularPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet("Container", "Leaf")]
        [string]$PathType = "Leaf",
        [Parameter(Mandatory)][string]$Description
    )

    $canonicalPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $canonicalPath -PathType $PathType)) {
        throw "$Description is missing: $canonicalPath"
    }
    $item = Get-Item -LiteralPath $canonicalPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a reparse point: $canonicalPath"
    }
    return $canonicalPath
}

function Assert-SupervisorOwnedStateDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedProject
    )

    $canonicalPath = Assert-SupervisorBootstrapRegularPath `
        -Path $Path `
        -PathType Container `
        -Description "The receipt-bound supervisor state directory"
    Assert-NoReparsePointAncestors -Path $canonicalPath
    $markerPath = Assert-SupervisorBootstrapRegularPath `
        -Path (Join-Path $canonicalPath $stateOwnershipMarkerName) `
        -PathType Leaf `
        -Description "The receipt-bound supervisor state ownership marker"
    try {
        $marker = Read-JsonFile -Path $markerPath
    }
    catch {
        throw (
            "The receipt-bound supervisor state ownership marker is invalid: " +
            $markerPath
        )
    }
    foreach ($property in @(
        "schemaVersion",
        "kind",
        "canonicalPath",
        "projectName"
    )) {
        if (-not $marker.PSObject.Properties[$property]) {
            throw (
                "The receipt-bound supervisor state ownership marker is missing " +
                "$property`: $markerPath"
            )
        }
    }
    $markedPath =
        [IO.Path]::GetFullPath([string]$marker.canonicalPath).TrimEnd("\", "/")
    if (
        [int]$marker.schemaVersion -ne 1 -or
        [string]$marker.kind -cne "k-comms-local-release-state" -or
        -not $markedPath.Equals(
            $canonicalPath.TrimEnd("\", "/"),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        [string]$marker.projectName -cne $ExpectedProject
    ) {
        throw (
            "The receipt-bound supervisor state ownership marker does not " +
            "match this path and project"
        )
    }
    return $canonicalPath
}

function Enter-SupervisorOperationLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ComposeProject
    )

    $canonicalPath = Assert-SupervisorOwnedStateDirectory `
        -Path $Path `
        -ExpectedProject $ComposeProject
    $mutex = New-Object Threading.Mutex(
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

        try {
            $stream = [IO.File]::Open(
                (Join-Path $canonicalPath "operation.lock"),
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        }
        catch {
            throw (
                "Another local-release operation is already using state " +
                "directory $canonicalPath"
            )
        }
        $payload = [Text.Encoding]::UTF8.GetBytes(
            "pid=$PID`nproject=$ComposeProject`nstarted=$([DateTime]::UtcNow.ToString('o'))`n"
        )
        $stream.SetLength(0)
        $stream.Write($payload, 0, $payload.Length)
        $stream.Flush()
        return [PSCustomObject]@{
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

function Get-SupervisorCurrentReceipt {
    param(
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][string]$CandidateId
    )

    $canonicalStateRoot = Assert-SupervisorOwnedStateDirectory `
        -Path $StateRoot `
        -ExpectedProject $ProjectName
    $historyPath = Assert-SupervisorBootstrapRegularPath `
        -Path (Join-Path $canonicalStateRoot "history") `
        -PathType Container `
        -Description "The receipt-bound supervisor history directory"
    $candidatePath = Assert-SupervisorBootstrapRegularPath `
        -Path (Join-Path $historyPath $CandidateId) `
        -PathType Container `
        -Description "The receipt-bound supervisor candidate directory"
    $expectedReceiptPath =
        [IO.Path]::GetFullPath((Join-Path $candidatePath "deployment.json"))
    if (
        -not [IO.Path]::GetFullPath($ReceiptPath).Equals(
            $expectedReceiptPath,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw (
            "The receipt-bound supervisor receipt path is outside its exact " +
            "state history candidate"
        )
    }
    $pointerPath = Assert-SupervisorBootstrapRegularPath `
        -Path (Join-Path $canonicalStateRoot "current.json") `
        -PathType Leaf `
        -Description "The receipt-bound supervisor current pointer"
    try {
        $pointer = Read-JsonFile -Path $pointerPath
    }
    catch {
        throw "The receipt-bound supervisor current pointer is invalid"
    }
    if (
        -not $pointer.PSObject.Properties["receiptPath"] -or
        -not [IO.Path]::GetFullPath([string]$pointer.receiptPath).Equals(
            $expectedReceiptPath,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw (
            "The receipt-bound supervisor current pointer does not match its " +
            "exact expected receipt"
        )
    }
    $canonicalReceiptPath = Assert-SupervisorBootstrapRegularPath `
        -Path $expectedReceiptPath `
        -PathType Leaf `
        -Description "The receipt-bound supervisor deployment receipt"
    try {
        $receipt = Read-JsonFile -Path $canonicalReceiptPath
    }
    catch {
        throw "The receipt-bound supervisor deployment receipt is invalid"
    }
    $null = Assert-SupportedReceiptSchemaVersion -Receipt $receipt
    foreach ($comparison in @(
        @(
            "receipt path",
            [IO.Path]::GetFullPath([string]$receipt.receiptPath),
            $canonicalReceiptPath
        ),
        @("candidate identity", [string]$receipt.candidateId, $CandidateId),
        @("Compose project", [string]$receipt.projectName, $ProjectName)
    )) {
        if (
            -not [string]$comparison[1] -or
            -not ([string]$comparison[1]).Equals(
                [string]$comparison[2],
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw (
                "The receipt-bound supervisor deployment receipt has a " +
                "mismatched $($comparison[0])"
            )
        }
    }
    return $receipt
}

function Get-ReceiptSchemaVersion {
    param([Parameter(Mandatory)]$Receipt)

    $value = $null
    if ($Receipt -is [Collections.IDictionary]) {
        if ($Receipt.Contains("schemaVersion")) {
            $value = $Receipt["schemaVersion"]
        }
        else {
            return 1
        }
    }
    else {
        $schemaVersionProperty = $Receipt.PSObject.Properties["schemaVersion"]
        if (-not $schemaVersionProperty) {
            return 1
        }
        $value = $schemaVersionProperty.Value
    }
    if ($value -isnot [int] -and $value -isnot [long]) {
        throw "Local-release receipt schema version must be an integer"
    }
    return [int]$value
}

function Assert-SupportedReceiptSchemaVersion {
    param([Parameter(Mandatory)]$Receipt)

    $schemaVersion = Get-ReceiptSchemaVersion -Receipt $Receipt
    if ($schemaVersion -lt 1) {
        throw "Local-release receipt schema version must be a positive integer"
    }
    if ($schemaVersion -gt $supportedReceiptSchemaVersion) {
        throw (
            "Local-release receipt schema version $schemaVersion is newer than " +
            "this manager's supported maximum $supportedReceiptSchemaVersion"
        )
    }
    return $schemaVersion
}

function Get-ReceiptExposureProfile {
    param([Parameter(Mandatory)]$Receipt)

    $profile = [string](Get-ReceiptNetworkProperty `
        -Receipt $Receipt `
        -Name "exposureProfile" `
        -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($profile)) {
        return $profile
    }

    $exposureMode = [string](Get-ReceiptNetworkProperty `
        -Receipt $Receipt `
        -Name "exposureMode" `
        -DefaultValue "")
    if ($exposureMode -ceq $cloudflareTrustedEdgeProfile) {
        return $cloudflareTrustedEdgeProfile
    }
    if ((Get-ReceiptBindAddress -Receipt $Receipt) -ceq $podmanBindAddress) {
        return "loopback"
    }
    return "private_lan"
}

function Test-ReceiptIsCloudflareTrustedEdge {
    param([Parameter(Mandatory)]$Receipt)

    (Get-ReceiptExposureProfile -Receipt $Receipt) -ceq
        $cloudflareTrustedEdgeProfile
}

function Get-ReceiptPodmanBindAddress {
    param([Parameter(Mandatory)]$Receipt)

    $value = Get-ReceiptNetworkProperty `
        -Receipt $Receipt `
        -Name "podmanBindAddress" `
        -DefaultValue $podmanBindAddress
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        return $podmanBindAddress
    }
    return [string]$value
}

function Test-ReceiptRequiresLanForwarder {
    param([Parameter(Mandatory)]$Receipt)

    (Test-ReceiptIsCloudflareTrustedEdge -Receipt $Receipt) -or
        (Get-ReceiptBindAddress -Receipt $Receipt) -cne $podmanBindAddress
}

function Test-Rfc1918IPv4 {
    param([Parameter(Mandatory)][Net.IPAddress]$Address)

    if ($Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }
    $octets = $Address.GetAddressBytes()
    return (
        $octets[0] -eq 10 -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168)
    )
}

function Test-IPv4AssignedLocally {
    param([Parameter(Mandatory)][Net.IPAddress]$Address)

    foreach ($networkInterface in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($networkInterface.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) {
            continue
        }
        foreach ($unicast in $networkInterface.GetIPProperties().UnicastAddresses) {
            if (
                $unicast.Address.AddressFamily -eq
                    [Net.Sockets.AddressFamily]::InterNetwork -and
                $unicast.Address.Equals($Address)
            ) {
                return $true
            }
        }
    }
    return $false
}

function Test-PreferredReleaseIPAddressRecord {
    param(
        [Parameter(Mandatory)]$AddressRecord,
        [Parameter(Mandatory)][string]$ExpectedAddress
    )

    return (
        [string]$AddressRecord.IPAddress -ceq $ExpectedAddress -and
        [string]$AddressRecord.AddressState -ceq "Preferred"
    )
}

function Resolve-ReleaseBindAddress {
    param([Parameter(Mandatory)][string]$Value)

    $parsed = $null
    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        -not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork
    ) {
        throw "BindAddress must be an explicit IPv4 address"
    }

    $canonical = $parsed.ToString()
    if ($Value -cne $canonical) {
        throw "BindAddress must use the canonical dotted-decimal IPv4 form"
    }
    if ($canonical -eq "0.0.0.0") {
        throw "BindAddress must never be the wildcard address 0.0.0.0"
    }
    if ([Net.IPAddress]::IsLoopback($parsed)) {
        if ($canonical -cne "127.0.0.1") {
            throw "BindAddress loopback mode requires the canonical address 127.0.0.1"
        }
        return "127.0.0.1"
    }
    if (-not (Test-Rfc1918IPv4 -Address $parsed)) {
        throw "BindAddress must be loopback or an RFC1918 private IPv4 address"
    }
    if (-not (Test-IPv4AssignedLocally -Address $parsed)) {
        throw "BindAddress $canonical is not assigned to an active local network interface"
    }
    return $canonical
}

function Assert-ReleaseNetworkCategory {
    param(
        [Parameter(Mandatory)][string]$NetworkCategory,
        [switch]$AllowPublicNetworkProfile
    )

    if ($NetworkCategory -ceq "Private") {
        return $false
    }
    if (-not $AllowPublicNetworkProfile) {
        throw (
            "BindAddress is attached to the non-Private Windows network profile " +
            "'$NetworkCategory'. Re-run with -AllowPublicNetworkProfile only after " +
            "explicitly accepting the LAN exposure risk."
        )
    }
    return $true
}

function Resolve-ReleaseNetworkObservation {
    param(
        [Parameter(Mandatory)][string]$Value,
        [switch]$AllowPublicNetworkProfile
    )

    $resolvedBindAddress = Resolve-ReleaseBindAddress -Value $Value
    if ($resolvedBindAddress -ceq "127.0.0.1") {
        if ($AllowPublicNetworkProfile) {
            throw (
                "-AllowPublicNetworkProfile is valid only with a non-loopback " +
                "RFC1918 BindAddress"
            )
        }
        return [PSCustomObject]@{
            BindAddress = $resolvedBindAddress
            InterfaceIndex = 0
            InterfaceAlias = "Loopback"
            NetworkName = "Loopback"
            NetworkCategory = "Loopback"
            AllowPublicNetworkProfile = $false
            PublicNetworkProfileOverrideUsed = $false
        }
    }

    $addresses = @(
        Get-NetIPAddress `
            -AddressFamily IPv4 `
            -IPAddress $resolvedBindAddress `
            -ErrorAction Stop |
            Where-Object {
                Test-PreferredReleaseIPAddressRecord `
                    -AddressRecord $_ `
                    -ExpectedAddress $resolvedBindAddress
            }
    )
    if ($addresses.Count -ne 1) {
        throw (
            "BindAddress $resolvedBindAddress must be reported as Preferred on " +
            "exactly one Windows network interface"
        )
    }
    $address = $addresses[0]
    $profiles = @(
        Get-NetConnectionProfile `
            -InterfaceIndex $address.InterfaceIndex `
            -ErrorAction Stop
    )
    if ($profiles.Count -ne 1) {
        throw (
            "BindAddress $resolvedBindAddress must have exactly one observable " +
            "Windows network profile"
        )
    }
    $profile = $profiles[0]
    $category = [string]$profile.NetworkCategory
    if (
        $category -cne "Private" -and
        $category -cne "Public" -and
        $category -cne "DomainAuthenticated"
    ) {
        throw (
            "BindAddress $resolvedBindAddress has unsupported Windows network " +
            "profile category '$category'"
        )
    }
    $overrideUsed = Assert-ReleaseNetworkCategory `
        -NetworkCategory $category `
        -AllowPublicNetworkProfile:$AllowPublicNetworkProfile

    [PSCustomObject]@{
        BindAddress = $resolvedBindAddress
        InterfaceIndex = [int]$address.InterfaceIndex
        InterfaceAlias = [string]$address.InterfaceAlias
        NetworkName = [string]$profile.Name
        NetworkCategory = $category
        AllowPublicNetworkProfile = [bool]$AllowPublicNetworkProfile
        PublicNetworkProfileOverrideUsed = [bool]$overrideUsed
    }
}

function Resolve-CanonicalDnsHostname {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value -cne $Value.Trim() -or
        $Value -cne $Value.ToLowerInvariant() -or
        $Value.Length -gt 253 -or
        $Value -notmatch "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])$" -or
        $Value -notmatch "\."
    ) {
        throw "$Name must be a canonical lowercase DNS hostname"
    }
    foreach ($label in $Value.Split(".")) {
        if (
            $label.Length -lt 1 -or
            $label.Length -gt 63 -or
            $label.StartsWith("-") -or
            $label.EndsWith("-")
        ) {
            throw "$Name contains an invalid DNS label"
        }
    }
    return $Value
}

function Resolve-RequestedReleaseTopology {
    param(
        [Parameter(Mandatory)][string]$RequestedExposureProfile,
        [Parameter(Mandatory)][string]$RequestedBindAddress,
        [switch]$AllowPublicNetworkProfile
    )

    if ($RequestedExposureProfile -cne $cloudflareTrustedEdgeProfile) {
        foreach ($entry in ([ordered]@{
            AppHostname = $AppHostname
            MediaHostname = $MediaHostname
            ObjectHostname = $ObjectHostname
            MediaNodeAddress = $MediaNodeAddress
            TrustedEdgeConfirmation = $TrustedEdgeConfirmation
        }).GetEnumerator()) {
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
                throw (
                    "-$($entry.Key) is valid only with " +
                    "-ExposureProfile $cloudflareTrustedEdgeProfile"
                )
            }
        }
        $observation = Resolve-ReleaseNetworkObservation `
            -Value $RequestedBindAddress `
            -AllowPublicNetworkProfile:$AllowPublicNetworkProfile
        $appOrigin = "http://$($observation.BindAddress)`:$AppPort"
        return [PSCustomObject]@{
            BindAddress = $observation.BindAddress
            InterfaceIndex = $observation.InterfaceIndex
            InterfaceAlias = $observation.InterfaceAlias
            NetworkName = $observation.NetworkName
            NetworkCategory = $observation.NetworkCategory
            AllowPublicNetworkProfile = $observation.AllowPublicNetworkProfile
            PublicNetworkProfileOverrideUsed =
                $observation.PublicNetworkProfileOverrideUsed
            ExposureProfile =
                if ($observation.BindAddress -ceq $podmanBindAddress) {
                    "loopback"
                }
                else {
                    "private_lan"
                }
            PublicHost = $observation.BindAddress
            PublicAppUrl = $appOrigin
            AppWebSocketOrigin =
                "ws://$($observation.BindAddress)`:$AppPort"
            LiveKitOrigin =
                "ws://$($observation.BindAddress)`:$LiveKitSignalPort"
            ObjectOrigin =
                "http://$($observation.BindAddress)`:$MinioPort"
            MediaNodeAddress = $observation.BindAddress
            TrustedProxyCidr = ""
            TrustedEdgeConfirmation = ""
        }
    }

    if ($RequestedBindAddress -cne $podmanBindAddress) {
        throw (
            "-BindAddress must remain $podmanBindAddress with the Cloudflare " +
            "trusted-edge profile; use -MediaNodeAddress for direct media exposure"
        )
    }
    if ($TrustedEdgeConfirmation -cne $cloudflareTrustedEdgeConfirmation) {
        throw (
            "Cloudflare trusted-edge deployment requires " +
            "-TrustedEdgeConfirmation $cloudflareTrustedEdgeConfirmation"
        )
    }
    $resolvedAppHostname =
        Resolve-CanonicalDnsHostname -Value $AppHostname -Name "AppHostname"
    $resolvedMediaHostname =
        Resolve-CanonicalDnsHostname -Value $MediaHostname -Name "MediaHostname"
    $resolvedObjectHostname =
        Resolve-CanonicalDnsHostname -Value $ObjectHostname -Name "ObjectHostname"
    if (@(
        $resolvedAppHostname,
        $resolvedMediaHostname,
        $resolvedObjectHostname
    ) | Group-Object | Where-Object { $_.Count -ne 1 }) {
        throw "Cloudflare application, media, and object hostnames must be distinct"
    }
    if ([string]::IsNullOrWhiteSpace($MediaNodeAddress)) {
        throw "Cloudflare trusted-edge deployment requires -MediaNodeAddress"
    }
    $observation = Resolve-ReleaseNetworkObservation `
        -Value $MediaNodeAddress `
        -AllowPublicNetworkProfile:$AllowPublicNetworkProfile
    if ($observation.BindAddress -ceq $podmanBindAddress) {
        throw "MediaNodeAddress must be an explicit non-loopback RFC1918 address"
    }

    [PSCustomObject]@{
        BindAddress = $observation.BindAddress
        InterfaceIndex = $observation.InterfaceIndex
        InterfaceAlias = $observation.InterfaceAlias
        NetworkName = $observation.NetworkName
        NetworkCategory = $observation.NetworkCategory
        AllowPublicNetworkProfile = $observation.AllowPublicNetworkProfile
        PublicNetworkProfileOverrideUsed =
            $observation.PublicNetworkProfileOverrideUsed
        ExposureProfile = $cloudflareTrustedEdgeProfile
        PublicHost = $resolvedAppHostname
        PublicAppUrl = "https://$resolvedAppHostname"
        AppWebSocketOrigin = "wss://$resolvedAppHostname"
        LiveKitOrigin = "wss://$resolvedMediaHostname"
        ObjectOrigin = "https://$resolvedObjectHostname"
        MediaNodeAddress = $observation.BindAddress
        # Deployment resolves and seals the exact application-network gateway
        # /32 before any application container starts.
        TrustedProxyCidr = ""
        TrustedEdgeConfirmation = $cloudflareTrustedEdgeConfirmation
    }
}

function Assert-ReleaseNetworkObservationMatches {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Observed,
        [Parameter(Mandatory)][string]$Context
    )

    foreach ($comparison in @(
        @("bindAddress", [string]$Expected.BindAddress, [string]$Observed.BindAddress),
        @("interfaceIndex", [int]$Expected.InterfaceIndex, [int]$Observed.InterfaceIndex),
        @("interfaceAlias", [string]$Expected.InterfaceAlias, [string]$Observed.InterfaceAlias),
        @("networkName", [string]$Expected.NetworkName, [string]$Observed.NetworkName),
        @("networkCategory", [string]$Expected.NetworkCategory, [string]$Observed.NetworkCategory),
        @(
            "publicNetworkProfileOverrideUsed",
            [bool]$Expected.PublicNetworkProfileOverrideUsed,
            [bool]$Observed.PublicNetworkProfileOverrideUsed
        )
    )) {
        if ($comparison[1] -cne $comparison[2]) {
            throw (
                "$Context $($comparison[0]) no longer matches the observed interface"
            )
        }
    }
}

function Assert-ReleaseNetworkObservationCurrent {
    param([Parameter(Mandatory)]$Expected)

    $current = Resolve-ReleaseNetworkObservation `
        -Value $Expected.BindAddress `
        -AllowPublicNetworkProfile:$Expected.AllowPublicNetworkProfile
    Assert-ReleaseNetworkObservationMatches `
        -Expected $Expected `
        -Observed $current `
        -Context "Selected release network profile"
    return [PSCustomObject]@{
        BindAddress = $current.BindAddress
        InterfaceIndex = $current.InterfaceIndex
        InterfaceAlias = $current.InterfaceAlias
        NetworkName = $current.NetworkName
        NetworkCategory = $current.NetworkCategory
        AllowPublicNetworkProfile = $current.AllowPublicNetworkProfile
        PublicNetworkProfileOverrideUsed =
            $current.PublicNetworkProfileOverrideUsed
        ExposureProfile = [string]$Expected.ExposureProfile
        PublicHost = [string]$Expected.PublicHost
        PublicAppUrl = [string]$Expected.PublicAppUrl
        AppWebSocketOrigin = [string]$Expected.AppWebSocketOrigin
        LiveKitOrigin = [string]$Expected.LiveKitOrigin
        ObjectOrigin = [string]$Expected.ObjectOrigin
        MediaNodeAddress = [string]$Expected.MediaNodeAddress
        TrustedProxyCidr = [string]$Expected.TrustedProxyCidr
        TrustedEdgeConfirmation = [string]$Expected.TrustedEdgeConfirmation
    }
}

function Get-ReceiptNetworkProperty {
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    $network =
        if ($Receipt -is [Collections.IDictionary]) {
            if ($Receipt.Contains("network")) {
                $Receipt["network"]
            }
            else {
                $null
            }
        }
        else {
            $networkProperty = $Receipt.PSObject.Properties["network"]
            if ($networkProperty) {
                $networkProperty.Value
            }
            else {
                $null
            }
        }
    if (-not $network) {
        return $DefaultValue
    }
    if ($network -is [Collections.IDictionary]) {
        if ($network.Contains($Name)) {
            return $network[$Name]
        }
        return $DefaultValue
    }
    $property = $network.PSObject.Properties[$Name]
    if (-not $property) {
        return $DefaultValue
    }
    return $property.Value
}

function Get-ReceiptBindAddress {
    param([Parameter(Mandatory)]$Receipt)

    $value = Get-ReceiptNetworkProperty `
        -Receipt $Receipt `
        -Name "bindAddress" `
        -DefaultValue "127.0.0.1"
    if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
        return [string]$value
    }
    return "127.0.0.1"
}

function Get-ReceiptPublicHost {
    param([Parameter(Mandatory)]$Receipt)

    $value = Get-ReceiptNetworkProperty `
        -Receipt $Receipt `
        -Name "publicHost"
    if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
        return [string]$value
    }
    return (Get-ReceiptBindAddress -Receipt $Receipt)
}

function Get-ReceiptPublicAppUrl {
    param([Parameter(Mandatory)]$Receipt)

    if ($Receipt -is [Collections.IDictionary]) {
        if (
            $Receipt.Contains("publicAppUrl") -and
            -not [string]::IsNullOrWhiteSpace([string]$Receipt["publicAppUrl"])
        ) {
            return [string]$Receipt["publicAppUrl"]
        }
    }
    else {
        $topLevelProperty = $Receipt.PSObject.Properties["publicAppUrl"]
        if (
            $topLevelProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$topLevelProperty.Value)
        ) {
            return [string]$topLevelProperty.Value
        }
    }
    $value = Get-ReceiptNetworkProperty `
        -Receipt $Receipt `
        -Name "publicAppUrl"
    if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
        return [string]$value
    }
    $publicHost = Get-ReceiptPublicHost -Receipt $Receipt
    return "http://$publicHost`:$($Receipt.ports.app)"
}

function Get-ReceiptNetworkProfileRecord {
    param([Parameter(Mandatory)]$Receipt)

    $bindAddress = Get-ReceiptBindAddress -Receipt $Receipt
    $isLoopback = $bindAddress -ceq "127.0.0.1"
    [PSCustomObject]@{
        BindAddress = $bindAddress
        InterfaceIndex = [int](Get-ReceiptNetworkProperty `
            -Receipt $Receipt `
            -Name "interfaceIndex" `
            -DefaultValue $(if ($isLoopback) { 0 } else { -1 }))
        InterfaceAlias = [string](Get-ReceiptNetworkProperty `
            -Receipt $Receipt `
            -Name "interfaceAlias" `
            -DefaultValue $(if ($isLoopback) { "Loopback" } else { "" }))
        NetworkName = [string](Get-ReceiptNetworkProperty `
            -Receipt $Receipt `
            -Name "networkName" `
            -DefaultValue $(if ($isLoopback) { "Loopback" } else { "" }))
        NetworkCategory = [string](Get-ReceiptNetworkProperty `
            -Receipt $Receipt `
            -Name "networkCategory" `
            -DefaultValue $(if ($isLoopback) { "Loopback" } else { "" }))
        AllowPublicNetworkProfile = [bool](Get-ReceiptNetworkProperty `
            -Receipt $Receipt `
            -Name "allowPublicNetworkProfile" `
            -DefaultValue $false)
        PublicNetworkProfileOverrideUsed = [bool](Get-ReceiptNetworkProperty `
            -Receipt $Receipt `
            -Name "publicNetworkProfileOverrideUsed" `
            -DefaultValue $false)
    }
}

function New-ReceiptNetworkRecord {
    param(
        [Parameter(Mandatory)]$Observation,
        [Parameter(Mandatory)][string]$PublicAppUrl
    )

    $profile = [string]$Observation.ExposureProfile
    $isTrustedEdge = $profile -ceq $cloudflareTrustedEdgeProfile
    $record = [ordered]@{
        bindAddress = $Observation.BindAddress
        podmanBindAddress = $podmanBindAddress
        publicHost =
            if ($isTrustedEdge) {
                [string]$Observation.PublicHost
            }
            else {
                [string]$Observation.BindAddress
            }
        publicAppUrl = $PublicAppUrl
        exposureProfile = $profile
        exposureMode =
            if ($isTrustedEdge) {
                $cloudflareTrustedEdgeProfile
            }
            elseif ($Observation.BindAddress -ceq $podmanBindAddress) {
                "loopback"
            }
            else {
                "lan-forwarder"
            }
        interfaceIndex = $Observation.InterfaceIndex
        interfaceAlias = $Observation.InterfaceAlias
        networkName = $Observation.NetworkName
        networkCategory = $Observation.NetworkCategory
        allowPublicNetworkProfile = $Observation.AllowPublicNetworkProfile
        publicNetworkProfileOverrideUsed =
            $Observation.PublicNetworkProfileOverrideUsed
    }
    if ($isTrustedEdge) {
        $record["mediaNodeAddress"] = [string]$Observation.MediaNodeAddress
        $record["trustedProxyCidr"] = [string]$Observation.TrustedProxyCidr
        $record["trustedEdgeConfirmation"] =
            [string]$Observation.TrustedEdgeConfirmation
        $record["appHostname"] = [string]$Observation.PublicHost
        $record["mediaHostname"] =
            ([Uri][string]$Observation.LiveKitOrigin).Host
        $record["objectHostname"] =
            ([Uri][string]$Observation.ObjectOrigin).Host
    }
    $record
}

function New-ReceiptPublicOriginsRecord {
    param([Parameter(Mandatory)]$Topology)

    [ordered]@{
        application = [string]$Topology.PublicAppUrl
        applicationWebSocket = [string]$Topology.AppWebSocketOrigin
        media = [string]$Topology.LiveKitOrigin
        objectStorage = [string]$Topology.ObjectOrigin
    }
}

function Get-ReceiptTopLevelProperty {
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    if ($Receipt -is [Collections.IDictionary]) {
        if ($Receipt.Contains($Name)) {
            return $Receipt[$Name]
        }
        return $DefaultValue
    }
    $property = $Receipt.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $DefaultValue
}

function Get-ReceiptPublicOriginsRecord {
    param([Parameter(Mandatory)]$Receipt)

    Get-ReceiptTopLevelProperty `
        -Receipt $Receipt `
        -Name "publicOrigins" `
        -DefaultValue $null
}

function Assert-ExactTrustedProxyCidr {
    param([Parameter(Mandatory)][string]$Value)

    $match = [Regex]::Match(
        $Value,
        "^(?<address>(?:[0-9]{1,3}\.){3}[0-9]{1,3})/32$"
    )
    if (-not $match.Success) {
        throw "Trusted proxy CIDR must be one exact canonical IPv4 /32"
    }
    $parsed = $null
    if (
        -not [Net.IPAddress]::TryParse($match.Groups["address"].Value, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.ToString() -cne $match.Groups["address"].Value -or
        [Net.IPAddress]::IsLoopback($parsed) -or
        $parsed.ToString() -ceq "0.0.0.0" -or
        -not (Test-Rfc1918IPv4 -Address $parsed)
    ) {
        throw "Trusted proxy CIDR must contain one canonical non-loopback IPv4 address"
    }
    return "$($parsed.ToString())/32"
}

function Resolve-ReceiptNetworkTopology {
    param([Parameter(Mandatory)]$Receipt)

    $schemaVersion = Get-ReceiptSchemaVersion -Receipt $Receipt
    $recordedBindAddress = Get-ReceiptBindAddress -Receipt $Receipt
    if ($schemaVersion -lt 5 -and $recordedBindAddress -cne $podmanBindAddress) {
        throw (
            "Schema-v3/v4 retained releases are supported only in loopback mode. " +
            "Deploy a schema-v5 LAN-forwarded release."
        )
    }
    $recordedPodmanBindAddress = Get-ReceiptPodmanBindAddress -Receipt $Receipt
    if ($recordedPodmanBindAddress -cne $podmanBindAddress) {
        throw "Retained release Podman bind address must be exactly $podmanBindAddress"
    }
    $record = Get-ReceiptNetworkProfileRecord -Receipt $Receipt
    $observation = Resolve-ReleaseNetworkObservation `
        -Value $recordedBindAddress `
        -AllowPublicNetworkProfile:$record.AllowPublicNetworkProfile
    $resolvedBindAddress = $observation.BindAddress
    $exposureProfile = Get-ReceiptExposureProfile -Receipt $Receipt
    $publicHost = Get-ReceiptPublicHost -Receipt $Receipt
    $publicAppUrl = Get-ReceiptPublicAppUrl -Receipt $Receipt

    if ($exposureProfile -ceq $cloudflareTrustedEdgeProfile) {
        if ($schemaVersion -lt 6) {
            throw "Cloudflare trusted-edge releases require a schema-v6 receipt"
        }
        $recordedExposureMode = [string](Get-ReceiptNetworkProperty `
            -Receipt $Receipt `
            -Name "exposureMode")
        if ($recordedExposureMode -cne $cloudflareTrustedEdgeProfile) {
            throw "Retained trusted-edge exposure mode does not match its profile"
        }
        $appHostname = Resolve-CanonicalDnsHostname `
            -Value ([string](Get-ReceiptNetworkProperty `
                -Receipt $Receipt `
                -Name "appHostname")) `
            -Name "receipt appHostname"
        $mediaHostname = Resolve-CanonicalDnsHostname `
            -Value ([string](Get-ReceiptNetworkProperty `
                -Receipt $Receipt `
                -Name "mediaHostname")) `
            -Name "receipt mediaHostname"
        $objectHostname = Resolve-CanonicalDnsHostname `
            -Value ([string](Get-ReceiptNetworkProperty `
                -Receipt $Receipt `
                -Name "objectHostname")) `
            -Name "receipt objectHostname"
        if (@(
            $appHostname,
            $mediaHostname,
            $objectHostname
        ) | Group-Object | Where-Object { $_.Count -ne 1 }) {
            throw (
                "Retained trusted-edge application, media, and object " +
                "hostnames must remain distinct"
            )
        }
        $mediaNodeAddress = [string](Get-ReceiptNetworkProperty `
            -Receipt $Receipt `
            -Name "mediaNodeAddress")
        if (
            $mediaNodeAddress -cne $resolvedBindAddress -or
            $publicHost -cne $appHostname
        ) {
            throw (
                "Retained trusted-edge public host or media node does not match " +
                "its sealed network topology"
            )
        }
        $trustedEdgeConfirmation = [string](Get-ReceiptNetworkProperty `
            -Receipt $Receipt `
            -Name "trustedEdgeConfirmation")
        if ($trustedEdgeConfirmation -cne $cloudflareTrustedEdgeConfirmation) {
            throw "Retained trusted-edge receipt lacks its exact confirmation"
        }
        $trustedProxyCidr = Assert-ExactTrustedProxyCidr `
            -Value ([string](Get-ReceiptNetworkProperty `
                -Receipt $Receipt `
                -Name "trustedProxyCidr"))
        $expectedOrigins = [ordered]@{
            application = "https://$appHostname"
            applicationWebSocket = "wss://$appHostname"
            media = "wss://$mediaHostname"
            objectStorage = "https://$objectHostname"
        }
        $publicOrigins = Get-ReceiptPublicOriginsRecord -Receipt $Receipt
        if (-not $publicOrigins) {
            throw "Schema-v6 trusted-edge receipt is missing sealed public origins"
        }
        foreach ($entry in $expectedOrigins.GetEnumerator()) {
            $actual = Get-ReceiptTopLevelProperty `
                -Receipt $publicOrigins `
                -Name $entry.Key `
                -DefaultValue ""
            if ([string]$actual -cne [string]$entry.Value) {
                throw (
                    "Retained trusted-edge public origin '$($entry.Key)' does not " +
                    "match its sealed hostname"
                )
            }
        }
        if (
            $publicAppUrl -cne [string]$expectedOrigins.application -or
            [string](Get-ReceiptNetworkProperty `
                -Receipt $Receipt `
                -Name "publicAppUrl") -cne [string]$expectedOrigins.application
        ) {
            throw (
                "Retained release public application URL does not match its " +
                "recorded trusted-edge topology"
            )
        }
        Assert-ReleaseNetworkObservationMatches `
            -Expected $record `
            -Observed $observation `
            -Context "Retained trusted-edge media network profile"
        return [PSCustomObject]@{
            BindAddress = $resolvedBindAddress
            PodmanBindAddress = $recordedPodmanBindAddress
            PublicHost = $publicHost
            PublicAppUrl = $publicAppUrl
            AppWebSocketOrigin = [string]$expectedOrigins.applicationWebSocket
            LiveKitOrigin = [string]$expectedOrigins.media
            ObjectOrigin = [string]$expectedOrigins.objectStorage
            MediaNodeAddress = $mediaNodeAddress
            TrustedProxyCidr = $trustedProxyCidr
            TrustedEdgeConfirmation = $trustedEdgeConfirmation
            ExposureProfile = $exposureProfile
            InterfaceIndex = $observation.InterfaceIndex
            InterfaceAlias = $observation.InterfaceAlias
            NetworkName = $observation.NetworkName
            NetworkCategory = $observation.NetworkCategory
            AllowPublicNetworkProfile = $observation.AllowPublicNetworkProfile
            PublicNetworkProfileOverrideUsed =
                $observation.PublicNetworkProfileOverrideUsed
        }
    }

    if ($publicHost -cne $resolvedBindAddress) {
        throw "Retained release public host must match its explicit bind address"
    }
    $expectedPublicAppUrl = "http://$publicHost`:$($Receipt.ports.app)"
    if ($publicAppUrl -cne $expectedPublicAppUrl) {
        throw "Retained release public application URL does not match its recorded topology"
    }
    if ($schemaVersion -ge 5) {
        $expectedExposureMode =
            if ($resolvedBindAddress -ceq $podmanBindAddress) {
                "loopback"
            }
            else {
                "lan-forwarder"
            }
        $recordedExposureMode = [string](Get-ReceiptNetworkProperty `
            -Receipt $Receipt `
            -Name "exposureMode")
        if ($recordedExposureMode -cne $expectedExposureMode) {
            throw "Retained release exposure mode does not match its recorded topology"
        }
    }
    $appWebSocketOrigin = "ws://$publicHost`:$($Receipt.ports.app)"
    $liveKitOrigin =
        "ws://$publicHost`:$($Receipt.ports.livekitSignal)"
    $objectOrigin = "http://$publicHost`:$($Receipt.ports.minio)"
    if ($schemaVersion -ge 6) {
        $expectedProfile =
            if ($resolvedBindAddress -ceq $podmanBindAddress) {
                "loopback"
            }
            else {
                "private_lan"
            }
        if ($exposureProfile -cne $expectedProfile) {
            throw "Schema-v6 release exposure profile does not match its topology"
        }
        $publicOrigins = Get-ReceiptPublicOriginsRecord -Receipt $Receipt
        $expectedOrigins = [ordered]@{
            application = $publicAppUrl
            applicationWebSocket = $appWebSocketOrigin
            media = $liveKitOrigin
            objectStorage = $objectOrigin
        }
        foreach ($entry in $expectedOrigins.GetEnumerator()) {
            if (
                -not $publicOrigins -or
                [string](Get-ReceiptTopLevelProperty `
                    -Receipt $publicOrigins `
                    -Name $entry.Key `
                    -DefaultValue "") -cne [string]$entry.Value
            ) {
                throw "Schema-v6 release public origins do not match its topology"
            }
        }
    }
    if ($resolvedBindAddress -cne "127.0.0.1") {
        Assert-ReleaseNetworkObservationMatches `
            -Expected $record `
            -Observed $observation `
            -Context "Retained release network profile"
    }
    [PSCustomObject]@{
        BindAddress = $resolvedBindAddress
        PodmanBindAddress = $recordedPodmanBindAddress
        PublicHost = $publicHost
        PublicAppUrl = $publicAppUrl
        AppWebSocketOrigin = $appWebSocketOrigin
        LiveKitOrigin = $liveKitOrigin
        ObjectOrigin = $objectOrigin
        MediaNodeAddress = $resolvedBindAddress
        TrustedProxyCidr = ""
        TrustedEdgeConfirmation = ""
        ExposureProfile = $exposureProfile
        InterfaceIndex = $observation.InterfaceIndex
        InterfaceAlias = $observation.InterfaceAlias
        NetworkName = $observation.NetworkName
        NetworkCategory = $observation.NetworkCategory
        AllowPublicNetworkProfile = $observation.AllowPublicNetworkProfile
        PublicNetworkProfileOverrideUsed =
            $observation.PublicNetworkProfileOverrideUsed
    }
}

function New-StableEnvironment {
    [ordered]@{
        POSTGRES_USER = "kcomms"
        POSTGRES_PASSWORD = New-UrlSafeSecret 36
        MINIO_ROOT_USER = "kcomms"
        MINIO_ROOT_PASSWORD = New-UrlSafeSecret 36
        LIVEKIT_API_KEY = "local_" + (New-UrlSafeSecret 24)
        LIVEKIT_API_SECRET = New-UrlSafeSecret 48
        SECRET_KEY_BASE = New-UrlSafeSecret 72
        PASSWORD_RECOVERY_SIGNING_KEY = New-UrlSafeSecret 48
        WEBHOOK_SECRET_ENCRYPTION_KEY = New-EncryptionKey
        PUSH_SUBSCRIPTION_ENCRYPTION_KEY = New-EncryptionKey
        METRICS_BEARER_TOKEN = New-UrlSafeSecret 36
        BOOTSTRAP_OWNER_PASSWORD = New-UrlSafeSecret 48
        WEB_PUSH_VAPID_PUBLIC_KEY = "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo"
    }
}

function Get-StableEnvironment {
    $path = Join-Path $StateRoot "environment.env"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-EnvironmentFile -Path $path -Values (New-StableEnvironment)
    }
    $values = Read-EnvironmentFile -Path $path
    $changed = $false
    if (-not $values.Contains("BOOTSTRAP_OWNER_PASSWORD")) {
        $values["BOOTSTRAP_OWNER_PASSWORD"] = New-UrlSafeSecret 48
        $changed = $true
    }
    foreach ($name in @(
        "WEBHOOK_SECRET_ENCRYPTION_KEY",
        "PUSH_SUBSCRIPTION_ENCRYPTION_KEY"
    )) {
        $existing = if ($values.Contains($name)) {
            [string]$values[$name]
        }
        else {
            $null
        }
        $resolved = Resolve-StableEncryptionKey -Value $existing -Name $name
        if ($resolved -cne $existing) {
            $values[$name] = $resolved
            $changed = $true
        }
    }
    if ($changed) {
        Write-EnvironmentFile -Path $path -Values $values
    }
    $values
}

function New-ReleaseEnvironment {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Stable,
        [Parameter(Mandatory)][string]$Revision,
        [Parameter(Mandatory)][string]$ImageReference,
        [Parameter(Mandatory)]$Topology
    )

    $values = [ordered]@{}
    foreach ($entry in $Stable.GetEnumerator()) {
        $values[$entry.Key] = $entry.Value
    }
    $values["K_COMMS_RELEASE_PROJECT"] = $ProjectName
    $values["K_COMMS_RELEASE_IMAGE"] = $ImageReference
    $values["K_COMMS_RELEASE_REVISION"] = $Revision
    $values["K_COMMS_RELEASE_VERSION"] = "sha-$Revision"
    $values["K_COMMS_PODMAN_BIND_ADDRESS"] = $podmanBindAddress
    $isTrustedEdge =
        [string]$Topology.ExposureProfile -ceq $cloudflareTrustedEdgeProfile
    $values["K_COMMS_RELEASE_HOST"] =
        if ($isTrustedEdge) {
            [string]$Topology.PublicHost
        }
        else {
            $BindAddress
        }
    $values["K_COMMS_LIVEKIT_NODE_IP"] =
        if ($isTrustedEdge) {
            [string]$Topology.MediaNodeAddress
        }
        else {
            $BindAddress
        }
    $values["K_COMMS_LOCAL_RELEASE_HOST"] =
        if ($BindAddress -eq "127.0.0.1") {
            if ($isTrustedEdge) { [string]$Topology.MediaNodeAddress } else { "" }
        }
        else {
            $BindAddress
        }
    $values["K_COMMS_RELEASE_EXPOSURE_MODE"] =
        if ($isTrustedEdge) { $cloudflareTrustedEdgeProfile } else { "" }
    $values["K_COMMS_TRUSTED_EDGE_CONFIRMATION"] =
        if ($isTrustedEdge) {
            $cloudflareTrustedEdgeConfirmation
        }
        else {
            ""
        }
    $values["K_COMMS_RELEASE_APP_PORT"] = "$AppPort"
    $values["K_COMMS_RELEASE_MINIO_PORT"] = "$MinioPort"
    $values["K_COMMS_RELEASE_MINIO_CONSOLE_PORT"] = "$MinioConsolePort"
    $values["K_COMMS_RELEASE_LIVEKIT_SIGNAL_PORT"] = "$LiveKitSignalPort"
    $values["K_COMMS_RELEASE_LIVEKIT_TCP_PORT"] = "$LiveKitTcpPort"
    $values["K_COMMS_RELEASE_LIVEKIT_UDP_PORT"] = "$LiveKitUdpPort"
    $values["POSTGRES_DB"] = "k_comms_release"
    $values["DATABASE_URL"] =
        "ecto://$($Stable.POSTGRES_USER):$($Stable.POSTGRES_PASSWORD)@postgres:5432/k_comms_release"
    if ($isTrustedEdge) {
        $values["PHX_HOST"] = [string]$Topology.PublicHost
        $values["PUBLIC_APP_URL"] = [string]$Topology.PublicAppUrl
        $values["CORS_ORIGINS"] = [string]$Topology.PublicAppUrl
        $values["HSTS_ENABLED"] = "true"
        $values["LIVEKIT_SERVER_URL"] = [string]$Topology.LiveKitOrigin
        $values["S3_PUBLIC_ENDPOINT"] = [string]$Topology.ObjectOrigin
        $values["MINIO_API_CORS_ALLOW_ORIGIN"] =
            [string]$Topology.PublicAppUrl
        $values["CSP_CONNECT_SOURCES"] =
            "'self' $($Topology.LiveKitOrigin) $($Topology.ObjectOrigin)"
        $values["TRUSTED_PROXY_CIDRS"] = [string]$Topology.TrustedProxyCidr
    }
    else {
        $values["PHX_HOST"] = $BindAddress
        $values["PUBLIC_APP_URL"] = "http://$BindAddress`:$AppPort"
        $browserOrigins =
            if ($BindAddress -eq "127.0.0.1") {
                "http://127.0.0.1:$AppPort,http://localhost:$AppPort"
            }
            else {
                "http://$BindAddress`:$AppPort"
            }
        $values["CORS_ORIGINS"] = $browserOrigins
        $values["HSTS_ENABLED"] = "false"
        $values["LIVEKIT_SERVER_URL"] = "ws://$BindAddress`:$LiveKitSignalPort"
        $values["S3_PUBLIC_ENDPOINT"] = "http://$BindAddress`:$MinioPort"
        $values["MINIO_API_CORS_ALLOW_ORIGIN"] = $browserOrigins
        $values["CSP_CONNECT_SOURCES"] =
            "'self' http://$BindAddress`:$AppPort ws://$BindAddress`:$AppPort " +
            "ws://$BindAddress`:$LiveKitSignalPort http://$BindAddress`:$MinioPort"
        $values["TRUSTED_PROXY_CIDRS"] = ""
    }
    $values["S3_BUCKET"] = "k-comms-release"
    $values["ALLOW_BOOTSTRAP"] = "false"
    $values["INSTANT_ROOMS_ENABLED"] = "true"
    $values["INSTANT_ROOM_TENANT_SLUG"] = "k-comms-development"
    $values["INSTANT_ROOM_GUEST_IDLE_TTL_SECONDS"] = "3600"
    $values["INSTANT_ROOM_REGISTERED_IDLE_TTL_SECONDS"] = "86400"
    $values["INSTANT_ROOM_PRESENCE_HEARTBEAT_SECONDS"] = "30"
    $values["INSTANT_ROOM_PRESENCE_LEASE_SECONDS"] = "90"
    $values["INSTANT_ROOM_RECONNECT_GRACE_SECONDS"] = "90"
    $values["INSTANT_ROOM_MAX_PARTICIPANTS"] = "25"
    $values["BOOTSTRAP_TENANT_NAME"] = "K-Comms Development"
    $values["BOOTSTRAP_TENANT_SLUG"] = "k-comms-development"
    $values["BOOTSTRAP_OWNER_DISPLAY_NAME"] = "Instant Room Owner"
    $values["BOOTSTRAP_OWNER_EMAIL"] = "instant-room-owner@k-comms.local"
    $values
}

function Assert-ReleaseEnvironmentTopology {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Values,
        [Parameter(Mandatory)][string]$ExpectedBindAddress,
        [Parameter(Mandatory)]$ExpectedTopology
    )

    $isTrustedEdge =
        [string]$ExpectedTopology.ExposureProfile -ceq
            $cloudflareTrustedEdgeProfile
    if ($isTrustedEdge) {
        $expectedValues = [ordered]@{
            ALLOW_BOOTSTRAP = "false"
            K_COMMS_PODMAN_BIND_ADDRESS = $podmanBindAddress
            K_COMMS_RELEASE_HOST = [string]$ExpectedTopology.PublicHost
            K_COMMS_LIVEKIT_NODE_IP =
                [string]$ExpectedTopology.MediaNodeAddress
            K_COMMS_LOCAL_RELEASE_HOST =
                [string]$ExpectedTopology.MediaNodeAddress
            K_COMMS_RELEASE_EXPOSURE_MODE =
                $cloudflareTrustedEdgeProfile
            K_COMMS_TRUSTED_EDGE_CONFIRMATION =
                $cloudflareTrustedEdgeConfirmation
            PHX_HOST = [string]$ExpectedTopology.PublicHost
            PUBLIC_APP_URL = [string]$ExpectedTopology.PublicAppUrl
            CORS_ORIGINS = [string]$ExpectedTopology.PublicAppUrl
            HSTS_ENABLED = "true"
            LIVEKIT_SERVER_URL = [string]$ExpectedTopology.LiveKitOrigin
            S3_PUBLIC_ENDPOINT = [string]$ExpectedTopology.ObjectOrigin
            MINIO_API_CORS_ALLOW_ORIGIN =
                [string]$ExpectedTopology.PublicAppUrl
            CSP_CONNECT_SOURCES =
                "'self' $($ExpectedTopology.LiveKitOrigin) " +
                "$($ExpectedTopology.ObjectOrigin)"
            TRUSTED_PROXY_CIDRS =
                Assert-ExactTrustedProxyCidr `
                    -Value ([string]$ExpectedTopology.TrustedProxyCidr)
        }
        foreach ($entry in $expectedValues.GetEnumerator()) {
            if (
                -not $Values.Contains($entry.Key) -or
                [string]$Values[$entry.Key] -cne [string]$entry.Value
            ) {
                throw (
                    "Trusted-edge release environment topology is inconsistent " +
                    "for $($entry.Key)"
                )
            }
        }
        return
    }

    $appOrigin = "http://$ExpectedBindAddress`:$AppPort"
    $expectedRuntimeHost =
        if ($ExpectedBindAddress -eq "127.0.0.1") {
            ""
        }
        else {
            $ExpectedBindAddress
        }
    $expectedBrowserOrigins =
        if ($ExpectedBindAddress -eq "127.0.0.1") {
            "$appOrigin,http://localhost:$AppPort"
        }
        else {
            $appOrigin
        }
    $expectedValues = [ordered]@{
        ALLOW_BOOTSTRAP = "false"
        K_COMMS_PODMAN_BIND_ADDRESS = $podmanBindAddress
        K_COMMS_RELEASE_HOST = $ExpectedBindAddress
        K_COMMS_LIVEKIT_NODE_IP = $ExpectedBindAddress
        K_COMMS_LOCAL_RELEASE_HOST = $expectedRuntimeHost
        K_COMMS_RELEASE_EXPOSURE_MODE = ""
        K_COMMS_TRUSTED_EDGE_CONFIRMATION = ""
        PHX_HOST = $ExpectedBindAddress
        PUBLIC_APP_URL = $appOrigin
        CORS_ORIGINS = $expectedBrowserOrigins
        LIVEKIT_SERVER_URL = "ws://$ExpectedBindAddress`:$LiveKitSignalPort"
        S3_PUBLIC_ENDPOINT = "http://$ExpectedBindAddress`:$MinioPort"
        MINIO_API_CORS_ALLOW_ORIGIN = $expectedBrowserOrigins
        HSTS_ENABLED = "false"
        TRUSTED_PROXY_CIDRS = ""
        CSP_CONNECT_SOURCES =
            "'self' $appOrigin ws://$ExpectedBindAddress`:$AppPort " +
            "ws://$ExpectedBindAddress`:$LiveKitSignalPort " +
            "http://$ExpectedBindAddress`:$MinioPort"
    }
    foreach ($entry in $expectedValues.GetEnumerator()) {
        if (
            -not $Values.Contains($entry.Key) -or
            [string]$Values[$entry.Key] -cne [string]$entry.Value
        ) {
            throw "Release environment topology is inconsistent for $($entry.Key)"
        }
    }
}

function Assert-RequiredTools {
    param([Parameter(Mandatory)][string[]]$Commands)

    foreach ($command in $Commands) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command was not found: $command"
        }
    }
    if (-not (Test-Path -LiteralPath $composeFile -PathType Leaf)) {
        throw "Local release composition was not found: $composeFile"
    }
}

function Get-RepositoryHead {
    $revision =
        (Invoke-NativeCommand -FilePath "git" -Arguments @("rev-parse", "--verify", "HEAD^{commit}")).Output.Trim()
    if ($revision -notmatch "^[0-9a-f]{40}$") {
        throw "Git did not return a full 40-character revision"
    }
    $revision
}

function Assert-RepositoryHead {
    param(
        [Parameter(Mandatory)][string]$ExpectedRevision,
        [Parameter(Mandatory)][string]$Phase
    )

    $observedRevision = Get-RepositoryHead
    if ($observedRevision -ne $ExpectedRevision) {
        throw (
            "Repository HEAD changed $Phase. " +
            "Expected $ExpectedRevision but observed $observedRevision."
        )
    }
}

function Assert-CleanRevision {
    $revision = Get-RepositoryHead
    $dirty = (Invoke-NativeCommand `
        -FilePath "git" `
        -Arguments @("status", "--porcelain=v1", "--untracked-files=all")).Output.Trim()
    if ($dirty) {
        throw (
            "Exact-revision deployment requires a completely clean worktree. " +
            "Commit or remove all tracked and untracked changes before Deploy."
        )
    }
    Assert-RepositoryHead `
        -ExpectedRevision $revision `
        -Phase "while validating the clean deployment revision"
    $revision
}

function New-ImmutableSourceContext {
    param(
        [Parameter(Mandatory)][string]$ExpectedRevision,
        [Parameter(Mandatory)][string]$CandidateDirectory
    )

    Assert-RepositoryHead `
        -ExpectedRevision $ExpectedRevision `
        -Phase "before capturing the immutable deployment source"

    $archivePath = Join-Path $CandidateDirectory "source.archive.tar"
    $contextPath = Join-Path $CandidateDirectory "source.context"
    if (
        (Test-Path -LiteralPath $archivePath) -or
        (Test-Path -LiteralPath $contextPath)
    ) {
        throw "Immutable deployment source paths already exist for this candidate"
    }

    Invoke-NativeCommand `
        -FilePath "git" `
        -Arguments @(
            "archive",
            "--format=tar",
            "--output", $archivePath,
            $ExpectedRevision
        ) | Out-Null
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "Git did not create the immutable deployment source archive"
    }

    New-Item -ItemType Directory -Path $contextPath | Out-Null
    Invoke-NativeCommand `
        -FilePath "tar" `
        -Arguments @("-xf", $archivePath, "-C", $contextPath) | Out-Null

    foreach ($requiredPath in @(
            (Join-Path $contextPath "Dockerfile"),
            (Join-Path $contextPath "deploy\compose.local-release.yaml")
        )) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Immutable deployment source is missing required file: $requiredPath"
        }
    }

    Assert-RepositoryHead `
        -ExpectedRevision $ExpectedRevision `
        -Phase "after capturing the immutable deployment source"

    [PSCustomObject]@{
        archivePath = $archivePath
        archiveSha256 =
            (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        contextPath = $contextPath
        revision = $ExpectedRevision
    }
}

function Remove-ImmutableSourceContext {
    param(
        [Parameter(Mandatory)][string]$ContextPath,
        [Parameter(Mandatory)][string]$CandidateDirectory
    )

    if (-not (Test-Path -LiteralPath $ContextPath)) {
        return
    }

    $candidatePrefix =
        [IO.Path]::GetFullPath($CandidateDirectory).TrimEnd("\", "/") +
        [IO.Path]::DirectorySeparatorChar
    $canonicalContext = [IO.Path]::GetFullPath($ContextPath)
    if (
        -not $canonicalContext.StartsWith(
            $candidatePrefix,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Refusing to remove an immutable source context outside its candidate directory"
    }

    Remove-Item -LiteralPath $canonicalContext -Recurse -Force
}

function Ensure-PodmanReady {
    $probe = Invoke-NativeCommand `
        -FilePath "podman" `
        -Arguments @("info", "--format", "{{.Host.Arch}}") `
        -AllowFailure
    if ($probe.ExitCode -ne 0) {
        Write-Host "Starting the Podman machine..."
        Invoke-NativeCommand -FilePath "podman" -Arguments @("machine", "start") -EchoOutput | Out-Null
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        $probe = Invoke-NativeCommand `
            -FilePath "podman" `
            -Arguments @("info", "--format", "{{.Host.Arch}}") `
            -AllowFailure
        if ($probe.ExitCode -eq 0) {
            return
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Podman did not become ready within 90 seconds"
        }
        Start-Sleep -Seconds 2
    } while ($true)
}

function Get-ImageEvidence {
    param(
        [Parameter(Mandatory)][string]$ImageReference,
        [Parameter(Mandatory)][string]$ExpectedRevision
    )

    $json = (Invoke-NativeCommand `
        -FilePath "podman" `
        -Arguments @("image", "inspect", $ImageReference)).Output | ConvertFrom-Json
    $image = @($json)[0]
    $labels = if ($image.Config -and $image.Config.Labels) {
        $image.Config.Labels
    }
    else {
        $image.Labels
    }
    $labelProperty = $labels.PSObject.Properties["org.opencontainers.image.revision"]
    $labelRevision = if ($labelProperty) { [string]$labelProperty.Value } else { "" }
    if ($labelRevision -ne $ExpectedRevision) {
        throw "Image revision label does not match the exact Git revision"
    }

    $digest = [string]$image.Digest
    $repoDigest = ""
    if ($image.RepoDigests -and @($image.RepoDigests).Count -gt 0) {
        $repoDigest = [string]@($image.RepoDigests)[0]
        if (-not $digest -and $repoDigest.Contains("@")) {
            $digest = $repoDigest.Split("@", 2)[1]
        }
    }
    if (-not $digest) {
        $digest = [string]$image.Id
    }

    [PSCustomObject]@{
        imageId = [string]$image.Id
        imageDigest = $digest
        repoDigest = $repoDigest
        labelRevision = $labelRevision
    }
}

function Write-RenderedConfiguration {
    param(
        [Parameter(Mandatory)][string]$EnvironmentFile,
        [Parameter(Mandatory)][string]$ComposeProject,
        [Parameter(Mandatory)][string]$ComposePath,
        [Parameter(Mandatory)][string]$DestinationDirectory,
        [Parameter(Mandatory)][Collections.IDictionary]$Secrets
    )

    $rendered = (Invoke-Compose `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -Arguments @("config")).Output
    $renderedPath = Join-Path $DestinationDirectory "compose.rendered.yaml"
    [IO.File]::WriteAllText(
        $renderedPath,
        $rendered,
        (New-Object Text.UTF8Encoding($false))
    )

    $redacted = $rendered
    $secretValues = foreach ($entry in $Secrets.GetEnumerator()) {
        if ([string]$entry.Value) {
            [PSCustomObject]@{ Name = $entry.Key; Value = [string]$entry.Value }
        }
    }
    foreach ($secret in ($secretValues | Sort-Object { $_.Value.Length } -Descending)) {
        $redacted = $redacted.Replace($secret.Value, "<redacted:$($secret.Name)>")
    }
    $redactedPath = Join-Path $DestinationDirectory "compose.rendered.redacted.yaml"
    [IO.File]::WriteAllText(
        $redactedPath,
        $redacted,
        (New-Object Text.UTF8Encoding($false))
    )

    [PSCustomObject]@{
        path = $renderedPath
        redactedPath = $redactedPath
        sha256 = (Get-FileHash -LiteralPath $renderedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Wait-ContainerHealth {
    param(
        [Parameter(Mandatory)][string]$EnvironmentFile,
        [Parameter(Mandatory)][string]$ComposeProject,
        [Parameter(Mandatory)][string]$ComposePath,
        [Parameter(Mandatory)][string]$Service
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
    do {
        $containerId = (Invoke-Compose `
            -EnvironmentFile $EnvironmentFile `
            -ComposeProject $ComposeProject `
            -ComposePath $ComposePath `
            -Arguments @("ps", "-q", $Service)).Output.Trim()
        if ($containerId) {
            $state = (Invoke-NativeCommand `
                -FilePath "podman" `
                -Arguments @(
                    "inspect",
                    "--format",
                    "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}",
                    $containerId
                )).Output.Trim()
            if ($state -eq "running|healthy") {
                return
            }
            if ($state.StartsWith("exited|") -or $state.StartsWith("dead|")) {
                throw "Service $Service exited before becoming healthy"
            }
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Service $Service did not become healthy within $ReadyTimeoutSeconds seconds"
        }
        Start-Sleep -Seconds 2
    } while ($true)
}

function Wait-HttpEndpoint {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Description
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 10
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                return
            }
        }
        catch {
            Write-Verbose "Waiting for $Description at $Uri`: $($_.Exception.Message)"
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "$Description did not become reachable within $ReadyTimeoutSeconds seconds"
        }
        Start-Sleep -Seconds 2
    } while ($true)
}

function Wait-Application {
    param(
        [Parameter(Mandatory)][string]$ExpectedBindAddress,
        [Parameter(Mandatory)][int]$ExpectedAppPort,
        [Parameter(Mandatory)][int]$ExpectedMinioPort,
        [Parameter(Mandatory)][int]$ExpectedLiveKitPort,
        [switch]$RequireGuestLinks,
        [switch]$RequireInstantRooms
    )

    $baseUri = "http://$ExpectedBindAddress`:$ExpectedAppPort"
    Wait-HttpEndpoint -Uri "$baseUri/health/ready" -Description "K-Comms readiness"
    Wait-HttpEndpoint -Uri "$baseUri/app/" -Description "packaged K-Comms web client"
    Wait-HttpEndpoint `
        -Uri "http://$ExpectedBindAddress`:$ExpectedMinioPort/minio/health/ready" `
        -Description "MinIO"
    Wait-HttpEndpoint `
        -Uri "http://$ExpectedBindAddress`:$ExpectedLiveKitPort/" `
        -Description "LiveKit"

    $status = Invoke-RestMethod -Uri "$baseUri/api/v1/status" -TimeoutSec 10
    Assert-ApplicationCapabilities `
        -Status $status `
        -RequireGuestLinks:$RequireGuestLinks `
        -RequireInstantRooms:$RequireInstantRooms
}

function Wait-TrustedEdgeApplication {
    param(
        [Parameter(Mandatory)]$Topology,
        [switch]$RequireGuestLinks,
        [switch]$RequireInstantRooms
    )

    if (
        [string]$Topology.ExposureProfile -cne
            $cloudflareTrustedEdgeProfile
    ) {
        throw "Trusted-edge health checks require the Cloudflare exposure profile"
    }
    Wait-HttpEndpoint `
        -Uri "$($Topology.PublicAppUrl)/health/ready" `
        -Description "Cloudflare-routed K-Comms readiness"
    Wait-HttpEndpoint `
        -Uri "$($Topology.PublicAppUrl)/app/" `
        -Description "Cloudflare-routed packaged K-Comms web client"
    Wait-HttpEndpoint `
        -Uri "$($Topology.ObjectOrigin)/minio/health/ready" `
        -Description "Cloudflare-routed MinIO"
    Wait-HttpEndpoint `
        -Uri "$($Topology.LiveKitOrigin.Replace('wss://', 'https://'))/" `
        -Description "Cloudflare-routed LiveKit signaling"

    $status = Invoke-RestMethod `
        -Uri "$($Topology.PublicAppUrl)/api/v1/status" `
        -TimeoutSec 10
    Assert-ApplicationCapabilities `
        -Status $status `
        -RequireGuestLinks:$RequireGuestLinks `
        -RequireInstantRooms:$RequireInstantRooms `
        -RequireSecureActions
}

function Test-InstantRoomTenantExists {
    param(
        [Parameter(Mandatory)][string]$EnvironmentFile,
        [Parameter(Mandatory)][string]$ComposeProject,
        [Parameter(Mandatory)][string]$ComposePath,
        [Parameter(Mandatory)][string]$TenantSlug,
        [Parameter(Mandatory)][string]$DatabaseUser,
        [Parameter(Mandatory)][string]$DatabaseName
    )

    if ($TenantSlug -notmatch "^[a-z0-9]+(?:-[a-z0-9]+)*$") {
        throw "Local instant-room tenant slug is malformed"
    }

    $query =
        "SELECT 1 FROM tenants " +
        "WHERE slug = '$TenantSlug' AND status = 'active' LIMIT 1"
    $result = Invoke-Compose `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -Arguments @(
            "exec", "-T", "postgres",
            "psql", "-U", $DatabaseUser, "-d", $DatabaseName,
            "-tA", "-c", $query
        ) `
        -AllowFailure

    $result.ExitCode -eq 0 -and $result.Output.Trim() -eq "1"
}

function Ensure-InstantRoomTenant {
    param(
        [Parameter(Mandatory)][string]$EnvironmentFile,
        [Parameter(Mandatory)][string]$ComposeProject,
        [Parameter(Mandatory)][string]$ComposePath,
        [Parameter(Mandatory)][string]$ExpectedBindAddress,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$ExpectedAppPort,
        [Parameter(Mandatory)][Collections.IDictionary]$ReleaseEnvironment
    )

    if ([string]$ReleaseEnvironment["INSTANT_ROOMS_ENABLED"] -ne "true") {
        return
    }

    $tenantSlug = [string]$ReleaseEnvironment["INSTANT_ROOM_TENANT_SLUG"]
    $databaseUser = [string]$ReleaseEnvironment["POSTGRES_USER"]
    $databaseName = [string]$ReleaseEnvironment["POSTGRES_DB"]

    $exists = Test-InstantRoomTenantExists `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -TenantSlug $tenantSlug `
        -DatabaseUser $databaseUser `
        -DatabaseName $databaseName
    if ($exists) {
        return
    }

    if ($ExpectedBindAddress -cne $podmanBindAddress) {
        throw "Local instant-room tenant provisioning must run through the loopback Podman topology"
    }
    if ([string]$ReleaseEnvironment["ALLOW_BOOTSTRAP"] -cne "false") {
        throw (
            "The retained release does not seal ALLOW_BOOTSTRAP=false and has no " +
            "active instant-room tenant. Deploy a current candidate; public HTTP bootstrap will not be used."
        )
    }
    $bootstrapTenantSlug = [string]$ReleaseEnvironment["BOOTSTRAP_TENANT_SLUG"]
    if ($bootstrapTenantSlug -cne $tenantSlug) {
        throw "Local bootstrap tenant slug must match the configured instant-room tenant slug"
    }
    $password = [string]$ReleaseEnvironment["BOOTSTRAP_OWNER_PASSWORD"]
    if ([string]::IsNullOrWhiteSpace($password) -or $password.Length -lt 32) {
        throw "Local instant-room tenant bootstrap password is missing or too short"
    }

    # The release command is PostgreSQL-serialized and idempotent for the same
    # tenant slug and owner email. It creates no browser session and never
    # exposes the bootstrap credential through the application listener.
    Invoke-Compose `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -Arguments @("run", "--rm", "--no-deps", "bootstrap") `
        -SealPublicBootstrap `
        -EchoOutput | Out-Null

    $exists = Test-InstantRoomTenantExists `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -TenantSlug $tenantSlug `
        -DatabaseUser $databaseUser `
        -DatabaseName $databaseName
    if (-not $exists) {
        throw (
            "Local instant-room tenant one-shot provisioning failed for configured slug " +
            "'$tenantSlug'; no active tenant was persisted"
        )
    }
}

function Assert-ApplicationCapabilities {
    param(
        [Parameter(Mandatory)]$Status,
        [switch]$RequireGuestLinks,
        [switch]$RequireInstantRooms,
        [switch]$RequireSecureActions
    )

    $capabilitiesProperty = $Status.PSObject.Properties["capabilities"]
    if ($null -eq $capabilitiesProperty) {
        throw "K-Comms status is missing capabilities"
    }
    $capabilities = $capabilitiesProperty.Value

    foreach ($name in @("audio_calls", "video_calls")) {
        $property = $capabilities.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -ne $true) {
            throw "K-Comms status does not report audio and video calls as available"
        }
    }

    $bootstrap = $capabilities.PSObject.Properties["bootstrap"]
    if ($null -eq $bootstrap -or $bootstrap.Value -ne $false) {
        throw "K-Comms status does not report the public bootstrap endpoint as disabled"
    }

    if ($RequireGuestLinks) {
        $guestLinks = $capabilities.PSObject.Properties["guest_links"]
        if ($null -eq $guestLinks -or $guestLinks.Value -ne $true) {
            throw "Candidate K-Comms status does not report guest links as available"
        }
    }

    if ($RequireInstantRooms) {
        $instantRooms = $capabilities.PSObject.Properties["instant_rooms"]
        if ($null -eq $instantRooms -or $instantRooms.Value -ne $true) {
            throw "Candidate K-Comms status does not report instant rooms as available"
        }
    }

    if ($RequireSecureActions) {
        foreach ($name in @(
            "secure_account_actions",
            "secure_media_actions"
        )) {
            $property = $capabilities.PSObject.Properties[$name]
            if ($null -eq $property -or $property.Value -ne $true) {
                throw (
                    "Trusted-edge K-Comms status does not report secure account " +
                    "and media actions as available"
                )
            }
        }
    }
}

function Invoke-CapabilityCompatibilitySelfTest {
    $predecessor = [PSCustomObject]@{
        capabilities = [PSCustomObject]@{
            audio_calls = $true
            video_calls = $true
            bootstrap = $false
        }
    }
    Assert-ApplicationCapabilities -Status $predecessor

    $candidateRequirementRejected = $false
    try {
        Assert-ApplicationCapabilities `
            -Status $predecessor `
            -RequireGuestLinks `
            -RequireInstantRooms
    }
    catch {
        $candidateRequirementRejected = $true
    }
    if (-not $candidateRequirementRejected) {
        throw "Capability self-test accepted a predecessor as a guest-links candidate"
    }

    $candidate = [PSCustomObject]@{
        capabilities = [PSCustomObject]@{
            audio_calls = $true
            video_calls = $true
            bootstrap = $false
            guest_links = $true
            instant_rooms = $true
        }
    }
    Assert-ApplicationCapabilities -Status $candidate -RequireGuestLinks
    Assert-ApplicationCapabilities `
        -Status $candidate `
        -RequireGuestLinks `
        -RequireInstantRooms

    $publicBootstrap = [PSCustomObject]@{
        capabilities = [PSCustomObject]@{
            audio_calls = $true
            video_calls = $true
            bootstrap = $true
            guest_links = $true
            instant_rooms = $true
        }
    }
    $publicBootstrapRejected = $false
    try {
        Assert-ApplicationCapabilities `
            -Status $publicBootstrap `
            -RequireGuestLinks `
            -RequireInstantRooms
    }
    catch {
        $publicBootstrapRejected = $true
    }
    if (-not $publicBootstrapRejected) {
        throw "Capability self-test accepted an application with public bootstrap enabled"
    }
}

function Test-ReceiptSupportsGuestRollback {
    param([Parameter(Mandatory)]$Receipt)

    $property = $Receipt.PSObject.Properties["rollbackCapabilities"]
    if ($null -eq $property) {
        return $false
    }

    $capabilities = @($property.Value | ForEach-Object { [string]$_ })
    (
        $capabilities -contains "guest_identity_v1" -and
        $capabilities -contains "guest_admission_expiry_worker_v1" -and
        $capabilities -contains "instant_room_lifecycle_v1" -and
        $capabilities -contains "instant_room_presence_lease_v1" -and
        $capabilities -contains "instant_room_expiry_worker_v1" -and
        $capabilities -contains "conversation_only_human_v1"
    )
}

function Assert-GuestRollbackCompatibility {
    param(
        [Parameter(Mandatory)]$TargetReceipt,
        [ValidateRange(0, [long]::MaxValue)]
        [long]$GuestUsers,
        [ValidateRange(0, [long]::MaxValue)]
        [long]$ActiveGuestExpiryJobs,
        [ValidateRange(0, [long]::MaxValue)]
        [long]$EphemeralRooms = 0,
        [ValidateRange(0, [long]::MaxValue)]
        [long]$EphemeralJoinReceipts = 0,
        [ValidateRange(0, [long]::MaxValue)]
        [long]$EphemeralPresenceLeases = 0,
        [ValidateRange(0, [long]::MaxValue)]
        [long]$ConversationOnlyHumans = 0,
        [ValidateRange(0, [long]::MaxValue)]
        [long]$ActiveEphemeralRoomJobs = 0
    )

    $capabilitiesProperty = $TargetReceipt.PSObject.Properties["rollbackCapabilities"]
    $capabilities = if ($null -eq $capabilitiesProperty) {
        @()
    }
    else {
        @($capabilitiesProperty.Value | ForEach-Object { [string]$_ })
    }
    $unsupported = @(
        @(
            [PSCustomObject]@{
                Name = "guest_identity_v1"
                Count = $GuestUsers
            }
            [PSCustomObject]@{
                Name = "guest_admission_expiry_worker_v1"
                Count = $ActiveGuestExpiryJobs
            }
            [PSCustomObject]@{
                Name = "instant_room_lifecycle_v1"
                Count = $EphemeralRooms + $EphemeralJoinReceipts
            }
            [PSCustomObject]@{
                Name = "instant_room_presence_lease_v1"
                Count = $EphemeralPresenceLeases
            }
            [PSCustomObject]@{
                Name = "conversation_only_human_v1"
                Count = $ConversationOnlyHumans
            }
            [PSCustomObject]@{
                Name = "instant_room_expiry_worker_v1"
                Count = $ActiveEphemeralRoomJobs
            }
        ) | Where-Object {
            $_.Count -gt 0 -and $capabilities -notcontains $_.Name
        }
    )

    if ($unsupported.Count -eq 0) {
        return
    }

    $revisionProperty = $TargetReceipt.PSObject.Properties["revision"]
    $revision = if ($revisionProperty) {
        [string]$revisionProperty.Value
    }
    else {
        "unknown"
    }
    $missingCapabilities =
        @($unsupported | ForEach-Object { $_.Name }) -join ", "
    throw (
        "Legacy release activation blocked after quiescing the current application. " +
        "Retained revision $revision lacks $missingCapabilities while PostgreSQL contains " +
        "guest_users=$GuestUsers, active_guest_expiry_jobs=$ActiveGuestExpiryJobs, " +
        "ephemeral_rooms=$EphemeralRooms, " +
        "ephemeral_join_receipts=$EphemeralJoinReceipts, " +
        "ephemeral_presence_leases=$EphemeralPresenceLeases, " +
        "conversation_only_humans=$ConversationOnlyHumans, " +
        "active_ephemeral_room_jobs=$ActiveEphemeralRoomJobs. Retain or deploy a " +
        "communication-compatible bridge release, or roll forward. No communication " +
        "data was changed."
    )
}

function Stop-ApplicationForGuestRollbackProbe {
    param([Parameter(Mandatory)]$CurrentReceipt)

    $stop = Invoke-Compose `
        -EnvironmentFile $CurrentReceipt.environmentFile `
        -ComposeProject $CurrentReceipt.projectName `
        -ComposePath $CurrentReceipt.composeSourcePath `
        -Arguments @("stop", "app") `
        -AllowFailure
    if ($stop.ExitCode -ne 0) {
        throw "Could not quiesce the current application before the guest rollback probe"
    }

    $running = Invoke-Compose `
        -EnvironmentFile $CurrentReceipt.environmentFile `
        -ComposeProject $CurrentReceipt.projectName `
        -ComposePath $CurrentReceipt.composeSourcePath `
        -Arguments @("ps", "--services", "--status", "running") `
        -AllowFailure
    if ($running.ExitCode -ne 0) {
        throw "Could not verify application quiescence before the guest rollback probe"
    }
    $runningServices = @(
        $running.Output -split "\r?\n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    if ($runningServices -contains "app") {
        throw "The current application remained active before the guest rollback probe"
    }
}

function Get-GuestRollbackHazards {
    param([Parameter(Mandatory)]$CurrentReceipt)

    $environment = Read-EnvironmentFile -Path $CurrentReceipt.environmentFile
    # The incomplete Oban group contains ('available', 'scheduled', 'executing', 'retryable')
    # plus the suspended state introduced by newer Oban releases.
    $query = @'
CREATE TEMP TABLE k_comms_communication_rollback_probe (
  guest_users bigint NOT NULL,
  guest_jobs bigint NOT NULL,
  ephemeral_rooms bigint NOT NULL,
  ephemeral_join_receipts bigint NOT NULL,
  ephemeral_leases bigint NOT NULL,
  conversation_only_humans bigint NOT NULL,
  ephemeral_jobs bigint NOT NULL
);
DO $k_comms$
DECLARE
  guest_users bigint := 0;
  guest_jobs bigint := 0;
  ephemeral_rooms bigint := 0;
  ephemeral_join_receipts bigint := 0;
  ephemeral_leases bigint := 0;
  conversation_only_humans bigint := 0;
  ephemeral_jobs bigint := 0;
BEGIN
  IF to_regclass('public.users') IS NOT NULL THEN
    EXECUTE $probe$SELECT count(*) FROM users WHERE account_type = 'guest'$probe$
      INTO guest_users;

    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'users'
        AND column_name = 'access_scope'
    ) THEN
      EXECUTE
        'SELECT count(*) FROM users ' ||
        'WHERE account_type = ''human'' AND access_scope = ''conversation_only'''
        INTO conversation_only_humans;
    END IF;
  END IF;

  IF to_regclass('public.oban_jobs') IS NOT NULL THEN
    EXECUTE $probe$
      SELECT count(*)
      FROM oban_jobs
      WHERE worker = 'CommsWorkers.GuestAdmissionExpiryWorker'
        AND state IN ('available', 'scheduled', 'executing', 'retryable', 'suspended')
    $probe$
      INTO guest_jobs;
    EXECUTE
      'SELECT count(*) FROM oban_jobs ' ||
      'WHERE worker IN (''CommsWorkers.EphemeralRoomLifecycleWorker'', ' ||
      '''CommsWorkers.EphemeralRoomReconcilerWorker'') ' ||
      'AND state IN (''available'', ''scheduled'', ''executing'', ''retryable'', ''suspended'')'
      INTO ephemeral_jobs;
  END IF;

  IF to_regclass('public.conversation_ephemeral_rooms') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM conversation_ephemeral_rooms'
      INTO ephemeral_rooms;
  END IF;

  IF to_regclass('public.conversation_ephemeral_join_receipts') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM conversation_ephemeral_join_receipts'
      INTO ephemeral_join_receipts;
  END IF;

  IF to_regclass('public.conversation_ephemeral_presence_leases') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM conversation_ephemeral_presence_leases'
      INTO ephemeral_leases;
  END IF;

  INSERT INTO k_comms_communication_rollback_probe
  VALUES (
    guest_users,
    guest_jobs,
    ephemeral_rooms,
    ephemeral_join_receipts,
    ephemeral_leases,
    conversation_only_humans,
    ephemeral_jobs
  );
END;
$k_comms$;
SELECT guest_users::text || '|' || guest_jobs::text || '|' ||
       ephemeral_rooms::text || '|' || ephemeral_join_receipts::text || '|' ||
       ephemeral_leases::text || '|' || conversation_only_humans::text || '|' ||
       ephemeral_jobs::text
FROM k_comms_communication_rollback_probe;
'@

    Invoke-Compose `
        -EnvironmentFile $CurrentReceipt.environmentFile `
        -ComposeProject $CurrentReceipt.projectName `
        -ComposePath $CurrentReceipt.composeSourcePath `
        -Arguments @("up", "-d", "--no-build", "postgres") | Out-Null
    Wait-ContainerHealth `
        -EnvironmentFile $CurrentReceipt.environmentFile `
        -ComposeProject $CurrentReceipt.projectName `
        -ComposePath $CurrentReceipt.composeSourcePath `
        -Service "postgres"
    $probe = Invoke-Compose `
        -EnvironmentFile $CurrentReceipt.environmentFile `
        -ComposeProject $CurrentReceipt.projectName `
        -ComposePath $CurrentReceipt.composeSourcePath `
        -Arguments @(
            "exec", "-T", "postgres",
            "psql", "-X", "-v", "ON_ERROR_STOP=1",
            "-U", [string]$environment["POSTGRES_USER"],
            "-d", [string]$environment["POSTGRES_DB"],
            "-Atqc", $query
        )

    $match = [Regex]::Match(
        $probe.Output,
        "(?m)^\s*(?<guestUsers>\d+)\|(?<guestJobs>\d+)\|" +
        "(?<rooms>\d+)\|(?<joinReceipts>\d+)\|(?<leases>\d+)\|" +
        "(?<humans>\d+)\|(?<roomJobs>\d+)\s*$"
    )
    if (-not $match.Success) {
        throw "Could not parse the guest rollback compatibility probe"
    }

    [PSCustomObject]@{
        GuestUsers = [long]$match.Groups["guestUsers"].Value
        ActiveGuestExpiryJobs = [long]$match.Groups["guestJobs"].Value
        EphemeralRooms = [long]$match.Groups["rooms"].Value
        EphemeralJoinReceipts = [long]$match.Groups["joinReceipts"].Value
        EphemeralPresenceLeases = [long]$match.Groups["leases"].Value
        ConversationOnlyHumans = [long]$match.Groups["humans"].Value
        ActiveEphemeralRoomJobs = [long]$match.Groups["roomJobs"].Value
    }
}

function Assert-GuestRollbackSafe {
    param(
        [Parameter(Mandatory)]$CurrentReceipt,
        [Parameter(Mandatory)]$TargetReceipt,
        [switch]$RestoreCurrentOnFailure,
        [scriptblock]$QuiesceAction = $null,
        [scriptblock]$HazardProbe = $null,
        [scriptblock]$RestoreAction = $null
    )

    $targetCompatible =
        Test-ReceiptSupportsGuestRollback -Receipt $TargetReceipt
    if ($targetCompatible) {
        return
    }

    try {
        if ($QuiesceAction) {
            & $QuiesceAction
        }
        else {
            Stop-ApplicationForGuestRollbackProbe -CurrentReceipt $CurrentReceipt
        }
        $hazards = if ($HazardProbe) {
            & $HazardProbe
        }
        else {
            Get-GuestRollbackHazards -CurrentReceipt $CurrentReceipt
        }
        Assert-GuestRollbackCompatibility `
            -TargetReceipt $TargetReceipt `
            -GuestUsers $hazards.GuestUsers `
            -ActiveGuestExpiryJobs $hazards.ActiveGuestExpiryJobs `
            -EphemeralRooms $hazards.EphemeralRooms `
            -EphemeralJoinReceipts $hazards.EphemeralJoinReceipts `
            -EphemeralPresenceLeases $hazards.EphemeralPresenceLeases `
            -ConversationOnlyHumans $hazards.ConversationOnlyHumans `
            -ActiveEphemeralRoomJobs $hazards.ActiveEphemeralRoomJobs
    }
    catch {
        $preflightError = $_
        if ($RestoreCurrentOnFailure) {
            $currentCompatible =
                Test-ReceiptSupportsGuestRollback -Receipt $CurrentReceipt
            if (-not $currentCompatible) {
                throw (
                    "Guest rollback preflight did not permit the predecessor, and the " +
                    "recorded current receipt also lacks guest rollback compatibility. " +
                    "The application remains quiesced for a guest-compatible bridge or " +
                    "roll-forward recovery. Preflight: $($preflightError.Exception.Message)"
                )
            }
            try {
                if ($RestoreAction) {
                    & $RestoreAction
                }
                else {
                    Restore-Release -Receipt $CurrentReceipt -UpdatePointer
                }
            }
            catch {
                throw (
                    "Guest rollback preflight failed and the exact current release could not " +
                    "be restored. Preflight: $($preflightError.Exception.Message) " +
                    "Current release restart: $($_.Exception.Message)"
                )
            }
            $currentRevisionProperty =
                $CurrentReceipt.PSObject.Properties["revision"]
            $currentRevision = if ($currentRevisionProperty) {
                [string]$currentRevisionProperty.Value
            }
            else {
                "unknown"
            }
            throw (
                "Guest rollback preflight did not permit the predecessor. Exact current " +
                "revision $currentRevision was restored and passed health checks. " +
                "Preflight: $($preflightError.Exception.Message)"
            )
        }
        throw $preflightError
    }
}

function Restore-RollbackTargetOrCurrent {
    param(
        [Parameter(Mandatory)]$CurrentReceipt,
        [Parameter(Mandatory)]$TargetReceipt,
        [scriptblock]$TargetRestoreAction = $null,
        [scriptblock]$CurrentRestoreAction = $null
    )

    try {
        if ($TargetRestoreAction) {
            & $TargetRestoreAction
        }
        else {
            Restore-Release -Receipt $TargetReceipt -UpdatePointer
        }
    }
    catch {
        $targetError = $_
        try {
            if ($CurrentRestoreAction) {
                & $CurrentRestoreAction
            }
            else {
                Restore-Release -Receipt $CurrentReceipt -UpdatePointer
            }
        }
        catch {
            throw (
                "Rollback target restore failed and the exact current release could not be " +
                "recovered. Target: $($targetError.Exception.Message) " +
                "Current release recovery: $($_.Exception.Message)"
            )
        }

        throw (
            "Rollback target restore failed. Exact current revision " +
            "$($CurrentReceipt.revision) was restored and passed health checks. " +
            "Target: $($targetError.Exception.Message)"
        )
    }
}

function Invoke-GuestRollbackCompatibilitySelfTest {
    $legacy = [PSCustomObject]@{
        revision = "legacy"
    }
    $compatible = [PSCustomObject]@{
        revision = "compatible"
        rollbackCapabilities = @(
            "guest_identity_v1",
            "guest_admission_expiry_worker_v1",
            "instant_room_lifecycle_v1",
            "instant_room_presence_lease_v1",
            "instant_room_expiry_worker_v1",
            "conversation_only_human_v1"
        )
    }

    Assert-GuestRollbackCompatibility `
        -TargetReceipt $legacy `
        -GuestUsers 0 `
        -ActiveGuestExpiryJobs 0
    Assert-GuestRollbackCompatibility `
        -TargetReceipt $compatible `
        -GuestUsers 1 `
        -ActiveGuestExpiryJobs 1

    foreach ($hazard in @(
        [PSCustomObject]@{
            GuestUsers = 1
            ActiveGuestExpiryJobs = 0
            EphemeralRooms = 0
            EphemeralJoinReceipts = 0
            EphemeralPresenceLeases = 0
            ConversationOnlyHumans = 0
            ActiveEphemeralRoomJobs = 0
        },
        [PSCustomObject]@{
            GuestUsers = 0
            ActiveGuestExpiryJobs = 1
            EphemeralRooms = 0
            EphemeralJoinReceipts = 0
            EphemeralPresenceLeases = 0
            ConversationOnlyHumans = 0
            ActiveEphemeralRoomJobs = 0
        },
        [PSCustomObject]@{
            GuestUsers = 0
            ActiveGuestExpiryJobs = 0
            EphemeralRooms = 1
            EphemeralJoinReceipts = 0
            EphemeralPresenceLeases = 0
            ConversationOnlyHumans = 0
            ActiveEphemeralRoomJobs = 0
        },
        [PSCustomObject]@{
            GuestUsers = 0
            ActiveGuestExpiryJobs = 0
            EphemeralRooms = 0
            EphemeralJoinReceipts = 1
            EphemeralPresenceLeases = 0
            ConversationOnlyHumans = 0
            ActiveEphemeralRoomJobs = 0
        },
        [PSCustomObject]@{
            GuestUsers = 0
            ActiveGuestExpiryJobs = 0
            EphemeralRooms = 0
            EphemeralJoinReceipts = 0
            EphemeralPresenceLeases = 1
            ConversationOnlyHumans = 0
            ActiveEphemeralRoomJobs = 0
        },
        [PSCustomObject]@{
            GuestUsers = 0
            ActiveGuestExpiryJobs = 0
            EphemeralRooms = 0
            EphemeralJoinReceipts = 0
            EphemeralPresenceLeases = 0
            ConversationOnlyHumans = 1
            ActiveEphemeralRoomJobs = 0
        },
        [PSCustomObject]@{
            GuestUsers = 0
            ActiveGuestExpiryJobs = 0
            EphemeralRooms = 0
            EphemeralJoinReceipts = 0
            EphemeralPresenceLeases = 0
            ConversationOnlyHumans = 0
            ActiveEphemeralRoomJobs = 1
        }
    )) {
        $legacyHazardRejected = $false
        try {
            Assert-GuestRollbackCompatibility `
                -TargetReceipt $legacy `
                -GuestUsers $hazard.GuestUsers `
                -ActiveGuestExpiryJobs $hazard.ActiveGuestExpiryJobs `
                -EphemeralRooms $hazard.EphemeralRooms `
                -EphemeralJoinReceipts $hazard.EphemeralJoinReceipts `
                -EphemeralPresenceLeases $hazard.EphemeralPresenceLeases `
                -ConversationOnlyHumans $hazard.ConversationOnlyHumans `
                -ActiveEphemeralRoomJobs $hazard.ActiveEphemeralRoomJobs
        }
        catch {
            $legacyHazardRejected = $true
        }
        if (-not $legacyHazardRejected) {
            throw "Communication rollback self-test accepted unsupported persisted state for a legacy predecessor"
        }
    }

    $compatibleBypassedProbe = $false
    Assert-GuestRollbackSafe `
        -CurrentReceipt ([PSCustomObject]@{}) `
        -TargetReceipt $compatible `
        -QuiesceAction { throw "compatible target attempted quiescence" } `
        -HazardProbe { throw "compatible target attempted a hazard probe" }
    $compatibleBypassedProbe = $true
    if (-not $compatibleBypassedProbe) {
        throw "Guest rollback self-test did not accept a compatible predecessor"
    }

    $probeFailureState = [PSCustomObject]@{ Restores = 0 }
    $probeFailureReported = $false
    try {
        Assert-GuestRollbackSafe `
            -CurrentReceipt $compatible `
            -TargetReceipt $legacy `
            -RestoreCurrentOnFailure `
            -QuiesceAction {} `
            -HazardProbe { throw "synthetic guest rollback probe failure" } `
            -RestoreAction { $probeFailureState.Restores++ }
    }
    catch {
        $probeFailureReported =
            $_.Exception.Message -match "synthetic guest rollback probe failure"
    }
    if (-not $probeFailureReported -or $probeFailureState.Restores -ne 1) {
        throw "Guest rollback self-test did not restore current release after a probe failure"
    }

    $restartFailureReported = $false
    try {
        Assert-GuestRollbackSafe `
            -CurrentReceipt $compatible `
            -TargetReceipt $legacy `
            -RestoreCurrentOnFailure `
            -QuiesceAction {} `
            -HazardProbe { throw "synthetic guest rollback probe failure" } `
            -RestoreAction { throw "synthetic current release restart failure" }
    }
    catch {
        $restartFailureReported =
            $_.Exception.Message -match "synthetic guest rollback probe failure" -and
            $_.Exception.Message -match "synthetic current release restart failure"
    }
    if (-not $restartFailureReported) {
        throw "Guest rollback self-test did not report probe and current-release restart failures"
    }

    $staleLegacyRestoreState = [PSCustomObject]@{ Restores = 0 }
    $staleLegacyRemainedQuiesced = $false
    try {
        Assert-GuestRollbackSafe `
            -CurrentReceipt $legacy `
            -TargetReceipt $legacy `
            -RestoreCurrentOnFailure `
            -QuiesceAction {} `
            -HazardProbe {
                [PSCustomObject]@{
                    GuestUsers = 1
                    ActiveGuestExpiryJobs = 0
                    EphemeralRooms = 0
                    EphemeralJoinReceipts = 0
                    EphemeralPresenceLeases = 0
                    ConversationOnlyHumans = 0
                    ActiveEphemeralRoomJobs = 0
                }
            } `
            -RestoreAction { $staleLegacyRestoreState.Restores++ }
    }
    catch {
        $staleLegacyRemainedQuiesced =
            $_.Exception.Message -match "recorded current receipt also lacks" -and
            $_.Exception.Message -match "remains quiesced"
    }
    if (-not $staleLegacyRemainedQuiesced -or $staleLegacyRestoreState.Restores -ne 0) {
        throw "Guest rollback self-test reactivated a stale legacy current receipt"
    }

    $targetFailureState = [PSCustomObject]@{ CurrentRestores = 0 }
    $targetFailureRecovered = $false
    try {
        Restore-RollbackTargetOrCurrent `
            -CurrentReceipt ([PSCustomObject]@{ revision = "current" }) `
            -TargetReceipt ([PSCustomObject]@{ revision = "target" }) `
            -TargetRestoreAction { throw "synthetic target restore failure" } `
            -CurrentRestoreAction { $targetFailureState.CurrentRestores++ }
    }
    catch {
        $targetFailureRecovered =
            $_.Exception.Message -match "synthetic target restore failure" -and
            $_.Exception.Message -match "restored and passed health checks"
    }
    if (-not $targetFailureRecovered -or $targetFailureState.CurrentRestores -ne 1) {
        throw "Guest rollback self-test did not recover the current release after target failure"
    }

    $targetAndCurrentFailuresReported = $false
    try {
        Restore-RollbackTargetOrCurrent `
            -CurrentReceipt ([PSCustomObject]@{ revision = "current" }) `
            -TargetReceipt ([PSCustomObject]@{ revision = "target" }) `
            -TargetRestoreAction { throw "synthetic target restore failure" } `
            -CurrentRestoreAction { throw "synthetic current recovery failure" }
    }
    catch {
        $targetAndCurrentFailuresReported =
            $_.Exception.Message -match "synthetic target restore failure" -and
            $_.Exception.Message -match "synthetic current recovery failure"
    }
    if (-not $targetAndCurrentFailuresReported) {
        throw "Guest rollback self-test did not report target and current restore failures"
    }
}

function Stop-ApplicationForMigration {
    param(
        [Parameter(Mandatory)][string]$EnvironmentFile,
        [Parameter(Mandatory)][string]$ComposeProject,
        [Parameter(Mandatory)][string]$ComposePath
    )

    $stop = Invoke-Compose `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -Arguments @("stop", "app") `
        -AllowFailure
    if ($stop.ExitCode -ne 0) {
        throw "Could not quiesce the application before the forward migration"
    }

    $running = Invoke-Compose `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -Arguments @("ps", "--services", "--status", "running") `
        -AllowFailure
    if ($running.ExitCode -ne 0) {
        throw "Could not verify application quiescence before the forward migration"
    }

    $runningServices = @(
        $running.Output -split "\r?\n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    if ($runningServices -contains "app") {
        throw "The application remained active before the forward migration"
    }
}

function Start-SealedApplication {
    param(
        [Parameter(Mandatory)][string]$EnvironmentFile,
        [Parameter(Mandatory)][string]$ComposeProject,
        [Parameter(Mandatory)][string]$ComposePath
    )

    # Always override the retained interpolation value. This keeps legacy
    # receipts restartable when their tenant already exists without ever
    # re-exposing the public bootstrap endpoint.
    Invoke-Compose `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -Arguments @("up", "-d", "--no-build", "--force-recreate", "app") `
        -SealPublicBootstrap `
        -EchoOutput | Out-Null
}

function Start-ReleaseServices {
    param(
        [Parameter(Mandatory)][string]$EnvironmentFile,
        [Parameter(Mandatory)][string]$ComposeProject,
        [Parameter(Mandatory)][string]$ComposePath,
        [switch]$RunMigration
    )

    Invoke-Compose `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -Arguments @("up", "-d", "--no-build", "postgres", "minio", "livekit") `
        -EchoOutput | Out-Null
    Wait-ContainerHealth `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -Service "postgres"
    Wait-ContainerHealth `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -Service "minio"

    Invoke-Compose `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -Arguments @("run", "--rm", "--no-deps", "minio-init") `
        -EchoOutput | Out-Null

    if ($RunMigration) {
        Stop-ApplicationForMigration `
            -EnvironmentFile $EnvironmentFile `
            -ComposeProject $ComposeProject `
            -ComposePath $ComposePath
        $migration = Invoke-Compose `
            -EnvironmentFile $EnvironmentFile `
            -ComposeProject $ComposeProject `
            -ComposePath $ComposePath `
            -Arguments @("run", "--rm", "--no-deps", "migrate")
        $migration.Output
    }
    else {
        $null
    }
}

function Resolve-ComposeTrustedProxyCidr {
    param(
        [Parameter(Mandatory)][string]$EnvironmentFile,
        [Parameter(Mandatory)][string]$ComposeProject,
        [Parameter(Mandatory)][string]$ComposePath
    )

    $containerId = (Invoke-Compose `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -Arguments @("ps", "-q", "postgres")).Output.Trim()
    if (-not $containerId) {
        throw "Cannot resolve the Podman gateway before PostgreSQL is running"
    }
    $inspection = Invoke-NativeCommand `
        -FilePath "podman" `
        -Arguments @(
            "inspect",
            "--format",
            "{{json .NetworkSettings.Networks}}",
            $containerId
        )
    try {
        $networks = $inspection.Output | ConvertFrom-Json
    }
    catch {
        throw "Podman returned invalid application-network inspection JSON"
    }
    $attachments = @($networks.PSObject.Properties)
    if ($attachments.Count -ne 1) {
        throw (
            "The local release must attach PostgreSQL to exactly one isolated " +
            "Compose network before deriving trusted proxies"
        )
    }
    $gatewayProperty = $attachments[0].Value.PSObject.Properties["Gateway"]
    if (
        -not $gatewayProperty -or
        [string]::IsNullOrWhiteSpace([string]$gatewayProperty.Value)
    ) {
        throw "The isolated Compose network has no observable IPv4 gateway"
    }
    Assert-ExactTrustedProxyCidr `
        -Value "$([string]$gatewayProperty.Value)/32"
}

function Assert-ReceiptTrustedProxyGatewayCurrent {
    param([Parameter(Mandatory)]$Receipt)

    if (-not (Test-ReceiptIsCloudflareTrustedEdge -Receipt $Receipt)) {
        return
    }
    $recorded = [string](Get-ReceiptNetworkProperty `
        -Receipt $Receipt `
        -Name "trustedProxyCidr")
    $observed = Resolve-ComposeTrustedProxyCidr `
        -EnvironmentFile ([string]$Receipt.environmentFile) `
        -ComposeProject ([string]$Receipt.projectName) `
        -ComposePath ([string]$Receipt.composeSourcePath)
    if ($observed -cne $recorded) {
        throw (
            "Observed Podman application-network gateway '$observed' does not " +
            "match the sealed trusted proxy CIDR '$recorded'"
        )
    }
}

function Get-RequiredForwarderProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )

    if ($Object -is [Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) {
            throw "$Context is missing required property '$Name'"
        }
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) {
        throw "$Context is missing required property '$Name'"
    }
    return $property.Value
}

function New-LanForwarderListeners {
    param(
        [Parameter(Mandatory)][int]$ExpectedAppPort,
        [Parameter(Mandatory)][int]$ExpectedMinioPort,
        [Parameter(Mandatory)][int]$ExpectedLiveKitSignalPort,
        [Parameter(Mandatory)][int]$ExpectedLiveKitTcpPort,
        [Parameter(Mandatory)][int]$ExpectedLiveKitUdpPort,
        [ValidateSet("full", "media-only")]
        [string]$Profile = "full"
    )

    if ($Profile -ceq "media-only") {
        return @(
            [ordered]@{
                name = "livekitTcp"
                protocol = "tcp"
                publicPort = $ExpectedLiveKitTcpPort
                targetHost = $podmanBindAddress
                targetPort = $ExpectedLiveKitTcpPort
            }
            [ordered]@{
                name = "livekitUdp"
                protocol = "udp"
                publicPort = $ExpectedLiveKitUdpPort
                targetHost = $podmanBindAddress
                targetPort = $ExpectedLiveKitUdpPort
            }
        )
    }

    @(
        [ordered]@{
            name = "app"
            protocol = "tcp"
            publicPort = $ExpectedAppPort
            targetHost = $podmanBindAddress
            targetPort = $ExpectedAppPort
        }
        [ordered]@{
            name = "minio"
            protocol = "tcp"
            publicPort = $ExpectedMinioPort
            targetHost = $podmanBindAddress
            targetPort = $ExpectedMinioPort
        }
        [ordered]@{
            name = "livekitSignal"
            protocol = "tcp"
            publicPort = $ExpectedLiveKitSignalPort
            targetHost = $podmanBindAddress
            targetPort = $ExpectedLiveKitSignalPort
        }
        [ordered]@{
            name = "livekitTcp"
            protocol = "tcp"
            publicPort = $ExpectedLiveKitTcpPort
            targetHost = $podmanBindAddress
            targetPort = $ExpectedLiveKitTcpPort
        }
        [ordered]@{
            name = "livekitUdp"
            protocol = "udp"
            publicPort = $ExpectedLiveKitUdpPort
            targetHost = $podmanBindAddress
            targetPort = $ExpectedLiveKitUdpPort
        }
    )
}

function New-LanForwarderLimits {
    [ordered]@{
        maxTcpConnections = 256
        tcpConnectTimeoutMs = 5000
        tcpIdleTimeoutMs = 120000
        tcpShutdownGraceMs = 3000
        tcpBacklog = 128
        socketHighWaterMarkBytes = 65536
        maxUdpMappings = 256
        udpMappingIdleTimeoutMs = 60000
        maxUdpPendingDatagramsPerMapping = 32
        maxUdpPendingPublicDatagrams = 1024
    }
}

function Assert-ForwarderValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][string]$Context
    )

    $actual = Get-RequiredForwarderProperty `
        -Object $Object `
        -Name $Name `
        -Context $Context
    if ([string]$actual -cne [string]$Expected) {
        throw (
            "$Context property '$Name' does not match the sealed release; " +
            "expected '$Expected', observed '$actual'"
        )
    }
}

function Assert-LanForwarderListeners {
    param(
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][string]$Context
    )

    $actualListeners = @($Actual)
    $expectedListeners = @($Expected)
    if ($actualListeners.Count -ne $expectedListeners.Count) {
        throw (
            "$Context must contain exactly $($expectedListeners.Count) listeners; " +
            "observed $($actualListeners.Count)"
        )
    }
    for ($index = 0; $index -lt $expectedListeners.Count; $index++) {
        foreach ($propertyName in @(
            "name",
            "protocol",
            "publicPort",
            "targetHost",
            "targetPort"
        )) {
            Assert-ForwarderValue `
                -Object $actualListeners[$index] `
                -Name $propertyName `
                -Expected (
                    Get-RequiredForwarderProperty `
                        -Object $expectedListeners[$index] `
                        -Name $propertyName `
                        -Context "expected LAN forwarder listener"
                ) `
                -Context "$Context listener $index"
        }
    }
}

function Assert-PathEquals {
    param(
        [Parameter(Mandatory)][string]$Actual,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Description
    )

    $actualFullPath = [IO.Path]::GetFullPath($Actual)
    $expectedFullPath = [IO.Path]::GetFullPath($Expected)
    if (-not $actualFullPath.Equals(
        $expectedFullPath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Description must be $expectedFullPath"
    }
}

function Get-Sha256Text {
    param([Parameter(Mandatory)][string]$Value)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return (
            [BitConverter]::ToString($algorithm.ComputeHash($bytes)).
                Replace("-", "").
                ToLowerInvariant()
        )
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-LanForwarderSupervisorTaskName {
    param(
        [Parameter(Mandatory)][string]$StateDirectory,
        [Parameter(Mandatory)][string]$ComposeProject
    )

    $identity = Get-Sha256Text -Value (
        ([IO.Path]::GetFullPath($StateDirectory).ToLowerInvariant()) +
        "|" +
        $ComposeProject.ToLowerInvariant()
    )
    return "K-Comms Media $ComposeProject-$($identity.Substring(0, 12))"
}

function Get-CurrentPowerShellExecutablePath {
    $path = [string](Get-Process -Id $PID -ErrorAction Stop).Path
    if (
        [string]::IsNullOrWhiteSpace($path) -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)
    ) {
        throw "Could not resolve the current PowerShell executable"
    }
    return [IO.Path]::GetFullPath($path)
}

function New-LanForwarderSupervisorScheduleRecord {
    param([DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow)

    $observed = $NowUtc.ToUniversalTime()
    $sealedAt = [DateTimeOffset]::new(
        $observed.Year,
        $observed.Month,
        $observed.Day,
        $observed.Hour,
        $observed.Minute,
        $observed.Second,
        [TimeSpan]::Zero
    )
    $startBoundary =
        $sealedAt.AddSeconds($lanForwarderSupervisorStartDelaySeconds)
    return [ordered]@{
        scheduleSealedAtUtc =
            $sealedAt.ToString(
                "yyyy-MM-ddTHH:mm:ss'Z'",
                [Globalization.CultureInfo]::InvariantCulture
            )
        taskStartBoundaryUtc =
            $startBoundary.ToString(
                "yyyy-MM-ddTHH:mm:ss'Z'",
                [Globalization.CultureInfo]::InvariantCulture
            )
        startDelaySeconds = $lanForwarderSupervisorStartDelaySeconds
        repetitionDurationDays =
            $lanForwarderSupervisorRepetitionDurationDays
        nextRunGraceSeconds = $lanForwarderSupervisorNextRunGraceSeconds
    }
}

function Set-LanForwarderSupervisorScheduleRecord {
    param(
        [Parameter(Mandatory)]$Forwarder,
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
    )

    $supervisor = Get-LanForwarderSupervisor -Forwarder $Forwarder
    if (-not $supervisor) {
        throw "Media-only LAN forwarder is missing its supervisor schedule"
    }
    $schedule = New-LanForwarderSupervisorScheduleRecord -NowUtc $NowUtc
    foreach ($entry in $schedule.GetEnumerator()) {
        if ($supervisor -is [Collections.IDictionary]) {
            $supervisor[$entry.Key] = $entry.Value
        }
        else {
            $property = $supervisor.PSObject.Properties[$entry.Key]
            if ($property) {
                $property.Value = $entry.Value
            }
            else {
                $supervisor |
                    Add-Member `
                        -NotePropertyName $entry.Key `
                        -NotePropertyValue $entry.Value
            }
        }
    }
}

function New-LanForwarderSupervisorRecord {
    param(
        [Parameter(Mandatory)][string]$ImmutableSourceRoot,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][string]$CandidateId,
        [Parameter(Mandatory)][string]$ForwarderConfigSha256
    )

    if ($CandidateId -notmatch "^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}-[0-9a-f]{8}$") {
        throw "LAN forwarder supervisor candidate identity is malformed"
    }
    if ($ForwarderConfigSha256 -notmatch "^[0-9a-f]{64}$") {
        throw "LAN forwarder supervisor configuration hash is malformed"
    }
    $principal = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]::IsNullOrWhiteSpace($principal)) {
        throw "LAN forwarder supervisor could not resolve the current Windows identity"
    }
    $candidateDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($ReceiptPath))
    $retainedManagerScriptPath =
        Join-Path $candidateDirectory $retainedSupervisorManagerName
    if (Test-Path -LiteralPath $retainedManagerScriptPath) {
        throw "Retained LAN forwarder supervisor manager already exists"
    }
    $sourceManagerScriptPath = Join-Path `
        $ImmutableSourceRoot `
        "scripts\manage_local_release.ps1"
    if (-not (Test-Path -LiteralPath $sourceManagerScriptPath -PathType Leaf)) {
        throw (
            "Immutable LAN forwarder supervisor manager source is missing: " +
            $sourceManagerScriptPath
        )
    }
    $sourceManagerHash = (
        Get-FileHash -LiteralPath $sourceManagerScriptPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    [IO.File]::Copy(
        $sourceManagerScriptPath,
        $retainedManagerScriptPath,
        $false
    )
    $retainedManagerHash = (
        Get-FileHash -LiteralPath $retainedManagerScriptPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ($retainedManagerHash -cne $sourceManagerHash) {
        throw "Retained LAN forwarder supervisor manager copy is not exact"
    }
    $schedule = New-LanForwarderSupervisorScheduleRecord
    return [ordered]@{
        required = $true
        kind = $lanForwarderSupervisorKind
        taskName = Get-LanForwarderSupervisorTaskName `
            -StateDirectory $StateRoot `
            -ComposeProject $ProjectName
        taskDescription = (
            "K-Comms receipt-bound media forwarder supervisor for " +
            "$ProjectName; state=" +
            (Get-Sha256Text -Value $StateRoot).Substring(0, 16)
        )
        principal = $principal
        managerScriptPath = $retainedManagerScriptPath
        managerScriptSha256 = $retainedManagerHash
        powerShellExecutablePath = Get-CurrentPowerShellExecutablePath
        stateRoot = $StateRoot
        projectName = $ProjectName
        expectedReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
        expectedCandidateId = $CandidateId
        expectedForwarderConfigSha256 = $ForwarderConfigSha256
        intervalSeconds = $lanForwarderSupervisorIntervalSeconds
        scheduleSealedAtUtc = $schedule.scheduleSealedAtUtc
        taskStartBoundaryUtc = $schedule.taskStartBoundaryUtc
        startDelaySeconds = $schedule.startDelaySeconds
        repetitionDurationDays = $schedule.repetitionDurationDays
        nextRunGraceSeconds = $schedule.nextRunGraceSeconds
        readyTimeoutSeconds = 30
    }
}

function Get-LanForwarderSupervisor {
    param([Parameter(Mandatory)]$Forwarder)

    if ($Forwarder -is [Collections.IDictionary]) {
        if ($Forwarder.Contains("supervisor")) {
            return $Forwarder["supervisor"]
        }
        return $null
    }
    $property = $Forwarder.PSObject.Properties["supervisor"]
    if (-not $property) {
        return $null
    }
    return $property.Value
}

function Assert-LanForwarderSupervisorRecord {
    param(
        [Parameter(Mandatory)]$Supervisor,
        [Parameter(Mandatory)]$Forwarder,
        [Parameter(Mandatory)][string]$CandidateDirectory
    )

    $expectedReceiptPath = Join-Path $CandidateDirectory "deployment.json"
    $expectedTaskName = Get-LanForwarderSupervisorTaskName `
        -StateDirectory $StateRoot `
        -ComposeProject $ProjectName
    $expectedDescription = (
        "K-Comms receipt-bound media forwarder supervisor for " +
        "$ProjectName; state=" +
        (Get-Sha256Text -Value $StateRoot).Substring(0, 16)
    )
    $expectedManagerScriptPath =
        Join-Path $CandidateDirectory $retainedSupervisorManagerName
    foreach ($expectation in @(
        @("required", $true),
        @("kind", $lanForwarderSupervisorKind),
        @("taskName", $expectedTaskName),
        @("taskDescription", $expectedDescription),
        @("principal", [Security.Principal.WindowsIdentity]::GetCurrent().Name),
        @("managerScriptPath", $expectedManagerScriptPath),
        @("stateRoot", $StateRoot),
        @("projectName", $ProjectName),
        @("expectedReceiptPath", $expectedReceiptPath),
        @("expectedForwarderConfigSha256", [string]$Forwarder.configSha256),
        @("intervalSeconds", $lanForwarderSupervisorIntervalSeconds),
        @("startDelaySeconds", $lanForwarderSupervisorStartDelaySeconds),
        @(
            "repetitionDurationDays",
            $lanForwarderSupervisorRepetitionDurationDays
        ),
        @("nextRunGraceSeconds", $lanForwarderSupervisorNextRunGraceSeconds),
        @("readyTimeoutSeconds", 30)
    )) {
        Assert-ForwarderValue `
            -Object $Supervisor `
            -Name $expectation[0] `
            -Expected $expectation[1] `
            -Context "LAN forwarder supervisor receipt"
    }
    $candidateId = [string](Get-RequiredForwarderProperty `
        -Object $Supervisor `
        -Name "expectedCandidateId" `
        -Context "LAN forwarder supervisor receipt")
    if ($candidateId -notmatch "^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}-[0-9a-f]{8}$") {
        throw "LAN forwarder supervisor receipt candidate identity is malformed"
    }
    $recordedManagerHash = [string](Get-RequiredForwarderProperty `
        -Object $Supervisor `
        -Name "managerScriptSha256" `
        -Context "LAN forwarder supervisor receipt")
    if (
        -not (Test-Path `
            -LiteralPath $expectedManagerScriptPath `
            -PathType Leaf)
    ) {
        throw "Retained LAN forwarder supervisor manager is missing"
    }
    $observedManagerHash = (
        Get-FileHash `
            -LiteralPath $expectedManagerScriptPath `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if (
        $recordedManagerHash -notmatch "^[0-9a-f]{64}$" -or
        $recordedManagerHash -cne $observedManagerHash
    ) {
        throw "LAN forwarder supervisor manager script hash does not match its receipt"
    }
    $powerShellExecutablePath = [string](Get-RequiredForwarderProperty `
        -Object $Supervisor `
        -Name "powerShellExecutablePath" `
        -Context "LAN forwarder supervisor receipt")
    if (
        -not [IO.Path]::IsPathRooted($powerShellExecutablePath) -or
        -not (Test-Path `
            -LiteralPath $powerShellExecutablePath `
            -PathType Leaf)
    ) {
        throw (
            "LAN forwarder supervisor PowerShell executable is not an existing " +
            "absolute file"
        )
    }
    $scheduleSealedAt = ConvertTo-ScheduledTaskUtcDateTimeOffset `
        -Value ([string](Get-RequiredForwarderProperty `
            -Object $Supervisor `
            -Name "scheduleSealedAtUtc" `
            -Context "LAN forwarder supervisor receipt"))
    $taskStartBoundary = ConvertTo-ScheduledTaskUtcDateTimeOffset `
        -Value ([string](Get-RequiredForwarderProperty `
            -Object $Supervisor `
            -Name "taskStartBoundaryUtc" `
            -Context "LAN forwarder supervisor receipt"))
    $now = [DateTimeOffset]::UtcNow
    if (
        $null -eq $scheduleSealedAt -or
        $null -eq $taskStartBoundary -or
        ($taskStartBoundary - $scheduleSealedAt).TotalSeconds -ne
            $lanForwarderSupervisorStartDelaySeconds -or
        $scheduleSealedAt -gt
            $now.AddSeconds($lanForwarderSupervisorNextRunGraceSeconds) -or
        $taskStartBoundary -gt
            $now.AddSeconds($lanForwarderSupervisorNextRunGraceSeconds) -or
        $taskStartBoundary.AddDays(
            $lanForwarderSupervisorRepetitionDurationDays
        ) -le $now
    ) {
        throw (
            "LAN forwarder supervisor receipt schedule is future-dated, " +
            "expired, or inconsistent"
        )
    }
}

function New-LanForwarderReceiptRecord {
    param(
        [Parameter(Mandatory)][string]$ImmutableSourceRoot,
        [Parameter(Mandatory)][string]$CandidateDirectory,
        [Parameter(Mandatory)][string]$ExpectedBindAddress,
        [Parameter(Mandatory)][int]$ExpectedAppPort,
        [Parameter(Mandatory)][int]$ExpectedMinioPort,
        [Parameter(Mandatory)][int]$ExpectedLiveKitSignalPort,
        [Parameter(Mandatory)][int]$ExpectedLiveKitTcpPort,
        [Parameter(Mandatory)][int]$ExpectedLiveKitUdpPort,
        [string]$ReceiptPath = "",
        [string]$CandidateId = "",
        [ValidateSet("full", "media-only")]
        [string]$Profile = "full"
    )

    $sourcePath = Join-Path `
        $ImmutableSourceRoot `
        ($lanForwarderSourceRelativePath.Replace("/", "\"))
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Immutable LAN forwarder source is missing: $sourcePath"
    }
    $nodeCommand = Get-Command node -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $nodeExecutablePath = [IO.Path]::GetFullPath($nodeCommand.Source)
    $scriptPath = Join-Path $CandidateDirectory "lan_release_forwarder.mjs"
    $configPath = Join-Path $CandidateDirectory "lan_release_forwarder.config.json"
    $statusPath = Join-Path $CandidateDirectory "lan_release_forwarder.ready.json"
    $stdoutLogPath = Join-Path $CandidateDirectory "lan_release_forwarder.stdout.log"
    $stderrLogPath = Join-Path $CandidateDirectory "lan_release_forwarder.stderr.log"
    [IO.File]::Copy($sourcePath, $scriptPath, $false)
    $sourceSha256 =
        (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $scriptSha256 =
        (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceSha256 -cne $scriptSha256) {
        throw "Copied LAN forwarder does not match its immutable source"
    }

    $listeners = New-LanForwarderListeners `
        -ExpectedAppPort $ExpectedAppPort `
        -ExpectedMinioPort $ExpectedMinioPort `
        -ExpectedLiveKitSignalPort $ExpectedLiveKitSignalPort `
        -ExpectedLiveKitTcpPort $ExpectedLiveKitTcpPort `
        -ExpectedLiveKitUdpPort $ExpectedLiveKitUdpPort `
        -Profile $Profile
    $readinessToken = New-UrlSafeSecret 32
    $configuration =
        if ($Profile -ceq "media-only") {
            [ordered]@{
                schemaVersion = 2
                profile = "media-only"
                bindAddress = $ExpectedBindAddress
                readinessToken = $readinessToken
                readyFile = $statusPath
                listeners = $listeners
                limits = New-LanForwarderLimits
            }
        }
        else {
            [ordered]@{
                schemaVersion = 1
                bindAddress = $ExpectedBindAddress
                readinessToken = $readinessToken
                readyFile = $statusPath
                listeners = $listeners
                limits = New-LanForwarderLimits
            }
        }
    Write-JsonAtomic -Path $configPath -Value $configuration
    $configSha256 =
        (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $record = [ordered]@{
        required = $true
        kind =
            if ($Profile -ceq "media-only") {
                "node-lan-forwarder-v2"
            }
            else {
                "node-lan-forwarder-v1"
            }
        nodeExecutablePath = $nodeExecutablePath
        sourceRelativePath = $lanForwarderSourceRelativePath
        sourceSha256 = $sourceSha256
        scriptPath = $scriptPath
        scriptSha256 = $scriptSha256
        configPath = $configPath
        configSha256 = $configSha256
        statusPath = $statusPath
        stdoutLogPath = $stdoutLogPath
        stderrLogPath = $stderrLogPath
        readinessToken = $readinessToken
        listeners = $listeners
    }
    if ($Profile -ceq "media-only") {
        $record["profile"] = "media-only"
        if (
            [string]::IsNullOrWhiteSpace($ReceiptPath) -or
            [string]::IsNullOrWhiteSpace($CandidateId)
        ) {
            throw (
                "Media-only LAN forwarding requires a receipt path and candidate " +
                "identity for durable supervision"
            )
        }
        $record["supervisor"] = New-LanForwarderSupervisorRecord `
            -ImmutableSourceRoot $ImmutableSourceRoot `
            -ReceiptPath $ReceiptPath `
            -CandidateId $CandidateId `
            -ForwarderConfigSha256 $configSha256
    }
    $record
}

function Assert-LanForwarderRecordAssets {
    param(
        [Parameter(Mandatory)]$Forwarder,
        [Parameter(Mandatory)][string]$CandidateDirectory,
        [Parameter(Mandatory)][string]$ExpectedBindAddress,
        [Parameter(Mandatory)][int]$ExpectedAppPort,
        [Parameter(Mandatory)][int]$ExpectedMinioPort,
        [Parameter(Mandatory)][int]$ExpectedLiveKitSignalPort,
        [Parameter(Mandatory)][int]$ExpectedLiveKitTcpPort,
        [Parameter(Mandatory)][int]$ExpectedLiveKitUdpPort,
        [ValidateSet("full", "media-only")]
        [string]$Profile = "full"
    )

    Assert-ForwarderValue `
        -Object $Forwarder `
        -Name "required" `
        -Expected $true `
        -Context "LAN forwarder receipt"
    Assert-ForwarderValue `
        -Object $Forwarder `
        -Name "kind" `
        -Expected $(if ($Profile -ceq "media-only") {
            "node-lan-forwarder-v2"
        } else {
            "node-lan-forwarder-v1"
        }) `
        -Context "LAN forwarder receipt"
    if ($Profile -ceq "media-only") {
        Assert-ForwarderValue `
            -Object $Forwarder `
            -Name "profile" `
            -Expected "media-only" `
            -Context "LAN forwarder receipt"
    }
    Assert-ForwarderValue `
        -Object $Forwarder `
        -Name "sourceRelativePath" `
        -Expected $lanForwarderSourceRelativePath `
        -Context "LAN forwarder receipt"

    $expectedPaths = [ordered]@{
        scriptPath = Join-Path $CandidateDirectory "lan_release_forwarder.mjs"
        configPath = Join-Path $CandidateDirectory "lan_release_forwarder.config.json"
        statusPath = Join-Path $CandidateDirectory "lan_release_forwarder.ready.json"
        stdoutLogPath = Join-Path $CandidateDirectory "lan_release_forwarder.stdout.log"
        stderrLogPath = Join-Path $CandidateDirectory "lan_release_forwarder.stderr.log"
    }
    foreach ($entry in $expectedPaths.GetEnumerator()) {
        $path = [string](Get-RequiredForwarderProperty `
            -Object $Forwarder `
            -Name $entry.Key `
            -Context "LAN forwarder receipt")
        Assert-PathEquals `
            -Actual $path `
            -Expected $entry.Value `
            -Description "LAN forwarder $($entry.Key)"
    }

    $scriptPath = [string]$Forwarder.scriptPath
    $configPath = [string]$Forwarder.configPath
    $nodeExecutablePath = [string](Get-RequiredForwarderProperty `
        -Object $Forwarder `
        -Name "nodeExecutablePath" `
        -Context "LAN forwarder receipt")
    foreach ($asset in @(
        @("Node executable", $nodeExecutablePath),
        @("script", $scriptPath),
        @("configuration", $configPath)
    )) {
        if (-not (Test-Path -LiteralPath $asset[1] -PathType Leaf)) {
            throw "LAN forwarder $($asset[0]) is missing: $($asset[1])"
        }
    }

    $scriptSha256 =
        (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach ($hashProperty in @("sourceSha256", "scriptSha256")) {
        Assert-ForwarderValue `
            -Object $Forwarder `
            -Name $hashProperty `
            -Expected $scriptSha256 `
            -Context "LAN forwarder receipt"
    }
    $configSha256 =
        (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-ForwarderValue `
        -Object $Forwarder `
        -Name "configSha256" `
        -Expected $configSha256 `
        -Context "LAN forwarder receipt"

    $config = Read-JsonFile -Path $configPath
    Assert-ForwarderValue `
        -Object $config `
        -Name "schemaVersion" `
        -Expected $(if ($Profile -ceq "media-only") { 2 } else { 1 }) `
        -Context "LAN forwarder configuration"
    if ($Profile -ceq "media-only") {
        Assert-ForwarderValue `
            -Object $config `
            -Name "profile" `
            -Expected "media-only" `
            -Context "LAN forwarder configuration"
    }
    Assert-ForwarderValue `
        -Object $config `
        -Name "bindAddress" `
        -Expected $ExpectedBindAddress `
        -Context "LAN forwarder configuration"
    Assert-ForwarderValue `
        -Object $config `
        -Name "readinessToken" `
        -Expected $Forwarder.readinessToken `
        -Context "LAN forwarder configuration"
    Assert-PathEquals `
        -Actual ([string]$config.readyFile) `
        -Expected ([string]$Forwarder.statusPath) `
        -Description "LAN forwarder configuration readyFile"

    $expectedListeners = New-LanForwarderListeners `
        -ExpectedAppPort $ExpectedAppPort `
        -ExpectedMinioPort $ExpectedMinioPort `
        -ExpectedLiveKitSignalPort $ExpectedLiveKitSignalPort `
        -ExpectedLiveKitTcpPort $ExpectedLiveKitTcpPort `
        -ExpectedLiveKitUdpPort $ExpectedLiveKitUdpPort `
        -Profile $Profile
    Assert-LanForwarderListeners `
        -Actual $config.listeners `
        -Expected $expectedListeners `
        -Context "LAN forwarder configuration"
    Assert-LanForwarderListeners `
        -Actual $Forwarder.listeners `
        -Expected $expectedListeners `
        -Context "LAN forwarder receipt"
    $expectedLimits = New-LanForwarderLimits
    foreach ($entry in $expectedLimits.GetEnumerator()) {
        Assert-ForwarderValue `
            -Object $config.limits `
            -Name $entry.Key `
            -Expected $entry.Value `
            -Context "LAN forwarder configuration limits"
    }
    if ($Profile -ceq "media-only") {
        $supervisor = Get-LanForwarderSupervisor -Forwarder $Forwarder
        if (-not $supervisor) {
            throw "Media-only LAN forwarder receipt is missing durable supervision"
        }
        Assert-LanForwarderSupervisorRecord `
            -Supervisor $supervisor `
            -Forwarder $Forwarder `
            -CandidateDirectory $CandidateDirectory
    }
}

function Get-ReceiptForwarder {
    param([Parameter(Mandatory)]$Receipt)

    if ($Receipt -is [Collections.IDictionary]) {
        if ($Receipt.Contains("forwarder")) {
            return $Receipt["forwarder"]
        }
        return $null
    }
    $property = $Receipt.PSObject.Properties["forwarder"]
    if (-not $property) {
        return $null
    }
    return $property.Value
}

function Assert-LanForwarderAssets {
    param([Parameter(Mandatory)]$Receipt)

    $schemaVersion = Get-ReceiptSchemaVersion -Receipt $Receipt
    $requiresForwarder = Test-ReceiptRequiresLanForwarder -Receipt $Receipt
    if ($schemaVersion -lt 5) {
        if ($requiresForwarder) {
            throw "Pre-schema-v5 receipts cannot authorize LAN forwarding"
        }
        return
    }
    $forwarder = Get-ReceiptForwarder -Receipt $Receipt
    if (-not $forwarder) {
        throw "Schema-v5 retained release is missing its forwarder record"
    }
    if (-not $requiresForwarder) {
        Assert-ForwarderValue `
            -Object $forwarder `
            -Name "required" `
            -Expected $false `
            -Context "Loopback forwarder receipt"
        return
    }

    $forwarderProfile =
        if (Test-ReceiptIsCloudflareTrustedEdge -Receipt $Receipt) {
            "media-only"
        }
        else {
            "full"
        }
    Assert-LanForwarderRecordAssets `
        -Forwarder $forwarder `
        -CandidateDirectory (Split-Path -Parent ([string]$Receipt.receiptPath)) `
        -ExpectedBindAddress (Get-ReceiptBindAddress -Receipt $Receipt) `
        -ExpectedAppPort ([int]$Receipt.ports.app) `
        -ExpectedMinioPort ([int]$Receipt.ports.minio) `
        -ExpectedLiveKitSignalPort ([int]$Receipt.ports.livekitSignal) `
        -ExpectedLiveKitTcpPort ([int]$Receipt.ports.livekitTcp) `
        -ExpectedLiveKitUdpPort ([int]$Receipt.ports.livekitUdp) `
        -Profile $forwarderProfile
}

function Get-ExactCommandLineValuePattern {
    param(
        [Parameter(Mandatory)][string]$Value
    )

    $escaped = [Regex]::Escape($Value)
    if ($Value -match "\s") {
        return "`"$escaped`""
    }
    return "(?:`"$escaped`"|$escaped)"
}

function Test-LanForwarderCommandLine {
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)]$Forwarder
    )

    $executablePattern =
        Get-ExactCommandLineValuePattern `
            -Value ([IO.Path]::GetFullPath(
                [string]$Forwarder.nodeExecutablePath
            ))
    $scriptPattern =
        Get-ExactCommandLineValuePattern `
            -Value ([IO.Path]::GetFullPath([string]$Forwarder.scriptPath))
    $configPattern =
        Get-ExactCommandLineValuePattern `
            -Value ([IO.Path]::GetFullPath([string]$Forwarder.configPath))
    $pattern = (
        "^\s*" +
        $executablePattern +
        "\s+" +
        $scriptPattern +
        "\s+--config(?:\s+|=)" +
        $configPattern +
        "\s*$"
    )
    return [Regex]::IsMatch(
        $CommandLine,
        $pattern,
        (
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [Text.RegularExpressions.RegexOptions]::CultureInvariant
        )
    )
}

function Get-LanForwarderObservation {
    param([Parameter(Mandatory)]$Receipt)

    $forwarder = Get-ReceiptForwarder -Receipt $Receipt
    if (-not (Test-ReceiptRequiresLanForwarder -Receipt $Receipt)) {
        return [PSCustomObject]@{
            Required = $false
            Status = "not-required"
            ProcessId = 0
            ProcessStartTimeUtc = ""
            ProcessFound = $false
            ProcessMatchesReceipt = $true
            ConfigHashMatchesReceipt = $true
            ListenersMatchReceipt = $true
            Detail = "loopback release"
        }
    }

    $configurationHashMatches = $false
    try {
        $configurationHashMatches =
            (Get-FileHash `
                -LiteralPath ([string]$forwarder.configPath) `
                -Algorithm SHA256).Hash.ToLowerInvariant() -ceq
                    [string]$forwarder.configSha256
    }
    catch {
        $configurationHashMatches = $false
    }
    if (-not (Test-Path -LiteralPath $forwarder.statusPath -PathType Leaf)) {
        return [PSCustomObject]@{
            Required = $true
            Status = "not-ready"
            ProcessId = 0
            ProcessStartTimeUtc = ""
            ProcessFound = $false
            ProcessMatchesReceipt = $false
            ConfigHashMatchesReceipt = $configurationHashMatches
            ListenersMatchReceipt = $false
            Detail = "readiness evidence is missing"
        }
    }

    try {
        $ready = Read-JsonFile -Path $forwarder.statusPath
        $pidValue = [int](Get-RequiredForwarderProperty `
            -Object $ready `
            -Name "pid" `
            -Context "LAN forwarder readiness evidence")
        $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        $processFound = $null -ne $process
        $identityMatches = $false
        if ($processFound) {
            $cimProcess = Get-CimInstance `
                -ClassName Win32_Process `
                -Filter "ProcessId = $pidValue" `
                -ErrorAction Stop
            $commandLine = [string]$cimProcess.CommandLine
            $readyProcessStartValue =
                Get-RequiredForwarderProperty `
                    -Object $ready `
                    -Name "processStartTimeUtc" `
                    -Context "LAN forwarder readiness evidence"
            $readyProcessStart =
                if ($readyProcessStartValue -is [DateTime]) {
                    $readyProcessStartValue.ToUniversalTime()
                }
                else {
                    [DateTimeOffset]::Parse(
                        [string]$readyProcessStartValue,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::AssumeUniversal
                    ).UtcDateTime
                }
            $actualProcessStart = $process.StartTime.ToUniversalTime()
            $processStartMatches =
                [Math]::Abs(
                    ($readyProcessStart - $actualProcessStart).TotalSeconds
                ) -le 5 -and
                $readyProcessStart -le [DateTime]::UtcNow.AddSeconds(1)
            $identityMatches = (
                $processStartMatches -and
                [IO.Path]::GetFullPath([string]$cimProcess.ExecutablePath).Equals(
                    [IO.Path]::GetFullPath([string]$forwarder.nodeExecutablePath),
                    [StringComparison]::OrdinalIgnoreCase
                ) -and
                (Test-LanForwarderCommandLine `
                    -CommandLine $commandLine `
                    -Forwarder $forwarder)
            )
        }

        $forwarderProfileValue = Get-ReceiptTopLevelProperty `
            -Receipt $forwarder `
            -Name "profile" `
            -DefaultValue ""
        $forwarderProfile =
            if ([string]$forwarderProfileValue -ceq "media-only") {
                "media-only"
            }
            else {
                "full"
            }
        $expectedReadySchemaVersion =
            if ($forwarderProfile -ceq "media-only") { 2 } else { 1 }
        $readyProfileMatches =
            if ($forwarderProfile -ceq "media-only") {
                [string](Get-ReceiptTopLevelProperty `
                    -Receipt $ready `
                    -Name "profile" `
                    -DefaultValue "") -ceq "media-only"
            }
            else {
                [string]::IsNullOrEmpty([string](Get-ReceiptTopLevelProperty `
                    -Receipt $ready `
                    -Name "profile" `
                    -DefaultValue ""))
            }
        $readyIdentityMatches = (
            [string]$ready.event -ceq "lan_release_forwarder_ready" -and
            [int]$ready.schemaVersion -eq $expectedReadySchemaVersion -and
            $readyProfileMatches -and
            [string]$ready.bindAddress -ceq
                (Get-ReceiptBindAddress -Receipt $Receipt) -and
            [string]$ready.configSha256 -ceq
                [string]$forwarder.configSha256 -and
            [string]$ready.readinessToken -ceq
                [string]$forwarder.readinessToken
        )
        $expectedListeners = @($forwarder.listeners)
        $readyListenersMatch = $true
        try {
            Assert-LanForwarderListeners `
                -Actual $ready.listeners `
                -Expected $expectedListeners `
                -Context "LAN forwarder readiness evidence"
        }
        catch {
            $readyListenersMatch = $false
        }

        $listenerOwnershipMatches = $processFound
        if ($listenerOwnershipMatches) {
            foreach ($listener in $expectedListeners) {
                $endpoint = @(
                    if ([string]$listener.protocol -ceq "tcp") {
                        Get-NetTCPConnection `
                            -State Listen `
                            -LocalAddress ([string]$ready.bindAddress) `
                            -LocalPort ([int]$listener.publicPort) `
                            -ErrorAction SilentlyContinue |
                        Where-Object { [int]$_.OwningProcess -eq $pidValue }
                    }
                    else {
                        Get-NetUDPEndpoint `
                            -LocalAddress ([string]$ready.bindAddress) `
                            -LocalPort ([int]$listener.publicPort) `
                            -ErrorAction SilentlyContinue |
                        Where-Object { [int]$_.OwningProcess -eq $pidValue }
                    }
                )
                if ($endpoint.Count -ne 1) {
                    $listenerOwnershipMatches = $false
                    break
                }
            }
        }

        $processMatchesReceipt =
            $processFound -and $identityMatches -and $readyIdentityMatches
        $listenersMatchReceipt =
            $readyListenersMatch -and $listenerOwnershipMatches
        [PSCustomObject]@{
            Required = $true
            Status =
                if (
                    $processMatchesReceipt -and
                    $configurationHashMatches -and
                    $listenersMatchReceipt
                ) {
                    "ready"
                }
                else {
                    "not-ready"
                }
            ProcessId = $pidValue
            ProcessStartTimeUtc =
                if ($processFound) {
                    $process.StartTime.ToUniversalTime().ToString("o")
                }
                else {
                    ""
                }
            ProcessFound = $processFound
            ProcessMatchesReceipt = $processMatchesReceipt
            ConfigHashMatchesReceipt = $configurationHashMatches
            ListenersMatchReceipt = $listenersMatchReceipt
            Detail =
                if (
                    $processMatchesReceipt -and
                    $configurationHashMatches -and
                    $listenersMatchReceipt
                ) {
                    "verified"
                }
                else {
                    "readiness identity, asset hash, or listener ownership mismatch"
                }
        }
    }
    catch {
        [PSCustomObject]@{
            Required = $true
            Status = "not-ready"
            ProcessId = 0
            ProcessStartTimeUtc = ""
            ProcessFound = $false
            ProcessMatchesReceipt = $false
            ConfigHashMatchesReceipt = $configurationHashMatches
            ListenersMatchReceipt = $false
            Detail = $_.Exception.Message
        }
    }
}

function Assert-LanForwarderReady {
    param([Parameter(Mandatory)]$Receipt)

    Assert-LanForwarderAssets -Receipt $Receipt
    $observation = Get-LanForwarderObservation -Receipt $Receipt
    if (
        $observation.Required -and
        (
            $observation.Status -cne "ready" -or
            -not $observation.ProcessMatchesReceipt -or
            -not $observation.ConfigHashMatchesReceipt -or
            -not $observation.ListenersMatchReceipt
        )
    ) {
        throw "LAN forwarder is not ready and receipt-bound: $($observation.Detail)"
    }
    return $observation
}

function Get-LanForwarderSupervisorTaskArguments {
    param([Parameter(Mandatory)]$Supervisor)

    foreach ($propertyName in @(
        "managerScriptPath",
        "stateRoot",
        "projectName",
        "expectedReceiptPath",
        "expectedCandidateId",
        "expectedForwarderConfigSha256",
        "readyTimeoutSeconds"
    )) {
        $value = [string](Get-RequiredForwarderProperty `
            -Object $Supervisor `
            -Name $propertyName `
            -Context "LAN forwarder supervisor receipt")
        if ($value.Contains('"')) {
            throw (
                "LAN forwarder supervisor property '$propertyName' contains an " +
                "unsupported quote character"
            )
        }
    }
    @(
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f [string]$Supervisor.managerScriptPath),
        "-Action", "Supervise",
        "-StateRoot", ('"{0}"' -f [string]$Supervisor.stateRoot),
        "-ProjectName", [string]$Supervisor.projectName,
        "-ExpectedReceiptPath",
            ('"{0}"' -f [string]$Supervisor.expectedReceiptPath),
        "-ExpectedCandidateId", [string]$Supervisor.expectedCandidateId,
        "-ExpectedForwarderConfigSha256",
            [string]$Supervisor.expectedForwarderConfigSha256,
        "-ReadyTimeoutSeconds", [string]$Supervisor.readyTimeoutSeconds
    ) -join " "
}

function Test-ScheduledTaskDurationEquals {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][TimeSpan]$Expected
    )

    if (
        $null -eq $Value -or
        [string]::IsNullOrWhiteSpace([string]$Value)
    ) {
        return $false
    }
    try {
        $observed =
            if ($Value -is [TimeSpan]) {
                [TimeSpan]$Value
            }
            else {
                [Xml.XmlConvert]::ToTimeSpan([string]$Value)
            }
        return $observed.Ticks -eq $Expected.Ticks
    }
    catch {
        return $false
    }
}

function ConvertTo-ScheduledTaskUtcDateTimeOffset {
    param([AllowNull()]$Value)

    if (
        $null -eq $Value -or
        [string]::IsNullOrWhiteSpace([string]$Value)
    ) {
        return $null
    }
    try {
        $observed =
            if ($Value -is [DateTimeOffset]) {
                ([DateTimeOffset]$Value).ToUniversalTime()
            }
            elseif ($Value -is [DateTime]) {
                $dateTime = [DateTime]$Value
                if ($dateTime.Kind -eq [DateTimeKind]::Unspecified) {
                    $dateTime = [DateTime]::SpecifyKind(
                        $dateTime,
                        [DateTimeKind]::Local
                    )
                }
                [DateTimeOffset]::new($dateTime).ToUniversalTime()
            }
            else {
                $parsed = [DateTimeOffset]::MinValue
                $styles =
                    [Globalization.DateTimeStyles]::AllowWhiteSpaces -bor
                    [Globalization.DateTimeStyles]::AssumeLocal
                if (
                    -not [DateTimeOffset]::TryParse(
                        [string]$Value,
                        [Globalization.CultureInfo]::InvariantCulture,
                        $styles,
                        [ref]$parsed
                    )
                ) {
                    return $null
                }
                $parsed.ToUniversalTime()
            }
        if ($observed.Year -le 1900) {
            return $null
        }
        return $observed
    }
    catch {
        return $null
    }
}

function Test-ScheduledTaskNamedValue {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$ExpectedName,
        [Parameter(Mandatory)][int]$ExpectedNumber
    )

    if ($null -eq $Value) {
        return $false
    }
    $text = [string]$Value
    if ($text -ceq $ExpectedName) {
        return $true
    }
    $number = 0
    return (
        [int]::TryParse(
            $text,
            [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$number
        ) -and
        $number -eq $ExpectedNumber
    )
}

function Test-ScheduledTaskBoolean {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][bool]$Expected
    )

    return $Value -is [bool] -and [bool]$Value -eq $Expected
}

function Get-LanForwarderSupervisorTaskContractObservation {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)]$Supervisor,
        [AllowNull()]$TaskInfo,
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow
    )

    $now = $NowUtc.ToUniversalTime()
    $identityFailures = [Collections.Generic.List[string]]::new()
    $scheduleFailures = [Collections.Generic.List[string]]::new()
    $operationalFailures = [Collections.Generic.List[string]]::new()
    $actions = @($Task.Actions)
    $expectedPowerShell =
        [IO.Path]::GetFullPath([string]$Supervisor.powerShellExecutablePath)
    $actionMatches = $false
    if ($actions.Count -eq 1) {
        $observedExecutable = [string]$actions[0].Execute
        try {
            $actionMatches = (
                -not [string]::IsNullOrWhiteSpace($observedExecutable) -and
                [IO.Path]::GetFullPath($observedExecutable).Equals(
                    $expectedPowerShell,
                    [StringComparison]::OrdinalIgnoreCase
                ) -and
                [string]$actions[0].Arguments -ceq
                    (Get-LanForwarderSupervisorTaskArguments `
                        -Supervisor $Supervisor) -and
                [string]::IsNullOrWhiteSpace(
                    [string]$actions[0].WorkingDirectory
                )
            )
        }
        catch {
            $actionMatches = $false
        }
    }
    if (-not $actionMatches) {
        $identityFailures.Add("action") | Out-Null
    }
    if ([string]$Task.TaskPath -cne "\") {
        $identityFailures.Add("task path") | Out-Null
    }
    if (
        [string]$Task.Description -cne
            [string]$Supervisor.taskDescription
    ) {
        $identityFailures.Add("description") | Out-Null
    }
    if (
        [string]$Task.Principal.UserId -cne
            [string]$Supervisor.principal -or
        -not (Test-ScheduledTaskNamedValue `
            -Value $Task.Principal.LogonType `
            -ExpectedName "Interactive" `
            -ExpectedNumber 3) -or
        -not (Test-ScheduledTaskNamedValue `
            -Value $Task.Principal.RunLevel `
            -ExpectedName "Limited" `
            -ExpectedNumber 0)
    ) {
        $identityFailures.Add("principal") | Out-Null
    }

    $triggers = @($Task.Triggers)
    $triggerMatches = $false
    if ($triggers.Count -eq 1) {
        $trigger = $triggers[0]
        $expectedStartBoundary =
            ConvertTo-ScheduledTaskUtcDateTimeOffset `
                -Value $Supervisor.taskStartBoundaryUtc
        $observedStartBoundary =
            ConvertTo-ScheduledTaskUtcDateTimeOffset `
                -Value $trigger.StartBoundary
        $scheduleSealedAt =
            ConvertTo-ScheduledTaskUtcDateTimeOffset `
                -Value $Supervisor.scheduleSealedAtUtc
        $startBoundaryMatches = (
            $null -ne $expectedStartBoundary -and
            $null -ne $observedStartBoundary -and
            $null -ne $scheduleSealedAt -and
            $observedStartBoundary.UtcDateTime.Ticks -eq
                $expectedStartBoundary.UtcDateTime.Ticks -and
            (
                $expectedStartBoundary - $scheduleSealedAt
            ).TotalSeconds -eq [int]$Supervisor.startDelaySeconds -and
            $scheduleSealedAt -le
                $now.AddSeconds([int]$Supervisor.nextRunGraceSeconds) -and
            $expectedStartBoundary -le
                $now.AddSeconds([int]$Supervisor.nextRunGraceSeconds) -and
            $expectedStartBoundary.AddDays(
                [int]$Supervisor.repetitionDurationDays
            ) -gt $now
        )
        $triggerMatches = (
            [string]$trigger.CimClass.CimClassName -ceq
                "MSFT_TaskTimeTrigger" -and
            (Test-ScheduledTaskBoolean `
                -Value $trigger.Enabled `
                -Expected $true) -and
            $startBoundaryMatches -and
            [string]::IsNullOrWhiteSpace([string]$trigger.EndBoundary) -and
            (Test-ScheduledTaskDurationEquals `
                -Value $trigger.Repetition.Interval `
                -Expected (
                    New-TimeSpan -Seconds (
                        [int]$Supervisor.intervalSeconds
                    )
                )) -and
            (Test-ScheduledTaskDurationEquals `
                -Value $trigger.Repetition.Duration `
                -Expected (
                    New-TimeSpan -Days (
                        [int]$Supervisor.repetitionDurationDays
                    )
                )) -and
            (Test-ScheduledTaskBoolean `
                -Value $trigger.Repetition.StopAtDurationEnd `
                -Expected $true)
        )
    }
    if (-not $triggerMatches) {
        $scheduleFailures.Add(
            "enabled active receipt-bound repeating time trigger"
        ) | Out-Null
    }
    $settings = $Task.Settings
    $settingsMatch = (
        (Test-ScheduledTaskBoolean `
            -Value $settings.Enabled `
            -Expected $true) -and
        (Test-ScheduledTaskNamedValue `
            -Value $settings.MultipleInstances `
            -ExpectedName "IgnoreNew" `
            -ExpectedNumber 2) -and
        [int]$settings.RestartCount -eq 3 -and
        (Test-ScheduledTaskDurationEquals `
            -Value $settings.RestartInterval `
            -Expected (New-TimeSpan -Seconds 30)) -and
        (Test-ScheduledTaskDurationEquals `
            -Value $settings.ExecutionTimeLimit `
            -Expected (New-TimeSpan -Minutes 2)) -and
        (Test-ScheduledTaskBoolean `
            -Value $settings.StartWhenAvailable `
            -Expected $true) -and
        (Test-ScheduledTaskBoolean `
            -Value $settings.AllowDemandStart `
            -Expected $true) -and
        (Test-ScheduledTaskBoolean `
            -Value $settings.DisallowStartIfOnBatteries `
            -Expected $false) -and
        (Test-ScheduledTaskBoolean `
            -Value $settings.StopIfGoingOnBatteries `
            -Expected $false)
    )
    if (-not $settingsMatch) {
        $scheduleFailures.Add("enabled restart and execution settings") |
            Out-Null
    }
    $nextRunTime =
        if (
            $null -ne $TaskInfo -and
            $TaskInfo.PSObject.Properties["NextRunTime"]
        ) {
            ConvertTo-ScheduledTaskUtcDateTimeOffset `
                -Value $TaskInfo.NextRunTime
        }
        else {
            $null
        }
    $nextRunMatches = (
        $null -ne $nextRunTime -and
        $nextRunTime -ge
            $now.AddSeconds(-[int]$Supervisor.nextRunGraceSeconds) -and
        $nextRunTime -le $now.AddSeconds(
            [int]$Supervisor.intervalSeconds +
            [int]$Supervisor.nextRunGraceSeconds
        )
    )
    if (-not $nextRunMatches) {
        $scheduleFailures.Add("bounded next run") | Out-Null
    }
    $operationalStateReady = (
        (Test-ScheduledTaskNamedValue `
            -Value $Task.State `
            -ExpectedName "Ready" `
            -ExpectedNumber 3) -or
        (Test-ScheduledTaskNamedValue `
            -Value $Task.State `
            -ExpectedName "Running" `
            -ExpectedNumber 4)
    )
    if (-not $operationalStateReady) {
        $operationalFailures.Add("operational state") | Out-Null
    }
    $identityMatches = $identityFailures.Count -eq 0
    $scheduleMatches = $scheduleFailures.Count -eq 0
    $matches =
        $identityMatches -and $scheduleMatches -and $operationalStateReady
    $failures = @(
        @($identityFailures) +
        @($scheduleFailures) +
        @($operationalFailures)
    )
    return [PSCustomObject]@{
        Required = $true
        Status = if ($matches) { "ready" } else { "not-ready" }
        MatchesReceipt = $matches
        IdentityMatchesReceipt = $identityMatches
        ScheduleMatchesReceipt = $scheduleMatches
        OperationalStateReady = $operationalStateReady
        Detail =
            if ($matches) {
                "verified"
            }
            else {
                "scheduled supervisor task mismatch: " + ($failures -join ", ")
            }
    }
}

function Get-LanForwarderSupervisorTaskObservation {
    param([Parameter(Mandatory)]$Receipt)

    if (-not (Test-ReceiptIsCloudflareTrustedEdge -Receipt $Receipt)) {
        return [PSCustomObject]@{
            Required = $false
            Status = "not-required"
            MatchesReceipt = $true
            IdentityMatchesReceipt = $true
            ScheduleMatchesReceipt = $true
            OperationalStateReady = $true
            Detail = "non-trusted-edge release"
        }
    }
    try {
        Assert-LanForwarderAssets -Receipt $Receipt
        $forwarder = Get-ReceiptForwarder -Receipt $Receipt
        $supervisor = Get-LanForwarderSupervisor -Forwarder $forwarder
        $task = Get-ScheduledTask `
            -TaskPath "\" `
            -TaskName ([string]$supervisor.taskName) `
            -ErrorAction SilentlyContinue
        if (-not $task) {
            return [PSCustomObject]@{
                Required = $true
                Status = "not-ready"
                MatchesReceipt = $false
                IdentityMatchesReceipt = $false
                ScheduleMatchesReceipt = $false
                OperationalStateReady = $false
                Detail = "scheduled supervisor task is missing"
            }
        }
        $taskInfo = $null
        try {
            $taskInfo = Get-ScheduledTaskInfo `
                -TaskPath "\" `
                -TaskName ([string]$supervisor.taskName) `
                -ErrorAction Stop
        }
        catch {
            # The pure contract treats missing runtime information as schedule
            # drift while retaining independently proven task ownership.
            $taskInfo = $null
        }
        return (Get-LanForwarderSupervisorTaskContractObservation `
            -Task $task `
            -Supervisor $supervisor `
            -TaskInfo $taskInfo `
            -NowUtc ([DateTimeOffset]::UtcNow))
    }
    catch {
        return [PSCustomObject]@{
            Required = $true
            Status = "not-ready"
            MatchesReceipt = $false
            IdentityMatchesReceipt = $false
            ScheduleMatchesReceipt = $false
            OperationalStateReady = $false
            Detail = $_.Exception.Message
        }
    }
}

function Assert-LanForwarderSupervisorTaskReady {
    param([Parameter(Mandatory)]$Receipt)

    $observation =
        Get-LanForwarderSupervisorTaskObservation -Receipt $Receipt
    if (
        $observation.Required -and
        (
            $observation.Status -cne "ready" -or
            -not $observation.MatchesReceipt
        )
    ) {
        throw (
            "LAN forwarder supervisor task is not receipt-bound and ready: " +
            $observation.Detail
        )
    }
    return $observation
}

function Unregister-LanForwarderSupervisor {
    param(
        [Parameter(Mandatory)]$Receipt,
        [switch]$AllowNotRegistered
    )

    if (-not (Test-ReceiptIsCloudflareTrustedEdge -Receipt $Receipt)) {
        return
    }
    Assert-LanForwarderAssets -Receipt $Receipt
    $forwarder = Get-ReceiptForwarder -Receipt $Receipt
    $supervisor = Get-LanForwarderSupervisor -Forwarder $forwarder
    $task = Get-ScheduledTask `
        -TaskPath "\" `
        -TaskName ([string]$supervisor.taskName) `
        -ErrorAction SilentlyContinue
    if (-not $task) {
        if ($AllowNotRegistered) {
            return
        }
        throw "LAN forwarder supervisor task is missing"
    }
    $observation =
        Get-LanForwarderSupervisorTaskObservation -Receipt $Receipt
    if (-not $observation.IdentityMatchesReceipt) {
        throw (
            "Refusing to remove a LAN forwarder supervisor task that does not " +
            "match the retained receipt: $($observation.Detail)"
        )
    }
    Stop-ScheduledTask `
        -TaskPath "\" `
        -TaskName ([string]$supervisor.taskName) `
        -ErrorAction SilentlyContinue
    Unregister-ScheduledTask `
        -TaskPath "\" `
        -TaskName ([string]$supervisor.taskName) `
        -Confirm:$false `
        -ErrorAction Stop
}

function Register-LanForwarderSupervisor {
    param([Parameter(Mandatory)]$Receipt)

    if (-not (Test-ReceiptIsCloudflareTrustedEdge -Receipt $Receipt)) {
        return (
            Get-LanForwarderSupervisorTaskObservation -Receipt $Receipt
        )
    }
    Assert-LanForwarderAssets -Receipt $Receipt
    $forwarder = Get-ReceiptForwarder -Receipt $Receipt
    $supervisor = Get-LanForwarderSupervisor -Forwarder $forwarder
    $existing = Get-ScheduledTask `
        -TaskPath "\" `
        -TaskName ([string]$supervisor.taskName) `
        -ErrorAction SilentlyContinue
    if ($existing) {
        $observation =
            Get-LanForwarderSupervisorTaskObservation -Receipt $Receipt
        if (-not $observation.IdentityMatchesReceipt) {
            throw (
                "Refusing to replace a same-name Windows Scheduled Task that is " +
                "not owned by this exact K-Comms receipt"
            )
        }
        Unregister-LanForwarderSupervisor `
            -Receipt $Receipt `
            -AllowNotRegistered
    }

    $powerShell = [string]$supervisor.powerShellExecutablePath
    if (
        -not [IO.Path]::IsPathRooted($powerShell) -or
        -not (Test-Path -LiteralPath $powerShell -PathType Leaf)
    ) {
        throw (
            "LAN forwarder supervisor PowerShell executable is missing: " +
            $powerShell
        )
    }
    $action = New-ScheduledTaskAction `
        -Execute $powerShell `
        -Argument (
            Get-LanForwarderSupervisorTaskArguments -Supervisor $supervisor
        )
    $taskStartBoundary =
        ConvertTo-ScheduledTaskUtcDateTimeOffset `
            -Value $supervisor.taskStartBoundaryUtc
    if ($null -eq $taskStartBoundary) {
        throw "LAN forwarder supervisor task start boundary is invalid"
    }
    $trigger = New-ScheduledTaskTrigger `
        -Once `
        -At $taskStartBoundary.LocalDateTime `
        -RepetitionInterval (
            New-TimeSpan -Seconds ([int]$supervisor.intervalSeconds)
        ) `
        -RepetitionDuration (
            New-TimeSpan -Days ([int]$supervisor.repetitionDurationDays)
        )
    $trigger.Repetition.StopAtDurationEnd = $true
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Seconds 30) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    $principal = New-ScheduledTaskPrincipal `
        -UserId ([string]$supervisor.principal) `
        -LogonType Interactive `
        -RunLevel Limited
    Register-ScheduledTask `
        -TaskPath "\" `
        -TaskName ([string]$supervisor.taskName) `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description ([string]$supervisor.taskDescription) `
        -Force | Out-Null
    return (Assert-LanForwarderSupervisorTaskReady -Receipt $Receipt)
}

function Assert-LanForwarderSupervisorInvocation {
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][string]$CandidateId,
        [Parameter(Mandatory)][string]$ForwarderConfigSha256
    )

    $forwarder = Get-ReceiptForwarder -Receipt $Receipt
    $supervisor = Get-LanForwarderSupervisor -Forwarder $forwarder
    foreach ($comparison in @(
        @(
            "receipt path",
            [IO.Path]::GetFullPath($ReceiptPath),
            [IO.Path]::GetFullPath([string]$supervisor.expectedReceiptPath)
        ),
        @(
            "candidate identity",
            $CandidateId,
            [string]$supervisor.expectedCandidateId
        ),
        @(
            "forwarder configuration hash",
            $ForwarderConfigSha256,
            [string]$supervisor.expectedForwarderConfigSha256
        ),
        @(
            "receipt forwarder configuration hash",
            [string]$forwarder.configSha256,
            [string]$supervisor.expectedForwarderConfigSha256
        ),
        @(
            "receipt candidate identity",
            [string]$Receipt.candidateId,
            [string]$supervisor.expectedCandidateId
        )
    )) {
        if ($comparison[1] -cne $comparison[2]) {
            throw (
                "LAN forwarder supervisor invocation does not match the sealed " +
                "$($comparison[0])"
            )
        }
    }
}

function Repair-LanForwarderIfNeeded {
    param([Parameter(Mandatory)]$Receipt)

    Assert-LanForwarderAssets -Receipt $Receipt
    if (-not (Test-ReceiptIsCloudflareTrustedEdge -Receipt $Receipt)) {
        throw "Durable LAN forwarder supervision is limited to trusted-edge media"
    }
    $observation = Get-LanForwarderObservation -Receipt $Receipt
    if ($observation.Status -ceq "ready") {
        return $observation
    }
    $null = Start-LanForwarder -Receipt $Receipt
    return (Assert-LanForwarderReady -Receipt $Receipt)
}

function Stop-OwnedLanForwarderProcess {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][DateTime]$ExpectedStartTimeUtc,
        [Parameter(Mandatory)][string]$Description
    )

    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            $observedStartTime = $Process.StartTime.ToUniversalTime()
            if ($observedStartTime.Ticks -ne $ExpectedStartTimeUtc.ToUniversalTime().Ticks) {
                throw (
                    "Refusing to stop $Description because its process start " +
                    "identity changed"
                )
            }
            $Process.Kill()
            $null = $Process.WaitForExit(10000)
            $Process.Refresh()
            if (-not $Process.HasExited) {
                throw "$Description did not exit"
            }
        }
    }
    finally {
        $Process.Dispose()
    }
}

function Get-LanForwarderCommandProcesses {
    param([Parameter(Mandatory)]$Forwarder)

    $matches = [Collections.Generic.List[object]]::new()
    $expectedExecutable =
        [IO.Path]::GetFullPath([string]$Forwarder.nodeExecutablePath)
    foreach ($candidate in @(
        Get-CimInstance -ClassName Win32_Process -ErrorAction Stop
    )) {
        if (
            [string]::IsNullOrWhiteSpace([string]$candidate.ExecutablePath) -or
            [string]::IsNullOrWhiteSpace([string]$candidate.CommandLine)
        ) {
            continue
        }
        if (-not [IO.Path]::GetFullPath([string]$candidate.ExecutablePath).Equals(
            $expectedExecutable,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            continue
        }
        if (Test-LanForwarderCommandLine `
            -CommandLine ([string]$candidate.CommandLine) `
            -Forwarder $Forwarder) {
            $matches.Add($candidate)
        }
    }
    return @($matches)
}

function Get-VerifiedLanForwarderCommandProcess {
    param(
        [Parameter(Mandatory)]$Forwarder,
        [Parameter(Mandatory)][int]$ProcessId
    )

    $freshCimProcess = Get-CimInstance `
        -ClassName Win32_Process `
        -Filter "ProcessId = $ProcessId" `
        -ErrorAction Stop
    if (-not $freshCimProcess) {
        throw "LAN forwarder process $ProcessId disappeared during verification"
    }
    $expectedExecutable =
        [IO.Path]::GetFullPath([string]$Forwarder.nodeExecutablePath)
    if (
        [string]::IsNullOrWhiteSpace([string]$freshCimProcess.ExecutablePath) -or
        -not [IO.Path]::GetFullPath(
            [string]$freshCimProcess.ExecutablePath
        ).Equals(
            $expectedExecutable,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (Test-LanForwarderCommandLine `
            -CommandLine ([string]$freshCimProcess.CommandLine) `
            -Forwarder $Forwarder)
    ) {
        throw "LAN forwarder process $ProcessId command identity changed"
    }

    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $processStartTimeUtc = $process.StartTime.ToUniversalTime()
    $cimStartTimeUtc =
        ([DateTime]$freshCimProcess.CreationDate).ToUniversalTime()
    if (
        [Math]::Abs(
            ($processStartTimeUtc - $cimStartTimeUtc).TotalSeconds
        ) -gt 2
    ) {
        $process.Dispose()
        throw "LAN forwarder process $ProcessId start identity changed"
    }
    [PSCustomObject]@{
        Process = $process
        StartTimeUtc = $processStartTimeUtc
    }
}

function Get-LanForwarderOwnedEndpoints {
    param(
        [Parameter(Mandatory)]$Receipt,
        [int]$ProcessId = 0
    )

    $forwarder = Get-ReceiptForwarder -Receipt $Receipt
    $bindAddress = Get-ReceiptBindAddress -Receipt $Receipt
    $endpoints = [Collections.Generic.List[object]]::new()
    foreach ($listener in @($forwarder.listeners)) {
        $observed =
            if ([string]$listener.protocol -ceq "tcp") {
                @(
                    Get-NetTCPConnection `
                        -State Listen `
                        -LocalAddress $bindAddress `
                        -LocalPort ([int]$listener.publicPort) `
                        -ErrorAction SilentlyContinue
                )
            }
            else {
                @(
                    Get-NetUDPEndpoint `
                        -LocalAddress $bindAddress `
                        -LocalPort ([int]$listener.publicPort) `
                        -ErrorAction SilentlyContinue
                )
            }
        foreach ($endpoint in $observed) {
            if ($ProcessId -eq 0 -or [int]$endpoint.OwningProcess -eq $ProcessId) {
                $endpoints.Add([PSCustomObject]@{
                    Name = [string]$listener.name
                    Protocol = [string]$listener.protocol
                    Port = [int]$listener.publicPort
                    OwningProcess = [int]$endpoint.OwningProcess
                })
            }
        }
    }
    return @($endpoints)
}

function Assert-LanForwarderPortsReleased {
    param([Parameter(Mandatory)]$Receipt)

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $remaining = @(Get-LanForwarderOwnedEndpoints -Receipt $Receipt)
        if ($remaining.Count -eq 0) {
            return
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            $descriptions = @(
                $remaining |
                    ForEach-Object {
                        "$($_.Protocol):$($_.Port) pid=$($_.OwningProcess)"
                    }
            )
            throw (
                "LAN forwarder public listeners remain after stop: " +
                ($descriptions -join ", ")
            )
        }
        Start-Sleep -Milliseconds 200
    } while ($true)
}

function Stop-LanForwarder {
    param(
        [Parameter(Mandatory)]$Receipt,
        [switch]$AllowNotRunning
    )

    Assert-LanForwarderAssets -Receipt $Receipt
    if (-not (Test-ReceiptRequiresLanForwarder -Receipt $Receipt)) {
        return
    }
    $forwarder = Get-ReceiptForwarder -Receipt $Receipt
    $statusExists =
        Test-Path -LiteralPath $forwarder.statusPath -PathType Leaf
    $observation =
        if ($statusExists) {
            Get-LanForwarderObservation -Receipt $Receipt
        }
        else {
            $null
        }
    $commandProcesses = @(Get-LanForwarderCommandProcesses -Forwarder $forwarder)
    if ($commandProcesses.Count -gt 1) {
        throw "Multiple exact-command LAN forwarder processes were found"
    }

    $receiptBoundProcess = (
        $observation -and
        $observation.ProcessFound -and
        $observation.ProcessMatchesReceipt -and
        $observation.ConfigHashMatchesReceipt
    )
    if ($receiptBoundProcess) {
        if (
            $commandProcesses.Count -ne 1 -or
            [int]$commandProcesses[0].ProcessId -ne
                [int]$observation.ProcessId
        ) {
            throw (
                "Refusing to stop process $($observation.ProcessId) because " +
                "fresh exact-command discovery does not match READY evidence"
            )
        }
        $verifiedProcess = Get-VerifiedLanForwarderCommandProcess `
            -Forwarder $forwarder `
            -ProcessId $observation.ProcessId
        $recordedProcessStartTime = [DateTime]::Parse(
            [string]$observation.ProcessStartTimeUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        if (
            $verifiedProcess.StartTimeUtc.Ticks -ne
                $recordedProcessStartTime.Ticks
        ) {
            $verifiedProcess.Process.Dispose()
            throw (
                "Refusing to stop process $($observation.ProcessId) because its " +
                "start identity changed after readiness verification"
            )
        }
        Stop-OwnedLanForwarderProcess `
            -Process $verifiedProcess.Process `
            -ExpectedStartTimeUtc $verifiedProcess.StartTimeUtc `
            -Description "LAN forwarder process $($observation.ProcessId)"
    }
    elseif ($commandProcesses.Count -eq 1) {
        $exactProcessId = [int]$commandProcesses[0].ProcessId
        $foreignEndpoints = @(
            Get-LanForwarderOwnedEndpoints -Receipt $Receipt |
                Where-Object {
                    [int]$_.OwningProcess -ne $exactProcessId
                }
        )
        if ($foreignEndpoints.Count -gt 0) {
            throw (
                "Refusing to replace stale LAN forwarder readiness because " +
                "one or more public listener ports are owned by another process"
            )
        }
        $verifiedProcess = Get-VerifiedLanForwarderCommandProcess `
            -Forwarder $forwarder `
            -ProcessId $exactProcessId
        Stop-OwnedLanForwarderProcess `
            -Process $verifiedProcess.Process `
            -ExpectedStartTimeUtc $verifiedProcess.StartTimeUtc `
            -Description (
                "stale-evidence LAN forwarder process $exactProcessId"
            )
    }
    else {
        $unownedEndpoints = @(Get-LanForwarderOwnedEndpoints -Receipt $Receipt)
        if ($unownedEndpoints.Count -gt 0) {
            throw (
                "LAN forwarder readiness evidence is missing or stale while " +
                "public listener ports remain occupied"
            )
        }
        Remove-Item `
            -LiteralPath $forwarder.statusPath `
            -Force `
            -ErrorAction SilentlyContinue
        if ($AllowNotRunning) {
            return
        }
        if ($statusExists) {
            throw (
                "LAN forwarder readiness evidence is stale and no exact-command " +
                "forwarder process is running"
            )
        }
        throw "LAN forwarder readiness evidence is missing"
    }
    Remove-Item `
        -LiteralPath $forwarder.statusPath `
        -Force `
        -ErrorAction SilentlyContinue
    Assert-LanForwarderPortsReleased -Receipt $Receipt
}

function Start-LanForwarder {
    param([Parameter(Mandatory)]$Receipt)

    Assert-LanForwarderAssets -Receipt $Receipt
    if (-not (Test-ReceiptRequiresLanForwarder -Receipt $Receipt)) {
        return (Get-LanForwarderObservation -Receipt $Receipt)
    }
    $forwarder = Get-ReceiptForwarder -Receipt $Receipt
    Stop-LanForwarder -Receipt $Receipt -AllowNotRunning
    foreach ($path in @(
        [string]$forwarder.statusPath,
        [string]$forwarder.stdoutLogPath,
        [string]$forwarder.stderrLogPath
    )) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }

    $argumentList = (
        '"{0}" --config "{1}"' -f
            [string]$forwarder.scriptPath,
            [string]$forwarder.configPath
    )
    $process = Start-Process `
        -FilePath ([string]$forwarder.nodeExecutablePath) `
        -ArgumentList $argumentList `
        -WindowStyle Hidden `
        -RedirectStandardOutput ([string]$forwarder.stdoutLogPath) `
        -RedirectStandardError ([string]$forwarder.stderrLogPath) `
        -PassThru
    $startedProcessTimeUtc = $process.StartTime.ToUniversalTime()
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
        do {
            $process.Refresh()
            if ($process.HasExited) {
                $stderr =
                    if (Test-Path -LiteralPath $forwarder.stderrLogPath) {
                        (Get-Content `
                            -LiteralPath $forwarder.stderrLogPath `
                            -Raw `
                            -ErrorAction SilentlyContinue).Trim()
                    }
                    else {
                        ""
                    }
                throw (
                    "LAN forwarder exited before readiness with code " +
                    "$($process.ExitCode): $stderr"
                )
            }
            if (Test-Path -LiteralPath $forwarder.statusPath -PathType Leaf) {
                $observation = Get-LanForwarderObservation -Receipt $Receipt
                if ($observation.Status -ceq "ready") {
                    return $observation
                }
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                throw (
                    "LAN forwarder did not become ready within " +
                    "$ReadyTimeoutSeconds seconds"
                )
            }
            Start-Sleep -Milliseconds 250
        } while ($true)
    }
    catch {
        $startError = $_
        $cleanupFailures = [Collections.Generic.List[string]]::new()
        try {
            Stop-OwnedLanForwarderProcess `
                -Process $process `
                -ExpectedStartTimeUtc $startedProcessTimeUtc `
                -Description "failed LAN forwarder candidate"
        }
        catch {
            $cleanupFailures.Add($_.Exception.Message)
        }
        Remove-Item `
            -LiteralPath $forwarder.statusPath `
            -Force `
            -ErrorAction SilentlyContinue
        try {
            Assert-LanForwarderPortsReleased -Receipt $Receipt
        }
        catch {
            $cleanupFailures.Add($_.Exception.Message)
        }
        if ($cleanupFailures.Count -gt 0) {
            throw (
                "LAN forwarder start failed and cleanup could not prove every " +
                "public listener closed. Start: $($startError.Exception.Message) " +
                "Cleanup: $($cleanupFailures -join ' | ')"
            )
        }
        throw $startError
    }
}

function Assert-RetainedReleaseAssets {
    param([Parameter(Mandatory)]$Receipt)

    $schemaVersion = Assert-SupportedReceiptSchemaVersion -Receipt $Receipt
    if (-not (Test-Path -LiteralPath $Receipt.environmentFile -PathType Leaf)) {
        throw "Retained release environment is missing: $($Receipt.environmentFile)"
    }
    $environmentHash =
        (Get-FileHash -LiteralPath $Receipt.environmentFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($environmentHash -ne $Receipt.environmentSha256) {
        throw "Retained release environment hash does not match its receipt"
    }
    $retainedEnvironment = Read-EnvironmentFile -Path $Receipt.environmentFile
    if (
        $schemaVersion -ge 5 -and
        (
            -not $retainedEnvironment.Contains("K_COMMS_PODMAN_BIND_ADDRESS") -or
            [string]$retainedEnvironment["K_COMMS_PODMAN_BIND_ADDRESS"] -cne
                $podmanBindAddress
        )
    ) {
        throw (
            "Retained release Podman exposure is not hash-bound to exact loopback " +
            "$podmanBindAddress"
        )
    }
    if (
        $schemaVersion -ge 5 -and
        $retainedEnvironment.Contains("K_COMMS_RELEASE_BIND_ADDRESS")
    ) {
        throw (
            "Schema-v5 release environment must not retain the legacy direct-bind " +
            "variable K_COMMS_RELEASE_BIND_ADDRESS"
        )
    }
    if (
        $schemaVersion -ge 6 -and
        (Test-ReceiptIsCloudflareTrustedEdge -Receipt $Receipt)
    ) {
        $topology = Resolve-ReceiptNetworkTopology -Receipt $Receipt
        $expectedTopologyEnvironment = [ordered]@{
            K_COMMS_PODMAN_BIND_ADDRESS = $podmanBindAddress
            K_COMMS_RELEASE_HOST = $topology.PublicHost
            K_COMMS_LIVEKIT_NODE_IP = $topology.MediaNodeAddress
            K_COMMS_LOCAL_RELEASE_HOST = $topology.MediaNodeAddress
            K_COMMS_RELEASE_EXPOSURE_MODE =
                $cloudflareTrustedEdgeProfile
            K_COMMS_TRUSTED_EDGE_CONFIRMATION =
                $cloudflareTrustedEdgeConfirmation
            PHX_HOST = $topology.PublicHost
            PUBLIC_APP_URL = $topology.PublicAppUrl
            CORS_ORIGINS = $topology.PublicAppUrl
            HSTS_ENABLED = "true"
            LIVEKIT_SERVER_URL = $topology.LiveKitOrigin
            S3_PUBLIC_ENDPOINT = $topology.ObjectOrigin
            MINIO_API_CORS_ALLOW_ORIGIN = $topology.PublicAppUrl
            CSP_CONNECT_SOURCES =
                "'self' $($topology.LiveKitOrigin) $($topology.ObjectOrigin)"
            TRUSTED_PROXY_CIDRS = $topology.TrustedProxyCidr
        }
        foreach ($entry in $expectedTopologyEnvironment.GetEnumerator()) {
            if (
                -not $retainedEnvironment.Contains($entry.Key) -or
                [string]$retainedEnvironment[$entry.Key] -cne
                    [string]$entry.Value
            ) {
                throw (
                    "Retained schema-v6 trusted-edge environment topology does " +
                    "not match its receipt for $($entry.Key)"
                )
            }
        }
    }
    elseif ($schemaVersion -ge 5) {
        $recordedBindAddress = Get-ReceiptBindAddress -Receipt $Receipt
        $recordedPublicHost = Get-ReceiptPublicHost -Receipt $Receipt
        $expectedRuntimeHost =
            if ($recordedBindAddress -ceq $podmanBindAddress) {
                ""
            }
            else {
                $recordedPublicHost
            }
        $appOrigin = "http://$recordedPublicHost`:$($Receipt.ports.app)"
        $browserOrigins =
            if ($recordedBindAddress -ceq $podmanBindAddress) {
                "$appOrigin,http://localhost:$($Receipt.ports.app)"
            }
            else {
                $appOrigin
            }
        $expectedTopologyEnvironment = [ordered]@{
            K_COMMS_PODMAN_BIND_ADDRESS = $podmanBindAddress
            K_COMMS_RELEASE_HOST = $recordedPublicHost
            K_COMMS_LOCAL_RELEASE_HOST = $expectedRuntimeHost
            PHX_HOST = $recordedPublicHost
            PUBLIC_APP_URL = $appOrigin
            CORS_ORIGINS = $browserOrigins
            LIVEKIT_SERVER_URL =
                "ws://$recordedPublicHost`:$($Receipt.ports.livekitSignal)"
            S3_PUBLIC_ENDPOINT =
                "http://$recordedPublicHost`:$($Receipt.ports.minio)"
            MINIO_API_CORS_ALLOW_ORIGIN = $browserOrigins
            CSP_CONNECT_SOURCES =
                "'self' $appOrigin ws://$recordedPublicHost`:$($Receipt.ports.app) " +
                "ws://$recordedPublicHost`:$($Receipt.ports.livekitSignal) " +
                "http://$recordedPublicHost`:$($Receipt.ports.minio)"
        }
        foreach ($entry in $expectedTopologyEnvironment.GetEnumerator()) {
            if (
                -not $retainedEnvironment.Contains($entry.Key) -or
                [string]$retainedEnvironment[$entry.Key] -cne
                    [string]$entry.Value
            ) {
                throw (
                    "Retained schema-v5 release environment topology does not " +
                    "match its receipt for $($entry.Key)"
                )
            }
        }
    }
    if ($retainedEnvironment.Contains("K_COMMS_RELEASE_BIND_ADDRESS")) {
        $recordedBindAddress = Get-ReceiptBindAddress -Receipt $Receipt
        $recordedPublicHost = Get-ReceiptPublicHost -Receipt $Receipt
        $expectedRuntimeHost =
            if ($recordedBindAddress -eq "127.0.0.1") {
                ""
            }
            else {
                $recordedPublicHost
            }
        if (
            [string]$retainedEnvironment["K_COMMS_RELEASE_BIND_ADDRESS"] -cne
                $recordedBindAddress -or
            [string]$retainedEnvironment["K_COMMS_RELEASE_HOST"] -cne
                $recordedPublicHost -or
            [string]$retainedEnvironment["K_COMMS_LOCAL_RELEASE_HOST"] -cne
                $expectedRuntimeHost -or
            [string]$retainedEnvironment["PUBLIC_APP_URL"] -cne
                (Get-ReceiptPublicAppUrl -Receipt $Receipt)
        ) {
            throw "Retained release network topology does not match its hash-bound environment"
        }
    }
    if (-not (Test-Path -LiteralPath $Receipt.composeSourcePath -PathType Leaf)) {
        throw "Retained release Compose source is missing: $($Receipt.composeSourcePath)"
    }
    $composeHash =
        (Get-FileHash -LiteralPath $Receipt.composeSourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($composeHash -ne $Receipt.composeSourceSha256) {
        throw "Retained release Compose source hash does not match its receipt"
    }
    if (-not (Test-Path -LiteralPath $Receipt.renderedConfigPath -PathType Leaf)) {
        throw "Retained rendered configuration is missing: $($Receipt.renderedConfigPath)"
    }
    $configHash =
        (Get-FileHash -LiteralPath $Receipt.renderedConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($configHash -ne $Receipt.renderedConfigSha256) {
        throw "Retained rendered configuration hash does not match its receipt"
    }

    if ($schemaVersion -ge 3) {
        if (-not (Test-Path -LiteralPath $Receipt.sourceArchivePath -PathType Leaf)) {
            throw "Retained immutable source archive is missing: $($Receipt.sourceArchivePath)"
        }
        $sourceArchiveHash =
            (Get-FileHash -LiteralPath $Receipt.sourceArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sourceArchiveHash -ne $Receipt.sourceArchiveSha256) {
            throw "Retained immutable source archive hash does not match its receipt"
        }
    }
    Assert-LanForwarderAssets -Receipt $Receipt
}

function Assert-ImmutableRestartReceipt {
    param([Parameter(Mandatory)]$Receipt)

    Assert-RetainedReleaseAssets -Receipt $Receipt
    $schemaVersionProperty = $Receipt.PSObject.Properties["schemaVersion"]
    if (-not $schemaVersionProperty -or [int]$schemaVersionProperty.Value -lt 3) {
        throw (
            "Start requires a schema-v3-or-newer immutable-source receipt. " +
            "Deploy the clean committed candidate once before using Start."
        )
    }
}

function Test-BindAddressPortAvailable {
    param(
        [Parameter(Mandatory)][Net.IPAddress]$Address,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)]
        [ValidateSet("tcp", "udp")]
        [string]$Protocol
    )

    $socket = $null
    try {
        $socketType =
            if ($Protocol -eq "tcp") {
                [Net.Sockets.SocketType]::Stream
            }
            else {
                [Net.Sockets.SocketType]::Dgram
            }
        $protocolType =
            if ($Protocol -eq "tcp") {
                [Net.Sockets.ProtocolType]::Tcp
            }
            else {
                [Net.Sockets.ProtocolType]::Udp
            }
        $socket = [Net.Sockets.Socket]::new(
            [Net.Sockets.AddressFamily]::InterNetwork,
            $socketType,
            $protocolType
        )
        $socket.ExclusiveAddressUse = $true
        $socket.Bind([Net.IPEndPoint]::new($Address, $Port))
        if ($Protocol -eq "tcp") {
            $socket.Listen(1)
        }
        $true
    }
    catch [Net.Sockets.SocketException] {
        $false
    }
    finally {
        if ($socket) {
            $socket.Dispose()
        }
    }
}

function Get-RunningRetainedServices {
    param([Parameter(Mandatory)]$Receipt)

    Assert-RetainedReleaseAssets -Receipt $Receipt
    $result = Invoke-Compose `
        -EnvironmentFile $Receipt.environmentFile `
        -ComposeProject $Receipt.projectName `
        -ComposePath $Receipt.composeSourcePath `
        -Arguments @("ps", "--services", "--status", "running") `
        -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "Could not inspect retained release services before port preflight"
    }

    $knownServices = @(
        "app",
        "bootstrap",
        "qualification",
        "migrate",
        "minio-init",
        "livekit",
        "minio",
        "postgres"
    )
    @(
        $result.Output -split "\r?\n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $knownServices -contains $_ }
    )
}

function Test-RetainedServiceOwnsPort {
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][int]$ContainerPort,
        [Parameter(Mandatory)]
        [ValidateSet("tcp", "udp")]
        [string]$Protocol,
        [Parameter(Mandatory)][string]$ExpectedBindAddress,
        [Parameter(Mandatory)][int]$ExpectedHostPort
    )

    $result = Invoke-Compose `
        -EnvironmentFile $Receipt.environmentFile `
        -ComposeProject $Receipt.projectName `
        -ComposePath $Receipt.composeSourcePath `
        -Arguments @(
            "port",
            "--protocol", $Protocol,
            $Service,
            [string]$ContainerPort
        ) `
        -AllowFailure
    if ($result.ExitCode -ne 0) {
        return $false
    }

    $escapedBindAddress = [Regex]::Escape($ExpectedBindAddress)
    foreach ($line in ($result.Output -split "\r?\n")) {
        $candidate = $line.Trim()
        if ($candidate -match "^${escapedBindAddress}:(?<port>[0-9]+)$") {
            if ([int]$Matches["port"] -eq $ExpectedHostPort) {
                return $true
            }
        }
    }
    $false
}

function Test-RetainedForwarderOwnsPort {
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$Protocol,
        [Parameter(Mandatory)][string]$ExpectedBindAddress,
        [Parameter(Mandatory)][int]$ExpectedPort
    )

    if (
        -not (Test-ReceiptRequiresLanForwarder -Receipt $Receipt) -or
        (Get-ReceiptBindAddress -Receipt $Receipt) -cne $ExpectedBindAddress
    ) {
        return $false
    }
    try {
        $observation = Assert-LanForwarderReady -Receipt $Receipt
        if ($observation.Status -cne "ready") {
            return $false
        }
        $forwarder = Get-ReceiptForwarder -Receipt $Receipt
        foreach ($listener in @($forwarder.listeners)) {
            if (
                [string]$listener.protocol -ceq $Protocol -and
                [int]$listener.publicPort -eq $ExpectedPort
            ) {
                return $true
            }
        }
    }
    catch {
        return $false
    }
    return $false
}

function Assert-CandidatePorts {
    param(
        [Parameter(Mandatory)][string]$CandidateBindAddress,
        [Parameter(Mandatory)][int]$CandidateAppPort,
        [Parameter(Mandatory)][int]$CandidateMinioPort,
        [Parameter(Mandatory)][int]$CandidateMinioConsolePort,
        [Parameter(Mandatory)][int]$CandidateLiveKitSignalPort,
        [Parameter(Mandatory)][int]$CandidateLiveKitTcpPort,
        [Parameter(Mandatory)][int]$CandidateLiveKitUdpPort,
        $PreviousReceipt = $null,
        [ValidateSet("full", "media-only")]
        [string]$ForwarderProfile = "full"
    )

    $specifications = @(
        [PSCustomObject]@{
            Name = "application"
            Protocol = "tcp"
            BindAddress = $podmanBindAddress
            Port = $CandidateAppPort
            Service = "app"
            ReceiptProperty = "app"
            ContainerPort = 4000
        },
        [PSCustomObject]@{
            Name = "MinIO API"
            Protocol = "tcp"
            BindAddress = $podmanBindAddress
            Port = $CandidateMinioPort
            Service = "minio"
            ReceiptProperty = "minio"
            ContainerPort = 9000
        },
        [PSCustomObject]@{
            Name = "MinIO console"
            Protocol = "tcp"
            BindAddress = "127.0.0.1"
            Port = $CandidateMinioConsolePort
            Service = "minio"
            ReceiptProperty = "minioConsole"
            ContainerPort = 9001
        },
        [PSCustomObject]@{
            Name = "LiveKit signaling"
            Protocol = "tcp"
            BindAddress = $podmanBindAddress
            Port = $CandidateLiveKitSignalPort
            Service = "livekit"
            ReceiptProperty = "livekitSignal"
            ContainerPort = 7880
        },
        [PSCustomObject]@{
            Name = "LiveKit media TCP"
            Protocol = "tcp"
            BindAddress = $podmanBindAddress
            Port = $CandidateLiveKitTcpPort
            Service = "livekit"
            ReceiptProperty = "livekitTcp"
            ContainerPort = $CandidateLiveKitTcpPort
        },
        [PSCustomObject]@{
            Name = "LiveKit media UDP"
            Protocol = "udp"
            BindAddress = $podmanBindAddress
            Port = $CandidateLiveKitUdpPort
            Service = "livekit"
            ReceiptProperty = "livekitUdp"
            ContainerPort = $CandidateLiveKitUdpPort
        }
    )

    $duplicates = @($specifications | Group-Object -Property Port | Where-Object { $_.Count -gt 1 })
    if ($duplicates.Count -gt 0) {
        $description =
            $duplicates |
                ForEach-Object {
                    $names = $_.Group.Name -join ", "
                    "$($_.Name) ($names)"
                }
        throw "Candidate local-release ports must be unique: $($description -join '; ')"
    }

    $runningServices =
        if ($PreviousReceipt) {
            @(Get-RunningRetainedServices -Receipt $PreviousReceipt)
        }
        else {
            @()
        }

    foreach ($specification in $specifications) {
        $ownedByRetainedRelease = $false
        $retainedBindAddress = $podmanBindAddress
        if (
            $PreviousReceipt -and
            $runningServices -contains $specification.Service -and
            $retainedBindAddress -ceq $specification.BindAddress
        ) {
            $receiptPort =
                $PreviousReceipt.ports.PSObject.Properties[$specification.ReceiptProperty]
            $ownedByRetainedRelease =
                $receiptPort -and
                [int]$receiptPort.Value -eq $specification.Port -and
                (Test-RetainedServiceOwnsPort `
                    -Receipt $PreviousReceipt `
                    -Service $specification.Service `
                    -ContainerPort $specification.ContainerPort `
                    -Protocol $specification.Protocol `
                    -ExpectedBindAddress $specification.BindAddress `
                    -ExpectedHostPort $specification.Port)
        }

        if ($ownedByRetainedRelease) {
            continue
        }

        $available = Test-BindAddressPortAvailable `
            -Address ([Net.IPAddress]::Parse($specification.BindAddress)) `
            -Port $specification.Port `
            -Protocol $specification.Protocol
        if (-not $available) {
            throw (
                "Candidate $($specification.Name) $($specification.Protocol.ToUpperInvariant()) " +
                "port $($specification.Port) is already in use on " +
                "$($specification.BindAddress)"
            )
        }
    }

    if ($CandidateBindAddress -ceq $podmanBindAddress) {
        return
    }
    $publicSpecifications =
        if ($ForwarderProfile -ceq "media-only") {
            @(
                [PSCustomObject]@{
                    Name = "LiveKit media TCP forwarder"
                    Protocol = "tcp"
                    Port = $CandidateLiveKitTcpPort
                },
                [PSCustomObject]@{
                    Name = "LiveKit media UDP forwarder"
                    Protocol = "udp"
                    Port = $CandidateLiveKitUdpPort
                }
            )
        }
        else {
            @(
        [PSCustomObject]@{
            Name = "application forwarder"
            Protocol = "tcp"
            Port = $CandidateAppPort
        },
        [PSCustomObject]@{
            Name = "MinIO API forwarder"
            Protocol = "tcp"
            Port = $CandidateMinioPort
        },
        [PSCustomObject]@{
            Name = "LiveKit signaling forwarder"
            Protocol = "tcp"
            Port = $CandidateLiveKitSignalPort
        },
        [PSCustomObject]@{
            Name = "LiveKit media TCP forwarder"
            Protocol = "tcp"
            Port = $CandidateLiveKitTcpPort
        },
        [PSCustomObject]@{
            Name = "LiveKit media UDP forwarder"
            Protocol = "udp"
            Port = $CandidateLiveKitUdpPort
        }
            )
        }
    foreach ($publicSpecification in $publicSpecifications) {
        $ownedByRetainedForwarder =
            $PreviousReceipt -and
            (Test-RetainedForwarderOwnsPort `
                -Receipt $PreviousReceipt `
                -Protocol $publicSpecification.Protocol `
                -ExpectedBindAddress $CandidateBindAddress `
                -ExpectedPort $publicSpecification.Port)
        if ($ownedByRetainedForwarder) {
            continue
        }
        $available = Test-BindAddressPortAvailable `
            -Address ([Net.IPAddress]::Parse($CandidateBindAddress)) `
            -Port $publicSpecification.Port `
            -Protocol $publicSpecification.Protocol
        if (-not $available) {
            throw (
                "Candidate $($publicSpecification.Name) " +
                "$($publicSpecification.Protocol.ToUpperInvariant()) port " +
                "$($publicSpecification.Port) is already in use on " +
                "$CandidateBindAddress"
            )
        }
    }
}

function Restore-Release {
    param(
        [Parameter(Mandatory)]$Receipt,
        [switch]$UpdatePointer,
        [switch]$RunMigration
    )

    Assert-RetainedReleaseAssets -Receipt $Receipt
    $topology = Resolve-ReceiptNetworkTopology -Receipt $Receipt
    $activeReceipt = Get-CurrentReceipt
    if ($activeReceipt) {
        Assert-RetainedReleaseAssets -Receipt $activeReceipt
    }

    $image = Get-ImageEvidence `
        -ImageReference $Receipt.imageReference `
        -ExpectedRevision $Receipt.revision
    if ($image.imageId -ne $Receipt.imageId) {
        throw "Retained image tag no longer resolves to the recorded image ID"
    }
    if (
        [string]$Receipt.imageDigest -and
        $image.imageDigest -ne [string]$Receipt.imageDigest
    ) {
        throw "Retained image digest no longer matches the recorded image digest"
    }

    $targetForwarderStarted = $false
    if ($activeReceipt) {
        Unregister-LanForwarderSupervisor `
            -Receipt $activeReceipt `
            -AllowNotRegistered
        Stop-LanForwarder -Receipt $activeReceipt -AllowNotRunning
    }
    try {
        $migrationOutput = Start-ReleaseServices `
            -EnvironmentFile $Receipt.environmentFile `
            -ComposeProject $Receipt.projectName `
            -ComposePath $Receipt.composeSourcePath `
            -RunMigration:$RunMigration
        Assert-ReceiptTrustedProxyGatewayCurrent -Receipt $Receipt
        Ensure-InstantRoomTenant `
            -EnvironmentFile $Receipt.environmentFile `
            -ComposeProject $Receipt.projectName `
            -ComposePath $Receipt.composeSourcePath `
            -ExpectedBindAddress $topology.PodmanBindAddress `
            -ExpectedAppPort ([int]$Receipt.ports.app) `
            -ReleaseEnvironment (Read-EnvironmentFile -Path $Receipt.environmentFile)
        Start-SealedApplication `
            -EnvironmentFile $Receipt.environmentFile `
            -ComposeProject $Receipt.projectName `
            -ComposePath $Receipt.composeSourcePath
        Wait-ContainerHealth `
            -EnvironmentFile $Receipt.environmentFile `
            -ComposeProject $Receipt.projectName `
            -ComposePath $Receipt.composeSourcePath `
            -Service "app"
        Wait-Application `
            -ExpectedBindAddress $topology.PodmanBindAddress `
            -ExpectedAppPort ([int]$Receipt.ports.app) `
            -ExpectedMinioPort ([int]$Receipt.ports.minio) `
            -ExpectedLiveKitPort ([int]$Receipt.ports.livekitSignal)
        if (Test-ReceiptRequiresLanForwarder -Receipt $Receipt) {
            $null = Start-LanForwarder -Receipt $Receipt
            $targetForwarderStarted = $true
            $null = Assert-LanForwarderReady -Receipt $Receipt
            if (Test-ReceiptIsCloudflareTrustedEdge -Receipt $Receipt) {
                Wait-TrustedEdgeApplication -Topology $topology
            }
            else {
                Wait-Application `
                    -ExpectedBindAddress $topology.BindAddress `
                    -ExpectedAppPort ([int]$Receipt.ports.app) `
                    -ExpectedMinioPort ([int]$Receipt.ports.minio) `
                    -ExpectedLiveKitPort ([int]$Receipt.ports.livekitSignal)
            }
        }
    }
    catch {
        $restoreError = $_
        if ($targetForwarderStarted) {
            try {
                Stop-LanForwarder -Receipt $Receipt -AllowNotRunning
            }
            catch {
                throw (
                    "Retained release restore failed and its target forwarder " +
                    "could not be stopped safely. Restore: " +
                    "$($restoreError.Exception.Message) Forwarder stop: " +
                    "$($_.Exception.Message)"
                )
            }
        }
        throw $restoreError
    }

    if ($UpdatePointer) {
        $supervisorRegistered = $false
        try {
            $null = Register-LanForwarderSupervisor -Receipt $Receipt
            $supervisorRegistered = $true
            Write-JsonAtomic -Path $currentPointerPath -Value ([ordered]@{
                receiptPath = $Receipt.receiptPath
                revision = $Receipt.revision
                imageReference = $Receipt.imageReference
                imageId = $Receipt.imageId
                publicAppUrl = $topology.PublicAppUrl
                updatedAt = [DateTime]::UtcNow.ToString("o")
            })
        }
        catch {
            $publishError = $_
            if ($supervisorRegistered) {
                Unregister-LanForwarderSupervisor `
                    -Receipt $Receipt `
                    -AllowNotRegistered
            }
            throw $publishError
        }
    }

    $migrationOutput
}

function Invoke-StateRootSafetySelfTest {
    $testId = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $testProject = "k-comms-state-test-$testId"
    $temporaryParent =
        Join-Path ([IO.Path]::GetTempPath()) ("k-comms-state-test-" + [Guid]::NewGuid().ToString("N"))
    $ownedPath = Join-Path $temporaryParent "owned"
    $junctionPath = Join-Path $temporaryParent "junction"
    $junctionTarget = Join-Path $temporaryParent "junction-target"

    New-Item -ItemType Directory -Path $temporaryParent | Out-Null
    try {
        $blockedUnowned = $false
        try {
            Initialize-OwnedStateDirectory -Path $temporaryParent -ExpectedProject $testProject
        }
        catch {
            $blockedUnowned = $true
        }
        if (-not $blockedUnowned) {
            throw "State-root safety self-test adopted an unmarked existing directory"
        }

        Initialize-OwnedStateDirectory -Path $ownedPath -ExpectedProject $testProject
        Initialize-OwnedStateDirectory -Path $ownedPath -ExpectedProject $testProject
        Assert-OwnedStateDirectory -Path $ownedPath -ExpectedProject $testProject
        $ownedAcl = Get-Acl -LiteralPath $ownedPath
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $unexpectedAllows =
            @($ownedAcl.Access | Where-Object {
                $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                $_.IdentityReference.Value -ne $currentIdentity
            })
        if (-not $ownedAcl.AreAccessRulesProtected -or $unexpectedAllows.Count -gt 0) {
            throw "State-root safety self-test did not produce a current-user-only protected ACL"
        }

        $operationLock = Enter-ReleaseOperationLock -Path $ownedPath -ComposeProject $testProject
        try {
            $blockedConcurrent = $false
            try {
                $unexpectedLock =
                    Enter-ReleaseOperationLock -Path $ownedPath -ComposeProject $testProject
                Exit-ReleaseOperationLock -Lock $unexpectedLock
            }
            catch {
                $blockedConcurrent = $true
            }
            if (-not $blockedConcurrent) {
                throw "State-root safety self-test allowed concurrent operations"
            }
        }
        finally {
            Exit-ReleaseOperationLock -Lock $operationLock
        }

        $retainedEnvironment = Join-Path $ownedPath "retained.env"
        $retainedCompose = Join-Path $ownedPath "compose.source.yaml"
        $retainedRendered = Join-Path $ownedPath "compose.rendered.yaml"
        [IO.File]::WriteAllText($retainedEnvironment, "TEST=true")
        [IO.File]::WriteAllText($retainedCompose, "services: {}")
        [IO.File]::WriteAllText($retainedRendered, "services: {}")
        $retainedReceipt = [PSCustomObject]@{
            environmentFile = $retainedEnvironment
            environmentSha256 =
                (Get-FileHash -LiteralPath $retainedEnvironment -Algorithm SHA256).Hash.ToLowerInvariant()
            composeSourcePath = $retainedCompose
            composeSourceSha256 =
                (Get-FileHash -LiteralPath $retainedCompose -Algorithm SHA256).Hash.ToLowerInvariant()
            renderedConfigPath = $retainedRendered
            renderedConfigSha256 =
                (Get-FileHash -LiteralPath $retainedRendered -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        Assert-RetainedReleaseAssets -Receipt $retainedReceipt
        [IO.File]::AppendAllText($retainedCompose, "`n# changed")
        $blockedChangedCompose = $false
        try {
            Assert-RetainedReleaseAssets -Receipt $retainedReceipt
        }
        catch {
            $blockedChangedCompose = $true
        }
        if (-not $blockedChangedCompose) {
            throw "State-root safety self-test accepted a changed retained Compose source"
        }
        [IO.File]::WriteAllText($retainedCompose, "services: {}")
        [IO.File]::AppendAllText($retainedEnvironment, "`nCHANGED=true")
        $blockedChangedEnvironment = $false
        try {
            Assert-RetainedReleaseAssets -Receipt $retainedReceipt
        }
        catch {
            $blockedChangedEnvironment = $true
        }
        if (-not $blockedChangedEnvironment) {
            throw "State-root safety self-test accepted a changed retained environment"
        }

        $markerPath = Get-StateOwnershipMarkerPath -Path $ownedPath
        $marker = Read-JsonFile -Path $markerPath
        $marker.canonicalPath = Join-Path $temporaryParent "other"
        Write-JsonAtomic -Path $markerPath -Value $marker
        $blockedMismatch = $false
        try {
            Assert-OwnedStateDirectory -Path $ownedPath -ExpectedProject $testProject
        }
        catch {
            $blockedMismatch = $true
        }
        if (-not $blockedMismatch) {
            throw "State-root safety self-test accepted a mismatched ownership marker"
        }
        $marker.canonicalPath = [IO.Path]::GetFullPath($ownedPath)
        Write-JsonAtomic -Path $markerPath -Value $marker

        New-Item -ItemType Directory -Path $junctionTarget | Out-Null
        New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
        $blockedReparsePoint = $false
        try {
            Initialize-OwnedStateDirectory -Path $junctionPath -ExpectedProject $testProject
        }
        catch {
            $blockedReparsePoint = $true
        }
        if (-not $blockedReparsePoint) {
            throw "State-root safety self-test accepted a reparse point"
        }

        $nestedUnderJunction = Join-Path $junctionPath "nested\state"
        $blockedReparseAncestor = $false
        $originalCustomStateRootRequested = $customStateRootRequested
        try {
            # Exercise the actual custom-StateRoot initialization path, not
            # only the ancestor helper in isolation.
            $script:customStateRootRequested = $true
            Initialize-OwnedStateDirectory `
                -Path $nestedUnderJunction `
                -ExpectedProject $testProject
        }
        catch {
            $blockedReparseAncestor = $true
        }
        finally {
            $script:customStateRootRequested = $originalCustomStateRootRequested
        }
        if (-not $blockedReparseAncestor) {
            throw "State-root safety self-test accepted a reparse-point ancestor"
        }

        $safeCustomPath = Join-Path $temporaryParent "safe-custom-owned"
        $originalCustomStateRootRequested = $customStateRootRequested
        try {
            $script:customStateRootRequested = $true
            Initialize-OwnedStateDirectory `
                -Path $safeCustomPath `
                -ExpectedProject $testProject
        }
        finally {
            $script:customStateRootRequested = $originalCustomStateRootRequested
        }
        Assert-OwnedStateDirectory -Path $safeCustomPath -ExpectedProject $testProject

        $blockedDangerousRoot = $false
        try {
            Assert-SafeStateRootPath -Path ([IO.Path]::GetPathRoot($temporaryParent))
        }
        catch {
            $blockedDangerousRoot = $true
        }
        if (-not $blockedDangerousRoot) {
            throw "State-root safety self-test accepted a filesystem root"
        }
    }
    finally {
        if (Test-Path -LiteralPath $junctionPath) {
            Remove-Item -LiteralPath $junctionPath -Force
        }
        if (Test-Path -LiteralPath $temporaryParent) {
            Remove-Item -LiteralPath $temporaryParent -Recurse -Force
        }
    }
}

function Invoke-PortPreflightSelfTest {
    $tcpSocket = $null
    try {
        $tcpSocket = [Net.Sockets.Socket]::new(
            [Net.Sockets.AddressFamily]::InterNetwork,
            [Net.Sockets.SocketType]::Stream,
            [Net.Sockets.ProtocolType]::Tcp
        )
        $tcpSocket.ExclusiveAddressUse = $true
        $tcpSocket.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
        $tcpSocket.Listen(1)
        $occupiedTcpPort = ([Net.IPEndPoint]$tcpSocket.LocalEndPoint).Port
        if (
            Test-BindAddressPortAvailable `
                -Address ([Net.IPAddress]::Loopback) `
                -Port $occupiedTcpPort `
                -Protocol "tcp"
        ) {
            throw "Port preflight self-test accepted an occupied TCP port"
        }
    }
    finally {
        if ($tcpSocket) {
            $tcpSocket.Dispose()
        }
    }

    $udpSocket = $null
    try {
        $udpSocket = [Net.Sockets.Socket]::new(
            [Net.Sockets.AddressFamily]::InterNetwork,
            [Net.Sockets.SocketType]::Dgram,
            [Net.Sockets.ProtocolType]::Udp
        )
        $udpSocket.ExclusiveAddressUse = $true
        $udpSocket.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
        $occupiedUdpPort = ([Net.IPEndPoint]$udpSocket.LocalEndPoint).Port
        if (
            Test-BindAddressPortAvailable `
                -Address ([Net.IPAddress]::Loopback) `
                -Port $occupiedUdpPort `
                -Protocol "udp"
        ) {
            throw "Port preflight self-test accepted an occupied UDP port"
        }
    }
    finally {
        if ($udpSocket) {
            $udpSocket.Dispose()
        }
    }

    $blockedDuplicate = $false
    try {
        Assert-CandidatePorts `
            -CandidateBindAddress "127.0.0.1" `
            -CandidateAppPort 42001 `
            -CandidateMinioPort 42001 `
            -CandidateMinioConsolePort 42002 `
            -CandidateLiveKitSignalPort 42003 `
            -CandidateLiveKitTcpPort 42004 `
            -CandidateLiveKitUdpPort 42005
    }
    catch {
        $blockedDuplicate = $true
    }
    if (-not $blockedDuplicate) {
        throw "Port preflight self-test accepted duplicate candidate ports"
    }
}

function Invoke-BindAddressSelfTest {
    if ((Resolve-ReleaseBindAddress -Value "127.0.0.1") -cne "127.0.0.1") {
        throw "Bind-address self-test did not preserve the default loopback address"
    }

    foreach ($sample in @("10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.0.1")) {
        if (-not (Test-Rfc1918IPv4 -Address ([Net.IPAddress]::Parse($sample)))) {
            throw "Bind-address self-test rejected RFC1918 address $sample"
        }
    }
    foreach ($sample in @("172.32.0.1", "169.254.1.1", "203.0.113.10")) {
        if (Test-Rfc1918IPv4 -Address ([Net.IPAddress]::Parse($sample))) {
            throw "Bind-address self-test accepted non-RFC1918 address $sample"
        }
    }

    foreach ($sample in @(
        "0.0.0.0",
        "127.0.0.2",
        "127.1",
        "127.000.000.001",
        "3232235953",
        "0xC0.0xA8.0x01.0xB1",
        " 127.0.0.1 ",
        "203.0.113.10",
        "::1",
        "not-an-address"
    )) {
        $rejected = $false
        try {
            $null = Resolve-ReleaseBindAddress -Value $sample
        }
        catch {
            $rejected = $true
        }
        if (-not $rejected) {
            throw "Bind-address self-test accepted unsafe address $sample"
        }
    }

    $preferredAddressRecord = [PSCustomObject]@{
        IPAddress = "192.168.50.12"
        AddressState = "Preferred"
    }
    if (-not (
        Test-PreferredReleaseIPAddressRecord `
            -AddressRecord $preferredAddressRecord `
            -ExpectedAddress "192.168.50.12"
    )) {
        throw "Network-profile self-test rejected an exact Preferred address"
    }
    foreach ($addressState in @(
        "Tentative",
        "Duplicate",
        "Deprecated",
        "Invalid"
    )) {
        $nonPreferredAddressRecord = [PSCustomObject]@{
            IPAddress = "192.168.50.12"
            AddressState = $addressState
        }
        if (
            Test-PreferredReleaseIPAddressRecord `
                -AddressRecord $nonPreferredAddressRecord `
                -ExpectedAddress "192.168.50.12"
        ) {
            throw (
                "Network-profile self-test accepted non-Preferred address state " +
                "$addressState"
            )
        }
    }
    $wrongAddressRecord = [PSCustomObject]@{
        IPAddress = "192.168.50.13"
        AddressState = "Preferred"
    }
    if (
        Test-PreferredReleaseIPAddressRecord `
            -AddressRecord $wrongAddressRecord `
            -ExpectedAddress "192.168.50.12"
    ) {
        throw "Network-profile self-test accepted a different Preferred address"
    }

    if (Assert-ReleaseNetworkCategory -NetworkCategory "Private") {
        throw "Network-profile self-test treated Private as requiring an override"
    }
    $publicBlocked = $false
    try {
        $null = Assert-ReleaseNetworkCategory -NetworkCategory "Public"
    }
    catch {
        $publicBlocked = $true
    }
    if (-not $publicBlocked) {
        throw "Network-profile self-test accepted Public without an explicit override"
    }
    if (-not (
        Assert-ReleaseNetworkCategory `
            -NetworkCategory "Public" `
            -AllowPublicNetworkProfile
    )) {
        throw "Network-profile self-test did not audit the explicit Public override"
    }
    $loopbackOverrideBlocked = $false
    try {
        $null = Resolve-ReleaseNetworkObservation `
            -Value "127.0.0.1" `
            -AllowPublicNetworkProfile
    }
    catch {
        $loopbackOverrideBlocked = $true
    }
    if (-not $loopbackOverrideBlocked) {
        throw "Network-profile self-test accepted a meaningless loopback override"
    }

    $expectedObservation = [PSCustomObject]@{
        BindAddress = "192.168.50.12"
        InterfaceIndex = 12
        InterfaceAlias = "Ethernet"
        NetworkName = "Private test network"
        NetworkCategory = "Private"
        AllowPublicNetworkProfile = $false
        PublicNetworkProfileOverrideUsed = $false
    }
    $matchingObservation = (
        $expectedObservation |
            ConvertTo-Json -Depth 4 |
            ConvertFrom-Json
    )
    Assert-ReleaseNetworkObservationMatches `
        -Expected $expectedObservation `
        -Observed $matchingObservation `
        -Context "Network-profile self-test"
    foreach ($drift in @(
        @("BindAddress", "192.168.50.13"),
        @("InterfaceIndex", 13),
        @("InterfaceAlias", "Wi-Fi"),
        @("NetworkName", "Different network"),
        @("NetworkCategory", "Public"),
        @("PublicNetworkProfileOverrideUsed", $true)
    )) {
        $driftedObservation = (
            $expectedObservation |
                ConvertTo-Json -Depth 4 |
                ConvertFrom-Json
        )
        $driftedObservation.PSObject.Properties[$drift[0]].Value = $drift[1]
        $driftRejected = $false
        try {
            Assert-ReleaseNetworkObservationMatches `
                -Expected $expectedObservation `
                -Observed $driftedObservation `
                -Context "Network-profile self-test"
        }
        catch {
            $driftRejected = $true
        }
        if (-not $driftRejected) {
            throw (
                "Network-profile self-test accepted drift in $($drift[0])"
            )
        }
    }

    $selfTestOrigin =
        "http://$($script:ReleaseNetworkObservation.BindAddress):4188"
    $selfTestObservation = [PSCustomObject]@{
        BindAddress = $script:ReleaseNetworkObservation.BindAddress
        InterfaceIndex = $script:ReleaseNetworkObservation.InterfaceIndex
        InterfaceAlias = $script:ReleaseNetworkObservation.InterfaceAlias
        NetworkName = $script:ReleaseNetworkObservation.NetworkName
        NetworkCategory = $script:ReleaseNetworkObservation.NetworkCategory
        AllowPublicNetworkProfile =
            $script:ReleaseNetworkObservation.AllowPublicNetworkProfile
        PublicNetworkProfileOverrideUsed =
            $script:ReleaseNetworkObservation.PublicNetworkProfileOverrideUsed
        ExposureProfile =
            if (
                $script:ReleaseNetworkObservation.BindAddress -ceq
                    $podmanBindAddress
            ) {
                "loopback"
            }
            else {
                "private_lan"
            }
        PublicHost = $script:ReleaseNetworkObservation.BindAddress
    }
    $selfTestReceipt = (
        [ordered]@{
            schemaVersion = 5
            publicAppUrl = $selfTestOrigin
            network = New-ReceiptNetworkRecord `
                -Observation $selfTestObservation `
                -PublicAppUrl $selfTestOrigin
            ports = [ordered]@{
                app = 4188
                livekitSignal = 7980
                livekitTcp = 7981
                livekitUdp = 7982
                minio = 5900
            }
        } |
            ConvertTo-Json -Depth 8 |
            ConvertFrom-Json
    )
    $selfTestTopology =
        Resolve-ReceiptNetworkTopology -Receipt $selfTestReceipt
    if (
        $selfTestTopology.BindAddress -cne
            $script:ReleaseNetworkObservation.BindAddress -or
        $selfTestTopology.NetworkCategory -cne
            $script:ReleaseNetworkObservation.NetworkCategory -or
        $selfTestTopology.AllowPublicNetworkProfile -cne
            $script:ReleaseNetworkObservation.AllowPublicNetworkProfile
    ) {
        throw "Network-profile receipt self-test did not preserve its audited topology"
    }
}

function Assert-LanForwarderSelfTestRejected {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Description
    )

    $rejected = $false
    try {
        & $Action
    }
    catch {
        $rejected = $true
    }
    if (-not $rejected) {
        throw "LAN forwarder self-test accepted $Description"
    }
}

function New-LanForwarderSelfTestPorts {
    param([Parameter(Mandatory)][string]$PublicBindAddress)

    $ports = [Collections.Generic.List[int]]::new()
    foreach ($protocol in @("tcp", "tcp", "tcp", "tcp", "udp")) {
        $selected = 0
        for ($attempt = 0; $attempt -lt 500; $attempt++) {
            $candidate = Get-Random -Minimum 42000 -Maximum 61000
            if ($ports.Contains($candidate)) {
                continue
            }
            if (
                (Test-BindAddressPortAvailable `
                    -Address ([Net.IPAddress]::Parse($PublicBindAddress)) `
                    -Port $candidate `
                    -Protocol $protocol) -and
                (Test-BindAddressPortAvailable `
                    -Address ([Net.IPAddress]::Loopback) `
                    -Port $candidate `
                    -Protocol $protocol)
            ) {
                $selected = $candidate
                break
            }
        }
        if ($selected -eq 0) {
            throw "LAN forwarder self-test could not allocate an unused $protocol port"
        }
        $ports.Add($selected)
    }
    return @($ports)
}

function New-LanForwarderSelfTestReceipt {
    param(
        [Parameter(Mandatory)][string]$CandidateDirectory,
        [Parameter(Mandatory)][string]$ExpectedBindAddress,
        [Parameter(Mandatory)][int[]]$Ports,
        [ValidateSet("full", "media-only")]
        [string]$Profile = "full",
        [string]$CandidateId = "20260725T000000Z-0123456789ab-01234567"
    )

    $receiptPath = Join-Path $CandidateDirectory "deployment.json"
    $forwarder = New-LanForwarderReceiptRecord `
        -ImmutableSourceRoot $repositoryRoot `
        -CandidateDirectory $CandidateDirectory `
        -ExpectedBindAddress $ExpectedBindAddress `
        -ExpectedAppPort $Ports[0] `
        -ExpectedMinioPort $Ports[1] `
        -ExpectedLiveKitSignalPort $Ports[2] `
        -ExpectedLiveKitTcpPort $Ports[3] `
        -ExpectedLiveKitUdpPort $Ports[4] `
        -ReceiptPath $receiptPath `
        -CandidateId $CandidateId `
        -Profile $Profile
    [PSCustomObject]@{
        schemaVersion = if ($Profile -ceq "media-only") { 6 } else { 5 }
        candidateId = $CandidateId
        receiptPath = $receiptPath
        publicAppUrl =
            if ($Profile -ceq "media-only") {
                "https://comms.self-test.invalid"
            }
            else {
                "http://$ExpectedBindAddress`:$($Ports[0])"
            }
        network = [PSCustomObject]@{
            bindAddress = $ExpectedBindAddress
            podmanBindAddress = $podmanBindAddress
            publicHost =
                if ($Profile -ceq "media-only") {
                    "comms.self-test.invalid"
                }
                else {
                    $ExpectedBindAddress
                }
            publicAppUrl =
                if ($Profile -ceq "media-only") {
                    "https://comms.self-test.invalid"
                }
                else {
                    "http://$ExpectedBindAddress`:$($Ports[0])"
                }
            exposureMode =
                if ($Profile -ceq "media-only") {
                    $cloudflareTrustedEdgeProfile
                }
                else {
                    "lan-forwarder"
                }
            exposureProfile =
                if ($Profile -ceq "media-only") {
                    $cloudflareTrustedEdgeProfile
                }
                else {
                    "private_lan"
                }
        }
        ports = [PSCustomObject]@{
            app = $Ports[0]
            minio = $Ports[1]
            minioConsole = 61999
            livekitSignal = $Ports[2]
            livekitTcp = $Ports[3]
            livekitUdp = $Ports[4]
        }
        forwarder = $forwarder
    }
}

function Invoke-LanForwarderSelfTest {
    param([Parameter(Mandatory)][string]$TemporaryDirectory)

    $commandIdentityFixture = [PSCustomObject]@{
        nodeExecutablePath = "C:\Program Files\nodejs\node.exe"
        scriptPath = "C:\K Comms State\lan_release_forwarder.mjs"
        configPath = "C:\K Comms State\lan_release_forwarder.config.json"
    }
    $validCommandLines = @(
        (
            '"C:\Program Files\nodejs\node.exe" ' +
            '"C:\K Comms State\lan_release_forwarder.mjs" ' +
            '--config "C:\K Comms State\lan_release_forwarder.config.json"'
        ),
        (
            '"C:\Program Files\nodejs\node.exe" ' +
            '"C:\K Comms State\lan_release_forwarder.mjs" ' +
            '--config="C:\K Comms State\lan_release_forwarder.config.json"'
        )
    )
    foreach ($commandLine in $validCommandLines) {
        if (-not (Test-LanForwarderCommandLine `
            -CommandLine $commandLine `
            -Forwarder $commandIdentityFixture)) {
            throw (
                "LAN forwarder self-test rejected a canonical exact command line: " +
                $commandLine
            )
        }
    }
    $decoyCommandLines = @(
        (
            '"C:\Program Files\nodejs\node.exe" "C:\decoy.mjs" ' +
            '"C:\K Comms State\lan_release_forwarder.mjs" ' +
            '--config "C:\K Comms State\lan_release_forwarder.config.json"'
        ),
        (
            '"C:\Program Files\nodejs\node.exe" ' +
            '"C:\K Comms State\lan_release_forwarder.mjs" extra ' +
            '--config "C:\K Comms State\lan_release_forwarder.config.json"'
        ),
        (
            '"C:\Program Files\nodejs\node.exe" ' +
            '"C:\K Comms State\lan_release_forwarder.mjs" ' +
            '--config "C:\other.json" ' +
            '"C:\K Comms State\lan_release_forwarder.config.json"'
        ),
        (
            '"C:\Program Files\nodejs\node.exe" ' +
            '"C:\K Comms State\lan_release_forwarder.mjs" ' +
            '--config "C:\K Comms State\lan_release_forwarder.config.json" ' +
            '--inspect'
        ),
        (
            '"C:\Program Files\nodejs\not-node.exe" ' +
            '"C:\K Comms State\lan_release_forwarder.mjs" ' +
            '--config "C:\K Comms State\lan_release_forwarder.config.json"'
        )
    )
    foreach ($commandLine in $decoyCommandLines) {
        if (Test-LanForwarderCommandLine `
            -CommandLine $commandLine `
            -Forwarder $commandIdentityFixture) {
            throw (
                "LAN forwarder self-test accepted a decoy command line: " +
                $commandLine
            )
        }
    }

    $sourcePath = Join-Path `
        $repositoryRoot `
        ($lanForwarderSourceRelativePath.Replace("/", "\"))
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "LAN forwarder self-test source is missing: $sourcePath"
    }
    $nodeAvailable = $null -ne (
        Get-Command node -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
    )
    if (-not $nodeAvailable) {
        if ($BindAddress -cne $podmanBindAddress) {
            throw "LAN validation requires the node command"
        }
        Write-Verbose "Skipping Node LAN forwarder self-test in loopback-only validation."
        return
    }

    $liveLifecycleTest = $BindAddress -cne $podmanBindAddress
    $testBindAddress =
        if ($liveLifecycleTest) {
            $BindAddress
        }
        else {
            "192.168.50.12"
        }
    $testPorts =
        if ($liveLifecycleTest) {
            New-LanForwarderSelfTestPorts -PublicBindAddress $testBindAddress
        }
        else {
            @(50101, 50102, 50103, 50104, 50105)
        }
    $candidateDirectory = Join-Path $TemporaryDirectory "forwarder-self-test"
    New-Item -ItemType Directory -Path $candidateDirectory | Out-Null
    $receipt = New-LanForwarderSelfTestReceipt `
        -CandidateDirectory $candidateDirectory `
        -ExpectedBindAddress $testBindAddress `
        -Ports $testPorts
    $forwarder = Get-ReceiptForwarder -Receipt $receipt
    Assert-LanForwarderAssets -Receipt $receipt

    $scriptBytes = [IO.File]::ReadAllBytes([string]$forwarder.scriptPath)
    $configBytes = [IO.File]::ReadAllBytes([string]$forwarder.configPath)
    try {
        [IO.File]::AppendAllText(
            [string]$forwarder.scriptPath,
            "`n// tamper",
            (New-Object Text.UTF8Encoding($false))
        )
        Assert-LanForwarderSelfTestRejected `
            -Description "a tampered immutable script" `
            -Action { Assert-LanForwarderAssets -Receipt $receipt }
    }
    finally {
        [IO.File]::WriteAllBytes([string]$forwarder.scriptPath, $scriptBytes)
    }
    try {
        [IO.File]::AppendAllText(
            [string]$forwarder.configPath,
            " ",
            (New-Object Text.UTF8Encoding($false))
        )
        Assert-LanForwarderSelfTestRejected `
            -Description "a tampered hash-bound configuration" `
            -Action { Assert-LanForwarderAssets -Receipt $receipt }
    }
    finally {
        [IO.File]::WriteAllBytes([string]$forwarder.configPath, $configBytes)
    }
    Assert-LanForwarderAssets -Receipt $receipt

    if (-not $liveLifecycleTest) {
        return
    }

    $cleanupError = $null
    try {
        $firstObservation = Start-LanForwarder -Receipt $receipt
        if ($firstObservation.Status -cne "ready") {
            throw "LAN forwarder self-test did not reach verified readiness"
        }
        $firstProcessId = $firstObservation.ProcessId
        $readyBytes = [IO.File]::ReadAllBytes([string]$forwarder.statusPath)

        try {
            $tamperedReady = Read-JsonFile -Path $forwarder.statusPath
            $tamperedReady.readinessToken = "tampered-token"
            Write-JsonAtomic -Path $forwarder.statusPath -Value $tamperedReady
            if (
                (Get-LanForwarderObservation -Receipt $receipt).
                    ProcessMatchesReceipt
            ) {
                throw "LAN forwarder self-test accepted a tampered READY token"
            }
            $staleReadyReplacement = Start-LanForwarder -Receipt $receipt
            if ($staleReadyReplacement.Status -cne "ready") {
                throw (
                    "LAN forwarder self-test could not replace a process with " +
                    "stale READY evidence"
                )
            }
            if (
                $staleReadyReplacement.ProcessId -eq $firstProcessId -and
                (Get-Process -Id $firstProcessId -ErrorAction SilentlyContinue)
            ) {
                throw (
                    "LAN forwarder self-test retained the process referenced by " +
                    "stale READY evidence"
                )
            }
            $firstProcessId = $staleReadyReplacement.ProcessId
            $readyBytes =
                [IO.File]::ReadAllBytes([string]$forwarder.statusPath)
        }
        finally {
            if (
                -not (Test-Path `
                    -LiteralPath $forwarder.statusPath `
                    -PathType Leaf)
            ) {
                [IO.File]::WriteAllBytes(
                    [string]$forwarder.statusPath,
                    $readyBytes
                )
            }
        }

        try {
            $tamperedReady = Read-JsonFile -Path $forwarder.statusPath
            $tamperedReady.processStartTimeUtc = "2000-01-01T00:00:00.000Z"
            Write-JsonAtomic -Path $forwarder.statusPath -Value $tamperedReady
            if (
                (Get-LanForwarderObservation -Receipt $receipt).
                    ProcessMatchesReceipt
            ) {
                throw (
                    "LAN forwarder self-test accepted READY process-start drift"
                )
            }
        }
        finally {
            [IO.File]::WriteAllBytes([string]$forwarder.statusPath, $readyBytes)
        }

        try {
            $tamperedReady = Read-JsonFile -Path $forwarder.statusPath
            $tamperedReady.listeners[0].publicPort =
                [int]$tamperedReady.listeners[0].publicPort + 1
            Write-JsonAtomic -Path $forwarder.statusPath -Value $tamperedReady
            if (
                (Get-LanForwarderObservation -Receipt $receipt).
                    ListenersMatchReceipt
            ) {
                throw "LAN forwarder self-test accepted READY listener drift"
            }
        }
        finally {
            [IO.File]::WriteAllBytes([string]$forwarder.statusPath, $readyBytes)
        }

        $replacement = Start-LanForwarder -Receipt $receipt
        if ($replacement.Status -cne "ready") {
            throw "LAN forwarder self-test replacement did not become ready"
        }
        if (
            $replacement.ProcessId -eq $firstProcessId -and
            (Get-Process -Id $firstProcessId -ErrorAction SilentlyContinue)
        ) {
            throw "LAN forwarder self-test did not replace the retained process"
        }

        Remove-Item -LiteralPath $forwarder.statusPath -Force
        Stop-LanForwarder -Receipt $receipt -AllowNotRunning
        if (
            @(Get-LanForwarderCommandProcesses -Forwarder $forwarder).Count -ne 0
        ) {
            throw "LAN forwarder self-test left an exact-command orphan process"
        }
        Assert-LanForwarderPortsReleased -Receipt $receipt

        $occupiedSocket = [Net.Sockets.Socket]::new(
            [Net.Sockets.AddressFamily]::InterNetwork,
            [Net.Sockets.SocketType]::Stream,
            [Net.Sockets.ProtocolType]::Tcp
        )
        try {
            $occupiedSocket.ExclusiveAddressUse = $true
            $occupiedSocket.Bind([Net.IPEndPoint]::new(
                [Net.IPAddress]::Parse($testBindAddress),
                $testPorts[0]
            ))
            $occupiedSocket.Listen(1)
            Assert-LanForwarderSelfTestRejected `
                -Description "an unowned public listener during start" `
                -Action { $null = Start-LanForwarder -Receipt $receipt }
            if (
                @(Get-LanForwarderCommandProcesses -Forwarder $forwarder).Count -ne 0
            ) {
                throw (
                    "LAN forwarder self-test failed start left a Node process"
                )
            }
        }
        finally {
            $occupiedSocket.Dispose()
        }
        Assert-LanForwarderPortsReleased -Receipt $receipt

        $null = Start-LanForwarder -Receipt $receipt
        Stop-LanForwarder -Receipt $receipt
        Assert-LanForwarderPortsReleased -Receipt $receipt
    }
    finally {
        try {
            [IO.File]::WriteAllBytes([string]$forwarder.scriptPath, $scriptBytes)
            [IO.File]::WriteAllBytes([string]$forwarder.configPath, $configBytes)
            Stop-LanForwarder -Receipt $receipt -AllowNotRunning
        }
        catch {
            $cleanupError = $_
        }
        if ($cleanupError) {
            throw (
                "LAN forwarder self-test cleanup failed: " +
                $cleanupError.Exception.Message
            )
        }
    }
}

function Invoke-LanForwarderSupervisionSelfTest {
    param([Parameter(Mandatory)][string]$TemporaryDirectory)

    if ($BindAddress -ceq $podmanBindAddress) {
        return
    }
    $testPorts = New-LanForwarderSelfTestPorts `
        -PublicBindAddress $BindAddress
    $candidateDirectory =
        Join-Path $TemporaryDirectory "forwarder-supervision-self-test"
    New-Item -ItemType Directory -Path $candidateDirectory | Out-Null
    $receipt = New-LanForwarderSelfTestReceipt `
        -CandidateDirectory $candidateDirectory `
        -ExpectedBindAddress $BindAddress `
        -Ports $testPorts `
        -Profile "media-only"
    $forwarder = Get-ReceiptForwarder -Receipt $receipt
    $supervisor = Get-LanForwarderSupervisor -Forwarder $forwarder
    Assert-LanForwarderAssets -Receipt $receipt
    if (
        @($forwarder.listeners).Count -ne 2 -or
        @($forwarder.listeners | ForEach-Object { [string]$_.name }) -join "," -cne
            "livekitTcp,livekitUdp"
    ) {
        throw (
            "LAN forwarder supervision self-test widened the media-only " +
            "listener contract"
        )
    }
    Assert-LanForwarderSupervisorInvocation `
        -Receipt $receipt `
        -ReceiptPath ([string]$receipt.receiptPath) `
        -CandidateId ([string]$receipt.candidateId) `
        -ForwarderConfigSha256 ([string]$forwarder.configSha256)
    Assert-LanForwarderSelfTestRejected `
        -Description "a stale supervisor candidate identity" `
        -Action {
            Assert-LanForwarderSupervisorInvocation `
                -Receipt $receipt `
                -ReceiptPath ([string]$receipt.receiptPath) `
                -CandidateId "20260725T000000Z-ffffffffffff-ffffffff" `
                -ForwarderConfigSha256 ([string]$forwarder.configSha256)
        }
    $arguments =
        Get-LanForwarderSupervisorTaskArguments -Supervisor $supervisor
    foreach ($required in @(
        "-Action Supervise",
        "-ExpectedReceiptPath",
        "-ExpectedCandidateId",
        "-ExpectedForwarderConfigSha256",
        "-ReadyTimeoutSeconds 30"
    )) {
        if (-not $arguments.Contains($required)) {
            throw (
                "LAN forwarder supervision self-test task action omitted " +
                "'$required'"
            )
        }
    }

    try {
        $first = Start-LanForwarder -Receipt $receipt
        $firstProcess = Get-Process -Id $first.ProcessId -ErrorAction Stop
        $firstProcess.Kill()
        $null = $firstProcess.WaitForExit(10000)
        $firstProcess.Dispose()
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            if (-not (Get-Process -Id $first.ProcessId -ErrorAction SilentlyContinue)) {
                break
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "LAN forwarder supervision self-test crash did not terminate"
            }
            Start-Sleep -Milliseconds 100
        } while ($true)

        $repaired = Repair-LanForwarderIfNeeded -Receipt $receipt
        if (
            $repaired.Status -cne "ready" -or
            $repaired.ProcessId -eq $first.ProcessId
        ) {
            throw (
                "LAN forwarder supervision self-test did not replace the " +
                "unexpectedly exited media-only process"
            )
        }
        $owned = @(Get-LanForwarderOwnedEndpoints -Receipt $receipt)
        if (
            $owned.Count -ne 2 -or
            @($owned | ForEach-Object { [string]$_.Name }) -join "," -cne
                "livekitTcp,livekitUdp"
        ) {
            throw (
                "LAN forwarder supervision self-test recovery exposed a " +
                "non-media listener"
            )
        }
    }
    finally {
        Stop-LanForwarder -Receipt $receipt -AllowNotRunning
    }
}

function Invoke-StableEncryptionKeySelfTest {
    $generated = New-EncryptionKey
    if (-not (Test-EncryptionKey -Value $generated)) {
        throw "Stable encryption-key self-test rejected a generated AES-256 key"
    }

    $legacy = New-UrlSafeSecret 48
    if (Test-EncryptionKey -Value $legacy) {
        throw "Stable encryption-key self-test accepted the legacy 48-byte format"
    }
    $rotated = Resolve-StableEncryptionKey `
        -Value $legacy `
        -Name "SELF_TEST_ENCRYPTION_KEY"
    if (-not (Test-EncryptionKey -Value $rotated) -or $rotated -ceq $legacy) {
        throw "Stable encryption-key self-test did not rotate the known legacy format"
    }

    $preserved = Resolve-StableEncryptionKey `
        -Value $generated `
        -Name "SELF_TEST_ENCRYPTION_KEY"
    if ($preserved -cne $generated) {
        throw "Stable encryption-key self-test replaced a valid retained key"
    }

    $corruptionRejected = $false
    try {
        $null = Resolve-StableEncryptionKey `
            -Value "invalid-retained-key" `
            -Name "SELF_TEST_ENCRYPTION_KEY"
    }
    catch {
        $corruptionRejected = $true
    }
    if (-not $corruptionRejected) {
        throw "Stable encryption-key self-test accepted unknown retained corruption"
    }
}

function Invoke-Validate {
    $script:ReleaseNetworkObservation = Resolve-RequestedReleaseTopology `
        -RequestedExposureProfile $ExposureProfile `
        -RequestedBindAddress $BindAddress `
        -AllowPublicNetworkProfile:$AllowPublicNetworkProfile
    if (
        $script:ReleaseNetworkObservation.ExposureProfile -ceq
            $cloudflareTrustedEdgeProfile
    ) {
        # Validate is non-mutating and therefore has no Compose network to
        # inspect. Use one narrow RFC1918 /32 only for rendering/self-tests.
        $script:ReleaseNetworkObservation.TrustedProxyCidr = "10.0.0.1/32"
    }
    $script:BindAddress = $script:ReleaseNetworkObservation.BindAddress
    $requiredCommands = @("podman", "python", "icacls.exe")
    if ($script:BindAddress -cne $podmanBindAddress) {
        $requiredCommands += "node"
    }
    Assert-RequiredTools -Commands $requiredCommands
    Invoke-NativeCommand `
        -FilePath "python" `
        -Arguments @("scripts/validate_local_release.py") `
        -EchoOutput | Out-Null
    Assert-LiveKitImageFlags

    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("k-comms-release-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    try {
        $sample = New-ReleaseEnvironment `
            -Stable (New-StableEnvironment) `
            -Revision ("0" * 40) `
            -ImageReference ("localhost/k-comms:sha-" + ("0" * 40)) `
            -Topology $script:ReleaseNetworkObservation
        Assert-ReleaseEnvironmentTopology `
            -Values $sample `
            -ExpectedBindAddress $script:BindAddress `
            -ExpectedTopology $script:ReleaseNetworkObservation
        $samplePath = Join-Path $temporaryDirectory "release.env"
        Write-EnvironmentFile -Path $samplePath -Values $sample
        $sampleComposePath = Join-Path $temporaryDirectory "compose.source.yaml"
        [IO.File]::Copy($composeFile, $sampleComposePath, $false)
        Invoke-Compose `
            -EnvironmentFile $samplePath `
            -ComposeProject $ProjectName `
            -ComposePath $sampleComposePath `
            -Arguments @("config", "--quiet") | Out-Null
        Invoke-StateRootSafetySelfTest
        Invoke-BindAddressSelfTest
        Invoke-PortPreflightSelfTest
        Invoke-LanForwarderSelfTest -TemporaryDirectory $temporaryDirectory
        Invoke-LanForwarderSupervisionSelfTest `
            -TemporaryDirectory $temporaryDirectory
        Invoke-StableEncryptionKeySelfTest
        Invoke-CapabilityCompatibilitySelfTest
        Invoke-GuestRollbackCompatibilitySelfTest
        Invoke-FailedCandidateCleanupSelfTest
    }
    finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
    Write-Host "Local release composition and orchestration policy passed."
}

function Remove-FailedCandidateRuntime {
    param(
        [Parameter(Mandatory)][string]$EnvironmentFile,
        [Parameter(Mandatory)][string]$ComposeProject,
        [Parameter(Mandatory)][string]$ComposePath,
        [scriptblock]$ComposeInvoker = $null
    )

    $candidateServices = @(
        "app",
        "bootstrap",
        "qualification",
        "migrate",
        "minio-init",
        "livekit",
        "minio",
        "postgres"
    )
    $cleanupErrors = [Collections.Generic.List[string]]::new()

    foreach ($service in $candidateServices) {
        $stopArguments = @("stop", $service)
        $stop =
            if ($ComposeInvoker) {
                & $ComposeInvoker $stopArguments
            }
            else {
                Invoke-Compose `
                    -EnvironmentFile $EnvironmentFile `
                    -ComposeProject $ComposeProject `
                    -ComposePath $ComposePath `
                    -Arguments @("stop", $service) `
                    -AllowFailure
            }
        if ($stop.ExitCode -ne 0) {
            $cleanupErrors.Add("stop $service failed: $($stop.Output)")
        }

        $removeArguments = @("rm", "--force", $service)
        $remove =
            if ($ComposeInvoker) {
                & $ComposeInvoker $removeArguments
            }
            else {
                Invoke-Compose `
                    -EnvironmentFile $EnvironmentFile `
                    -ComposeProject $ComposeProject `
                    -ComposePath $ComposePath `
                    -Arguments @("rm", "--force", $service) `
                    -AllowFailure
            }
        if ($remove.ExitCode -ne 0) {
            $cleanupErrors.Add("remove $service failed: $($remove.Output)")
        }
    }

    $remainingArguments = @("ps", "--all", "--quiet")
    $remaining =
        if ($ComposeInvoker) {
            & $ComposeInvoker $remainingArguments
        }
        else {
            Invoke-Compose `
                -EnvironmentFile $EnvironmentFile `
                -ComposeProject $ComposeProject `
                -ComposePath $ComposePath `
                -Arguments @("ps", "--all", "--quiet") `
                -AllowFailure
        }
    if ($remaining.ExitCode -ne 0) {
        $cleanupErrors.Add("candidate runtime verification failed: $($remaining.Output)")
    }
    elseif ($remaining.Output.Trim()) {
        $cleanupErrors.Add(
            "candidate containers remain after cleanup: $($remaining.Output.Trim())"
        )
    }

    if ($cleanupErrors.Count -gt 0) {
        throw (
            "Failed to remove the first candidate runtime completely. " +
            ($cleanupErrors -join " | ")
        )
    }
}

function Invoke-FailedCandidateCleanupSelfTest {
    $expectedServices = @(
        "app",
        "bootstrap",
        "qualification",
        "migrate",
        "minio-init",
        "livekit",
        "minio",
        "postgres"
    )
    $calls = [Collections.Generic.List[string]]::new()
    $successfulInvoker = {
        param([string[]]$Arguments)

        $calls.Add(($Arguments -join " ")) | Out-Null
        [PSCustomObject]@{
            ExitCode = 0
            Output = ""
        }
    }.GetNewClosure()

    Remove-FailedCandidateRuntime `
        -EnvironmentFile "self-test.env" `
        -ComposeProject "k-comms-cleanup-self-test" `
        -ComposePath "self-test-compose.yaml" `
        -ComposeInvoker $successfulInvoker

    foreach ($service in $expectedServices) {
        if ($calls -notcontains "stop $service") {
            throw "First-candidate cleanup self-test did not stop service $service"
        }
        if ($calls -notcontains "rm --force $service") {
            throw "First-candidate cleanup self-test did not remove service $service"
        }
    }
    if ($calls -notcontains "ps --all --quiet") {
        throw "First-candidate cleanup self-test did not verify the complete project"
    }

    $remainingInvoker = {
        param([string[]]$Arguments)

        [PSCustomObject]@{
            ExitCode = 0
            Output =
                if ($Arguments[0] -eq "ps") {
                    "unexpected-candidate-container"
                }
                else {
                    ""
                }
        }
    }
    $blockedRemaining = $false
    try {
        Remove-FailedCandidateRuntime `
            -EnvironmentFile "self-test.env" `
            -ComposeProject "k-comms-cleanup-self-test" `
            -ComposePath "self-test-compose.yaml" `
            -ComposeInvoker $remainingInvoker
    }
    catch {
        $blockedRemaining = $true
    }
    if (-not $blockedRemaining) {
        throw "First-candidate cleanup self-test accepted a remaining container"
    }
}

function Invoke-Deploy {
    $script:ReleaseNetworkObservation = Resolve-RequestedReleaseTopology `
        -RequestedExposureProfile $ExposureProfile `
        -RequestedBindAddress $BindAddress `
        -AllowPublicNetworkProfile:$AllowPublicNetworkProfile
    $script:BindAddress = $script:ReleaseNetworkObservation.BindAddress
    $requiredCommands = @("git", "podman", "tar", "icacls.exe")
    if ($script:BindAddress -cne $podmanBindAddress) {
        $requiredCommands += "node"
    }
    Assert-RequiredTools -Commands $requiredCommands
    $revision = Assert-CleanRevision
    Ensure-PodmanReady
    Initialize-OwnedStateDirectory -Path $StateRoot -ExpectedProject $ProjectName
    $operationLock = Enter-ReleaseOperationLock -Path $StateRoot -ComposeProject $ProjectName
    try {
        Invoke-DeployLocked -Revision $revision
    }
    finally {
        Exit-ReleaseOperationLock -Lock $operationLock
    }
}

function Invoke-DeployLocked {
    param([Parameter(Mandatory)][string]$Revision)

    $releaseNetworkObservation =
        Assert-ReleaseNetworkObservationCurrent `
            -Expected $script:ReleaseNetworkObservation
    New-Item -ItemType Directory -Path (Join-Path $StateRoot "history") -Force | Out-Null

    $previousReceipt = Get-CurrentReceipt
    if ($previousReceipt -and $previousReceipt.projectName -ne $ProjectName) {
        throw (
            "The retained release uses Compose project $($previousReceipt.projectName). " +
            "Reuse that project name or select a new -StateRoot for an isolated project."
        )
    }
    Assert-CandidatePorts `
        -CandidateBindAddress $BindAddress `
        -CandidateAppPort $AppPort `
        -CandidateMinioPort $MinioPort `
        -CandidateMinioConsolePort $MinioConsolePort `
        -CandidateLiveKitSignalPort $LiveKitSignalPort `
        -CandidateLiveKitTcpPort $LiveKitTcpPort `
        -CandidateLiveKitUdpPort $LiveKitUdpPort `
        -PreviousReceipt $previousReceipt `
        -ForwarderProfile $(if (
            $releaseNetworkObservation.ExposureProfile -ceq
                $cloudflareTrustedEdgeProfile
        ) {
            "media-only"
        } else {
            "full"
        })

    $shortRevision = $Revision.Substring(0, 12)
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $candidateNonce = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $candidateId = "$stamp-$shortRevision-$candidateNonce"
    $candidateDirectory = Join-Path `
        (Join-Path $StateRoot "history") `
        $candidateId
    New-Item -ItemType Directory -Path $candidateDirectory | Out-Null

    $imageReference =
        "localhost/k-comms:sha-$Revision-$($stamp.ToLowerInvariant())-$candidateNonce"
    $composeSourcePath = Join-Path $candidateDirectory "compose.source.yaml"
    $environmentFile = Join-Path $candidateDirectory "release.env"
    $receiptPath = Join-Path $candidateDirectory "deployment.json"
    $migrationLogPath = Join-Path $candidateDirectory "migration.log"
    $candidateTouchedRuntime = $false
    $composeSourceSha256 = $null
    $environmentSha256 = $null
    $source = $null
    $stableEnvironment = $null
    $rendered = $null
    $image = $null
    $migrationSucceeded = $false
    $forwarderRecord = [ordered]@{
        required = $false
        kind = "not-required"
    }
    $candidateForwarderReceipt = $null
    $candidateForwarderStarted = $false
    try {
        $source = New-ImmutableSourceContext `
            -ExpectedRevision $Revision `
            -CandidateDirectory $candidateDirectory
        $snapshotComposePath =
            Join-Path $source.contextPath "deploy\compose.local-release.yaml"
        [IO.File]::Copy($snapshotComposePath, $composeSourcePath, $false)
        $composeSourceSha256 =
            (Get-FileHash -LiteralPath $composeSourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if (
            $releaseNetworkObservation.ExposureProfile -ceq
                $cloudflareTrustedEdgeProfile -or
            $BindAddress -cne $podmanBindAddress
        ) {
            $forwarderRecord = New-LanForwarderReceiptRecord `
                -ImmutableSourceRoot $source.contextPath `
                -CandidateDirectory $candidateDirectory `
                -ExpectedBindAddress $BindAddress `
                -ExpectedAppPort $AppPort `
                -ExpectedMinioPort $MinioPort `
                -ExpectedLiveKitSignalPort $LiveKitSignalPort `
                -ExpectedLiveKitTcpPort $LiveKitTcpPort `
                -ExpectedLiveKitUdpPort $LiveKitUdpPort `
                -ReceiptPath $receiptPath `
                -CandidateId $candidateId `
                -Profile $(if (
                    $releaseNetworkObservation.ExposureProfile -ceq
                        $cloudflareTrustedEdgeProfile
                ) {
                    "media-only"
                } else {
                    "full"
                })
        }

        $stableEnvironment = Get-StableEnvironment
        $releaseEnvironment = New-ReleaseEnvironment `
            -Stable $stableEnvironment `
            -Revision $Revision `
            -ImageReference $imageReference `
            -Topology $releaseNetworkObservation
        if (
            $releaseNetworkObservation.ExposureProfile -cne
                $cloudflareTrustedEdgeProfile
        ) {
            Assert-ReleaseEnvironmentTopology `
                -Values $releaseEnvironment `
                -ExpectedBindAddress $BindAddress `
                -ExpectedTopology $releaseNetworkObservation
        }
        Write-EnvironmentFile -Path $environmentFile -Values $releaseEnvironment
        $environmentSha256 =
            (Get-FileHash -LiteralPath $environmentFile -Algorithm SHA256).Hash.ToLowerInvariant()

        $rendered = Write-RenderedConfiguration `
            -EnvironmentFile $environmentFile `
            -ComposeProject $ProjectName `
            -ComposePath $composeSourcePath `
            -DestinationDirectory $candidateDirectory `
            -Secrets $stableEnvironment

        Write-Host "Building exact K-Comms revision $Revision..."
        Invoke-NativeCommand `
            -FilePath "podman" `
            -Arguments @(
                "build",
                "--format", "docker",
                "--target", "runtime",
                "--build-arg", "OCI_SOURCE=https://github.com/Soyuz-Tec/k-comms",
                "--build-arg", "OCI_REVISION=$Revision",
                "--build-arg", "OCI_VERSION=sha-$Revision",
                "--tag", $imageReference,
                "."
            ) `
            -WorkingDirectory $source.contextPath `
            -EchoOutput | Out-Null
        Assert-RepositoryHead `
            -ExpectedRevision $Revision `
            -Phase "after building the immutable candidate image"
        $image = Get-ImageEvidence -ImageReference $imageReference -ExpectedRevision $Revision
        if (
            $releaseNetworkObservation.ExposureProfile -ceq
                $cloudflareTrustedEdgeProfile
        ) {
            # Compose creates the isolated application network. Only after it
            # exists can the manager seal the one exact host-side gateway /32
            # that is allowed to supply Cloudflare's forwarded scheme.
            $candidateTouchedRuntime = $true
            Invoke-Compose `
                -EnvironmentFile $environmentFile `
                -ComposeProject $ProjectName `
                -ComposePath $composeSourcePath `
                -Arguments @(
                    "up",
                    "-d",
                    "--no-build",
                    "postgres",
                    "minio",
                    "livekit"
                ) `
                -EchoOutput | Out-Null
            $releaseNetworkObservation.TrustedProxyCidr =
                Resolve-ComposeTrustedProxyCidr `
                    -EnvironmentFile $environmentFile `
                    -ComposeProject $ProjectName `
                    -ComposePath $composeSourcePath
            $releaseEnvironment = New-ReleaseEnvironment `
                -Stable $stableEnvironment `
                -Revision $Revision `
                -ImageReference $imageReference `
                -Topology $releaseNetworkObservation
            Assert-ReleaseEnvironmentTopology `
                -Values $releaseEnvironment `
                -ExpectedBindAddress $BindAddress `
                -ExpectedTopology $releaseNetworkObservation
            Write-EnvironmentFile `
                -Path $environmentFile `
                -Values $releaseEnvironment
            $environmentSha256 =
                (Get-FileHash `
                    -LiteralPath $environmentFile `
                    -Algorithm SHA256).Hash.ToLowerInvariant()
            $rendered = Write-RenderedConfiguration `
                -EnvironmentFile $environmentFile `
                -ComposeProject $ProjectName `
                -ComposePath $composeSourcePath `
                -DestinationDirectory $candidateDirectory `
                -Secrets $stableEnvironment
        }
        $candidateForwarderReceipt = [PSCustomObject]@{
            schemaVersion = 6
            candidateId = $candidateId
            receiptPath = $receiptPath
            publicAppUrl = [string]$releaseNetworkObservation.PublicAppUrl
            publicOrigins =
                New-ReceiptPublicOriginsRecord `
                    -Topology $releaseNetworkObservation
            network = New-ReceiptNetworkRecord `
                -Observation $releaseNetworkObservation `
                -PublicAppUrl ([string]$releaseNetworkObservation.PublicAppUrl)
            ports = [PSCustomObject]@{
                app = $AppPort
                minio = $MinioPort
                minioConsole = $MinioConsolePort
                livekitSignal = $LiveKitSignalPort
                livekitTcp = $LiveKitTcpPort
                livekitUdp = $LiveKitUdpPort
            }
            forwarder = $forwarderRecord
        }

        $releaseNetworkObservation =
            Assert-ReleaseNetworkObservationCurrent `
                -Expected $releaseNetworkObservation
        if ($previousReceipt) {
            Unregister-LanForwarderSupervisor `
                -Receipt $previousReceipt `
                -AllowNotRegistered
            Stop-LanForwarder -Receipt $previousReceipt -AllowNotRunning
        }
        $candidateTouchedRuntime = $true
        $migrationOutput = Start-ReleaseServices `
            -EnvironmentFile $environmentFile `
            -ComposeProject $ProjectName `
            -ComposePath $composeSourcePath `
            -RunMigration
        if (
            $releaseNetworkObservation.ExposureProfile -ceq
                $cloudflareTrustedEdgeProfile
        ) {
            $currentTrustedProxyCidr = Resolve-ComposeTrustedProxyCidr `
                -EnvironmentFile $environmentFile `
                -ComposeProject $ProjectName `
                -ComposePath $composeSourcePath
            if (
                $currentTrustedProxyCidr -cne
                    [string]$releaseNetworkObservation.TrustedProxyCidr
            ) {
                throw (
                    "Podman application-network gateway changed before trusted " +
                    "edge activation"
                )
            }
        }
        $migrationSucceeded = $true
        [IO.File]::WriteAllText(
            $migrationLogPath,
            [string]$migrationOutput,
            (New-Object Text.UTF8Encoding($false))
        )
        Ensure-InstantRoomTenant `
            -EnvironmentFile $environmentFile `
            -ComposeProject $ProjectName `
            -ComposePath $composeSourcePath `
            -ExpectedBindAddress $podmanBindAddress `
            -ExpectedAppPort $AppPort `
            -ReleaseEnvironment $releaseEnvironment
        Start-SealedApplication `
            -EnvironmentFile $environmentFile `
            -ComposeProject $ProjectName `
            -ComposePath $composeSourcePath
        Wait-ContainerHealth `
            -EnvironmentFile $environmentFile `
            -ComposeProject $ProjectName `
            -ComposePath $composeSourcePath `
            -Service "app"
        Wait-Application `
            -ExpectedBindAddress $podmanBindAddress `
            -ExpectedAppPort $AppPort `
            -ExpectedMinioPort $MinioPort `
            -ExpectedLiveKitPort $LiveKitSignalPort `
            -RequireGuestLinks `
            -RequireInstantRooms
        if (
            $releaseNetworkObservation.ExposureProfile -ceq
                $cloudflareTrustedEdgeProfile -or
            $BindAddress -cne $podmanBindAddress
        ) {
            $null = Start-LanForwarder -Receipt $candidateForwarderReceipt
            $candidateForwarderStarted = $true
            $null = Assert-LanForwarderReady `
                -Receipt $candidateForwarderReceipt
            if (
                $releaseNetworkObservation.ExposureProfile -ceq
                    $cloudflareTrustedEdgeProfile
            ) {
                Wait-TrustedEdgeApplication `
                    -Topology $releaseNetworkObservation `
                    -RequireGuestLinks `
                    -RequireInstantRooms
            }
            else {
                Wait-Application `
                    -ExpectedBindAddress $BindAddress `
                    -ExpectedAppPort $AppPort `
                    -ExpectedMinioPort $MinioPort `
                    -ExpectedLiveKitPort $LiveKitSignalPort `
                    -RequireGuestLinks `
                    -RequireInstantRooms
            }
        }
        $releaseNetworkObservation =
            Assert-ReleaseNetworkObservationCurrent `
                -Expected $releaseNetworkObservation

        if (
            $releaseNetworkObservation.ExposureProfile -ceq
                $cloudflareTrustedEdgeProfile
        ) {
            Set-LanForwarderSupervisorScheduleRecord `
                -Forwarder $forwarderRecord
        }
        $receipt = [ordered]@{
            schemaVersion = 6
            status = "healthy"
            receiptPath = $receiptPath
            deployedAt = [DateTime]::UtcNow.ToString("o")
            repository = "https://github.com/Soyuz-Tec/k-comms"
            revision = $Revision
            candidateId = $candidateId
            imageReference = $imageReference
            imageId = $image.imageId
            imageDigest = $image.imageDigest
            repoDigest = $image.repoDigest
            imageLabelRevision = $image.labelRevision
            projectName = $ProjectName
            environmentFile = $environmentFile
            environmentSha256 = $environmentSha256
            composeSourcePath = $composeSourcePath
            composeSourceSha256 = $composeSourceSha256
            sourceArchivePath = $source.archivePath
            sourceArchiveSha256 = $source.archiveSha256
            renderedConfigPath = $rendered.path
            redactedConfigPath = $rendered.redactedPath
            renderedConfigSha256 = $rendered.sha256
            publicAppUrl = [string]$releaseNetworkObservation.PublicAppUrl
            publicOrigins =
                New-ReceiptPublicOriginsRecord `
                    -Topology $releaseNetworkObservation
            network = New-ReceiptNetworkRecord `
                -Observation $releaseNetworkObservation `
                -PublicAppUrl ([string]$releaseNetworkObservation.PublicAppUrl)
            forwarder = $forwarderRecord
            migration = [ordered]@{
                command = "CommsCore.Release.migrate()"
                direction = "up"
                status = "succeeded"
                logPath = $migrationLogPath
            }
            rollbackCapabilities = @(
                "guest_identity_v1"
                "guest_admission_expiry_worker_v1"
                "instant_room_lifecycle_v1"
                "instant_room_presence_lease_v1"
                "instant_room_expiry_worker_v1"
                "conversation_only_human_v1"
            )
            ports = [ordered]@{
                app = $AppPort
                minio = $MinioPort
                minioConsole = $MinioConsolePort
                livekitSignal = $LiveKitSignalPort
                livekitTcp = $LiveKitTcpPort
                livekitUdp = $LiveKitUdpPort
            }
            previousReceiptPath = if ($previousReceipt) { $previousReceipt.receiptPath } else { $null }
        }
        Write-JsonAtomic -Path $receiptPath -Value $receipt
        $null = Register-LanForwarderSupervisor -Receipt $receipt
        Write-JsonAtomic -Path $currentPointerPath -Value ([ordered]@{
            receiptPath = $receiptPath
            revision = $Revision
            imageReference = $imageReference
            imageId = $image.imageId
            publicAppUrl = [string]$releaseNetworkObservation.PublicAppUrl
            updatedAt = [DateTime]::UtcNow.ToString("o")
        })
    }
    catch {
        $deploymentError = $_
        if ($candidateForwarderReceipt) {
            try {
                Unregister-LanForwarderSupervisor `
                    -Receipt $candidateForwarderReceipt `
                    -AllowNotRegistered
            }
            catch {
                throw (
                    "Candidate deployment failed and its supervisor task could " +
                    "not be removed safely. Candidate: " +
                    "$($deploymentError.Exception.Message) Supervisor cleanup: " +
                    "$($_.Exception.Message)"
                )
            }
        }
        if ($candidateForwarderReceipt -and $candidateForwarderStarted) {
            try {
                Stop-LanForwarder `
                    -Receipt $candidateForwarderReceipt `
                    -AllowNotRunning
                $candidateForwarderStarted = $false
            }
            catch {
                throw (
                    "Candidate deployment failed and its public LAN forwarder " +
                    "could not be stopped safely. Candidate: " +
                    "$($deploymentError.Exception.Message) Forwarder cleanup: " +
                    "$($_.Exception.Message)"
                )
            }
        }
        try {
            Write-JsonAtomic -Path (Join-Path $candidateDirectory "failure.json") -Value ([ordered]@{
                failedAt = [DateTime]::UtcNow.ToString("o")
                revision = $Revision
                candidateId = $candidateId
                imageReference = $imageReference
                publicAppUrl = [string]$releaseNetworkObservation.PublicAppUrl
                publicOrigins =
                    New-ReceiptPublicOriginsRecord `
                        -Topology $releaseNetworkObservation
                network = New-ReceiptNetworkRecord `
                    -Observation $releaseNetworkObservation `
                    -PublicAppUrl ([string]$releaseNetworkObservation.PublicAppUrl)
                environmentSha256 = $environmentSha256
                composeSourcePath = $composeSourcePath
                composeSourceSha256 = $composeSourceSha256
                sourceArchivePath = if ($source) { $source.archivePath } else { $null }
                sourceArchiveSha256 = if ($source) { $source.archiveSha256 } else { $null }
                forwarder = $forwarderRecord
                message = $deploymentError.Exception.Message
                previousReceiptPath = if ($previousReceipt) { $previousReceipt.receiptPath } else { $null }
            })
        }
        catch {
            Write-Warning "Could not persist the candidate failure receipt: $($_.Exception.Message)"
        }
        if ($previousReceipt -and $candidateTouchedRuntime) {
            Write-Warning "Candidate failed; restoring the retained application image without down migrations."
            try {
                if ($migrationSucceeded) {
                    Assert-GuestRollbackSafe `
                        -CurrentReceipt ([PSCustomObject]@{
                            environmentFile = $environmentFile
                            projectName = $ProjectName
                            composeSourcePath = $composeSourcePath
                        }) `
                        -TargetReceipt $previousReceipt
                }
                Restore-Release -Receipt $previousReceipt -UpdatePointer
            }
            catch {
                throw (
                    "Candidate deployment failed and automatic application rollback also failed. " +
                    "Candidate: $($deploymentError.Exception.Message) Rollback: $($_.Exception.Message)"
                )
            }
        }
        elseif ($candidateTouchedRuntime) {
            Write-Warning "First candidate failed; stopping and removing every candidate service."
            try {
                Remove-FailedCandidateRuntime `
                    -EnvironmentFile $environmentFile `
                    -ComposeProject $ProjectName `
                    -ComposePath $composeSourcePath
            }
            catch {
                throw (
                    "Candidate deployment failed and complete first-candidate cleanup also failed. " +
                    "Candidate: $($deploymentError.Exception.Message) Cleanup: $($_.Exception.Message)"
                )
            }
        }
        throw $deploymentError
    }
    finally {
        if ($source -and $source.contextPath) {
            try {
                Remove-ImmutableSourceContext `
                    -ContextPath $source.contextPath `
                    -CandidateDirectory $candidateDirectory
            }
            catch {
                Write-Warning (
                    "Could not remove the extracted immutable source context: " +
                    $_.Exception.Message
                )
            }
        }
    }

    Write-Host (
        "K-Comms local release is healthy at " +
        "$($releaseNetworkObservation.PublicAppUrl)/app/"
    )
    Write-Host "Bind address: $BindAddress"
    Write-Host "Public host: $($releaseNetworkObservation.PublicHost)"
    Write-Host "Exposure profile: $($releaseNetworkObservation.ExposureProfile)"
    Write-Host (
        "Network interface: $($releaseNetworkObservation.InterfaceAlias) " +
        "(index $($releaseNetworkObservation.InterfaceIndex))"
    )
    Write-Host (
        "Network profile: $($releaseNetworkObservation.NetworkName) " +
        "[$($releaseNetworkObservation.NetworkCategory)]"
    )
    Write-Host (
        "Public network profile override authorized: " +
        "$($releaseNetworkObservation.AllowPublicNetworkProfile)"
    )
    Write-Host (
        "Public network profile override used: " +
        "$($releaseNetworkObservation.PublicNetworkProfileOverrideUsed)"
    )
    Write-Host "Revision: $Revision"
    Write-Host "Image: $imageReference"
    Write-Host "Image ID: $($image.imageId)"
    Write-Host "Image digest: $($image.imageDigest)"
    Write-Host "Receipt: $receiptPath"
    Write-Host "Redacted rendered config: $($rendered.redactedPath)"
}

function Invoke-Rollback {
    Assert-RequiredTools -Commands @("podman", "icacls.exe")
    Ensure-PodmanReady
    if (-not (Test-Path -LiteralPath $StateRoot)) {
        throw "No current local release exists"
    }
    Initialize-OwnedStateDirectory -Path $StateRoot -ExpectedProject $ProjectName
    $operationLock = Enter-ReleaseOperationLock -Path $StateRoot -ComposeProject $ProjectName
    try {
        Invoke-RollbackLocked
    }
    finally {
        Exit-ReleaseOperationLock -Lock $operationLock
    }
}

function Assert-RollbackExposureTopologyCompatible {
    param(
        [Parameter(Mandatory)]$CurrentReceipt,
        [Parameter(Mandatory)]$CurrentTopology,
        [Parameter(Mandatory)]$TargetReceipt,
        [Parameter(Mandatory)]$TargetTopology
    )

    $currentProfile = Get-ReceiptExposureProfile -Receipt $CurrentReceipt
    $targetProfile = Get-ReceiptExposureProfile -Receipt $TargetReceipt
    $trustedEdgeInvolved = (
        $currentProfile -ceq $cloudflareTrustedEdgeProfile -or
        $targetProfile -ceq $cloudflareTrustedEdgeProfile
    )
    if (-not $trustedEdgeInvolved) {
        return
    }
    if (
        $currentProfile -cne $cloudflareTrustedEdgeProfile -or
        $targetProfile -cne $cloudflareTrustedEdgeProfile
    ) {
        throw (
            "Rollback cannot change between the Cloudflare trusted-edge profile " +
            "and a loopback or private-LAN exposure profile. Deploy the intended " +
            "profile explicitly instead."
        )
    }

    foreach ($comparison in @(
        @(
            "public application origin",
            [string]$CurrentTopology.PublicAppUrl,
            [string]$TargetTopology.PublicAppUrl
        ),
        @(
            "application WebSocket origin",
            [string]$CurrentTopology.AppWebSocketOrigin,
            [string]$TargetTopology.AppWebSocketOrigin
        ),
        @(
            "media origin",
            [string]$CurrentTopology.LiveKitOrigin,
            [string]$TargetTopology.LiveKitOrigin
        ),
        @(
            "object-storage origin",
            [string]$CurrentTopology.ObjectOrigin,
            [string]$TargetTopology.ObjectOrigin
        ),
        @(
            "media node address",
            [string]$CurrentTopology.MediaNodeAddress,
            [string]$TargetTopology.MediaNodeAddress
        ),
        @(
            "trusted proxy CIDR",
            [string]$CurrentTopology.TrustedProxyCidr,
            [string]$TargetTopology.TrustedProxyCidr
        ),
        @(
            "trusted-edge confirmation",
            [string]$CurrentTopology.TrustedEdgeConfirmation,
            [string]$TargetTopology.TrustedEdgeConfirmation
        )
    )) {
        if ($comparison[1] -cne $comparison[2]) {
            throw (
                "Rollback target changes the sealed trusted-edge " +
                "$($comparison[0]); deploy that topology explicitly instead"
            )
        }
    }
    foreach ($portName in @(
        "app",
        "minio",
        "livekitSignal",
        "livekitTcp",
        "livekitUdp"
    )) {
        if (
            [int]$CurrentReceipt.ports.$portName -ne
                [int]$TargetReceipt.ports.$portName
        ) {
            throw (
                "Rollback target changes sealed trusted-edge port '$portName'; " +
                "deploy that topology explicitly instead"
            )
        }
    }

    foreach ($receiptPair in @(
        @("current", $CurrentReceipt),
        @("target", $TargetReceipt)
    )) {
        $forwarder = Get-ReceiptForwarder -Receipt $receiptPair[1]
        if (
            -not $forwarder -or
            [string](Get-ReceiptTopLevelProperty `
                -Receipt $forwarder `
                -Name "profile" `
                -DefaultValue "") -cne "media-only"
        ) {
            throw (
                "Trusted-edge rollback $($receiptPair[0]) receipt must seal the " +
                "media-only forwarder profile"
            )
        }
    }
}

function Invoke-RollbackLocked {
    $current = Get-CurrentReceipt
    if (-not $current) {
        throw "No current local release exists"
    }
    if (-not $current.previousReceiptPath) {
        throw "The current local release has no retained predecessor"
    }
    $target = Read-JsonFile -Path $current.previousReceiptPath
    Assert-RetainedReleaseAssets -Receipt $current
    Assert-RetainedReleaseAssets -Receipt $target
    $currentTopology = Resolve-ReceiptNetworkTopology -Receipt $current
    $targetTopology = Resolve-ReceiptNetworkTopology -Receipt $target
    Assert-RollbackExposureTopologyCompatible `
        -CurrentReceipt $current `
        -CurrentTopology $currentTopology `
        -TargetReceipt $target `
        -TargetTopology $targetTopology
    if (
        (Test-ReceiptRequiresLanForwarder -Receipt $current) -or
        (Test-ReceiptRequiresLanForwarder -Receipt $target)
    ) {
        Assert-RequiredTools -Commands @("node")
    }
    Unregister-LanForwarderSupervisor `
        -Receipt $current `
        -AllowNotRegistered
    Stop-LanForwarder -Receipt $current -AllowNotRunning
    Assert-GuestRollbackSafe `
        -CurrentReceipt $current `
        -TargetReceipt $target `
        -RestoreCurrentOnFailure
    Restore-RollbackTargetOrCurrent `
        -CurrentReceipt $current `
        -TargetReceipt $target

    $eventPath = Join-Path `
        (Split-Path -Parent $current.receiptPath) `
        ("rollback-" + [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") + ".json")
    Write-JsonAtomic -Path $eventPath -Value ([ordered]@{
        rolledBackAt = [DateTime]::UtcNow.ToString("o")
        fromReceiptPath = $current.receiptPath
        toReceiptPath = $target.receiptPath
        publicAppUrl = $targetTopology.PublicAppUrl
        network = New-ReceiptNetworkRecord `
            -Observation $targetTopology `
            -PublicAppUrl $targetTopology.PublicAppUrl
        migrationDirection = "none"
        result = "healthy"
    })
    Write-Host "Restored K-Comms revision $($target.revision) without down migrations."
    Write-Host "Bind address: $($targetTopology.BindAddress)"
    Write-Host "Public host: $($targetTopology.PublicHost)"
    Write-Host (
        "Network profile: $($targetTopology.NetworkName) " +
        "[$($targetTopology.NetworkCategory)]"
    )
    Write-Host (
        "Public network profile override used: " +
        "$($targetTopology.PublicNetworkProfileOverrideUsed)"
    )
    Write-Host "Application: $($targetTopology.PublicAppUrl)/app/"
    Write-Host "Rollback receipt: $eventPath"
}

function Get-AppRuntimeObservation {
    param([Parameter(Mandatory)]$Receipt)

    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{
            Status = "unavailable"
            Health = "unknown"
            ImageId = ""
            ImageMatchesReceipt = $false
            Detail = "podman command not found"
        }
    }

    $probe = Invoke-NativeCommand `
        -FilePath "podman" `
        -Arguments @("info", "--format", "{{.Host.Arch}}") `
        -AllowFailure
    if ($probe.ExitCode -ne 0) {
        return [PSCustomObject]@{
            Status = "unavailable"
            Health = "unknown"
            ImageId = ""
            ImageMatchesReceipt = $false
            Detail = "Podman is not ready"
        }
    }

    $containerQuery = Invoke-Compose `
        -EnvironmentFile $Receipt.environmentFile `
        -ComposeProject $Receipt.projectName `
        -ComposePath $Receipt.composeSourcePath `
        -Arguments @("ps", "-q", "app") `
        -AllowFailure
    if ($containerQuery.ExitCode -ne 0) {
        return [PSCustomObject]@{
            Status = "unavailable"
            Health = "unknown"
            ImageId = ""
            ImageMatchesReceipt = $false
            Detail = "Compose could not inspect the application"
        }
    }

    $containerId = $containerQuery.Output.Trim()
    if (-not $containerId) {
        return [PSCustomObject]@{
            Status = "stopped"
            Health = "not_running"
            ImageId = ""
            ImageMatchesReceipt = $false
            Detail = "application container is not running"
        }
    }

    $inspection = Invoke-NativeCommand `
        -FilePath "podman" `
        -Arguments @(
            "inspect",
            "--format",
            "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.Image}}",
            $containerId
        ) `
        -AllowFailure
    if ($inspection.ExitCode -ne 0) {
        return [PSCustomObject]@{
            Status = "unavailable"
            Health = "unknown"
            ImageId = ""
            ImageMatchesReceipt = $false
            Detail = "Podman could not inspect the application container"
        }
    }

    $parts = $inspection.Output.Trim().Split("|", 3)
    $observedImage = if ($parts.Count -ge 3) { $parts[2] } else { "" }
    [PSCustomObject]@{
        Status = if ($parts.Count -ge 1) { $parts[0] } else { "unknown" }
        Health = if ($parts.Count -ge 2 -and $parts[1]) { $parts[1] } else { "unknown" }
        ImageId = $observedImage
        ImageMatchesReceipt = $observedImage -eq [string]$Receipt.imageId
        Detail = "observed"
    }
}

function Assert-ReceiptRuntimeHealthy {
    param([Parameter(Mandatory)]$Receipt)

    Assert-RetainedReleaseAssets -Receipt $Receipt
    $null = Resolve-ReceiptNetworkTopology -Receipt $Receipt
    Assert-ReceiptTrustedProxyGatewayCurrent -Receipt $Receipt
    $application = Get-AppRuntimeObservation -Receipt $Receipt
    if (
        $application.Status -cne "running" -or
        $application.Health -cne "healthy" -or
        -not $application.ImageMatchesReceipt
    ) {
        throw (
            "Retained application is not running healthy on its exact receipt " +
            "image: state=$($application.Status), " +
            "health=$($application.Health), " +
            "image_match=$($application.ImageMatchesReceipt)"
        )
    }
    $forwarder = Assert-LanForwarderReady -Receipt $Receipt
    $supervisor =
        Assert-LanForwarderSupervisorTaskReady -Receipt $Receipt
    [PSCustomObject]@{
        Application = $application
        Forwarder = $forwarder
        Supervisor = $supervisor
    }
}

function Invoke-HealthCheck {
    $current = Get-CurrentReceipt
    if (-not $current) {
        throw "No successful K-Comms local release is recorded"
    }
    $health = Assert-ReceiptRuntimeHealthy -Receipt $current
    Write-Host (
        "K-Comms local release is healthy: revision=$($current.revision), " +
        "image_match=$($health.Application.ImageMatchesReceipt), " +
        "forwarder=$($health.Forwarder.Status), " +
        "supervisor=$($health.Supervisor.Status)"
    )
}

function Invoke-Supervise {
    foreach ($required in @(
        @("ExpectedReceiptPath", $ExpectedReceiptPath),
        @("ExpectedCandidateId", $ExpectedCandidateId),
        @("ExpectedForwarderConfigSha256", $ExpectedForwarderConfigSha256)
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$required[1])) {
            throw "Supervise requires -$($required[0])"
        }
    }
    if (
        $ExpectedCandidateId -notmatch
            "^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}-[0-9a-f]{8}$"
    ) {
        throw "Supervise expected candidate identity is malformed"
    }
    if ($ExpectedForwarderConfigSha256 -notmatch "^[0-9a-f]{64}$") {
        throw "Supervise expected forwarder configuration hash is malformed"
    }
    $operationLock =
        Enter-SupervisorOperationLock `
            -Path $StateRoot `
            -ComposeProject $ProjectName
    try {
        $current = Get-SupervisorCurrentReceipt `
            -ReceiptPath $ExpectedReceiptPath `
            -CandidateId $ExpectedCandidateId
        Assert-LanForwarderSupervisorInvocation `
            -Receipt $current `
            -ReceiptPath $ExpectedReceiptPath `
            -CandidateId $ExpectedCandidateId `
            -ForwarderConfigSha256 $ExpectedForwarderConfigSha256
        if (-not (Test-ReceiptIsCloudflareTrustedEdge -Receipt $current)) {
            throw "The receipt-bound media supervisor requires trusted-edge mode"
        }
        Assert-RetainedReleaseAssets -Receipt $current
        $null = Assert-LanForwarderSupervisorTaskReady -Receipt $current
        $null = Resolve-ReceiptNetworkTopology -Receipt $current
        Assert-ReceiptTrustedProxyGatewayCurrent -Receipt $current
        $application = Get-AppRuntimeObservation -Receipt $current
        if (
            $application.Status -cne "running" -or
            $application.Health -cne "healthy" -or
            -not $application.ImageMatchesReceipt
        ) {
            throw (
                "Supervisor will not start media forwarding while the exact " +
                "retained application is unhealthy"
            )
        }
        $before = Get-LanForwarderObservation -Receipt $current
        $after = Repair-LanForwarderIfNeeded -Receipt $current
        if ($before.Status -cne "ready") {
            Write-Host (
                "Recovered receipt-bound media forwarder: " +
                "pid=$($after.ProcessId)"
            )
        }
    }
    finally {
        Exit-ReleaseOperationLock -Lock $operationLock
    }
}

function Invoke-Status {
    $current = Get-CurrentReceipt
    if (-not $current) {
        throw "No successful K-Comms local release is recorded"
    }
    Assert-RetainedReleaseAssets -Receipt $current
    $networkTopologyMatchesReceipt = $false
    $networkTopologyDetail = ""
    try {
        $observedNetworkTopology =
            Resolve-ReceiptNetworkTopology -Receipt $current
        Assert-ReceiptTrustedProxyGatewayCurrent -Receipt $current
        $networkTopologyMatchesReceipt = $true
        $networkTopologyDetail = (
            "$($observedNetworkTopology.InterfaceAlias) " +
            "(index $($observedNetworkTopology.InterfaceIndex)); " +
            "$($observedNetworkTopology.NetworkName) " +
            "[$($observedNetworkTopology.NetworkCategory)]"
        )
    }
    catch {
        $networkTopologyDetail = $_.Exception.Message
    }
    $observation = Get-AppRuntimeObservation -Receipt $current
    $forwarderObservation = Get-LanForwarderObservation -Receipt $current
    $supervisorObservation =
        Get-LanForwarderSupervisorTaskObservation -Receipt $current
    $recordedBindAddress = Get-ReceiptBindAddress -Receipt $current
    $recordedPublicHost = Get-ReceiptPublicHost -Receipt $current
    $recordedPublicAppUrl = Get-ReceiptPublicAppUrl -Receipt $current
    $recordedNetworkProfile = Get-ReceiptNetworkProfileRecord -Receipt $current
    Write-Host "Recorded revision: $($current.revision)"
    Write-Host "Recorded image: $($current.imageReference)"
    Write-Host "Recorded image ID: $($current.imageId)"
    Write-Host "Image digest: $($current.imageDigest)"
    Write-Host "Bind address: $recordedBindAddress"
    Write-Host "Public host: $recordedPublicHost"
    Write-Host "Exposure profile: $(Get-ReceiptExposureProfile -Receipt $current)"
    if (Test-ReceiptIsCloudflareTrustedEdge -Receipt $current) {
        $trustedPublicOrigins = Get-ReceiptPublicOriginsRecord -Receipt $current
        Write-Host (
            "Media node address: " +
            [string](Get-ReceiptNetworkProperty `
                -Receipt $current `
                -Name "mediaNodeAddress" `
                -DefaultValue "")
        )
        Write-Host (
            "Trusted proxy CIDR: " +
            [string](Get-ReceiptNetworkProperty `
                -Receipt $current `
                -Name "trustedProxyCidr" `
                -DefaultValue "")
        )
        if ($trustedPublicOrigins) {
            Write-Host (
                "Media origin: " +
                [string](Get-ReceiptTopLevelProperty `
                    -Receipt $trustedPublicOrigins `
                    -Name "media" `
                    -DefaultValue "")
            )
            Write-Host (
                "Object origin: " +
                [string](Get-ReceiptTopLevelProperty `
                    -Receipt $trustedPublicOrigins `
                    -Name "objectStorage" `
                    -DefaultValue "")
            )
        }
    }
    Write-Host (
        "Recorded network interface: $($recordedNetworkProfile.InterfaceAlias) " +
        "(index $($recordedNetworkProfile.InterfaceIndex))"
    )
    Write-Host (
        "Recorded network profile: $($recordedNetworkProfile.NetworkName) " +
        "[$($recordedNetworkProfile.NetworkCategory)]"
    )
    Write-Host (
        "Public network profile override authorized: " +
        "$($recordedNetworkProfile.AllowPublicNetworkProfile)"
    )
    Write-Host (
        "Public network profile override used: " +
        "$($recordedNetworkProfile.PublicNetworkProfileOverrideUsed)"
    )
    Write-Host (
        "Observed network topology matches receipt: " +
        "$networkTopologyMatchesReceipt"
    )
    Write-Host "Observed network topology: $networkTopologyDetail"
    Write-Host "Application: $recordedPublicAppUrl/app/"
    Write-Host "Receipt: $($current.receiptPath)"
    Write-Host "Observed application state: $($observation.Status)"
    Write-Host "Observed application health: $($observation.Health)"
    if ($observation.ImageId) {
        Write-Host "Observed image ID: $($observation.ImageId)"
    }
    Write-Host "Observed image matches receipt: $($observation.ImageMatchesReceipt)"
    Write-Host "Forwarder: $($forwarderObservation.Status)"
    if ($forwarderObservation.Required) {
        Write-Host (
            "Observed forwarder matches receipt: " +
            "$($forwarderObservation.ProcessMatchesReceipt)"
        )
        Write-Host (
            "Observed forwarder configuration hash matches receipt: " +
            "$($forwarderObservation.ConfigHashMatchesReceipt)"
        )
        Write-Host (
            "Observed forwarder listeners match receipt: " +
            "$($forwarderObservation.ListenersMatchReceipt)"
        )
        Write-Host "Observed forwarder process ID: $($forwarderObservation.ProcessId)"
        Write-Host "Observed forwarder detail: $($forwarderObservation.Detail)"
    }
    Write-Host "Forwarder supervisor: $($supervisorObservation.Status)"
    if ($supervisorObservation.Required) {
        Write-Host (
            "Observed supervisor matches receipt: " +
            "$($supervisorObservation.MatchesReceipt)"
        )
        Write-Host (
            "Observed supervisor detail: " +
            "$($supervisorObservation.Detail)"
        )
    }
    $unhealthy = (
        -not $networkTopologyMatchesReceipt -or
        $observation.Status -ne "running" -or
        $observation.Health -ne "healthy" -or
        -not $observation.ImageMatchesReceipt -or
        $forwarderObservation.Status -notin @("ready", "not-required") -or
        $supervisorObservation.Status -notin @("ready", "not-required")
    )
    if ($unhealthy) {
        Write-Warning (
            "Recorded release is not currently observed with its sealed network " +
            "topology, healthy application state, recorded image, and " +
            "receipt-bound forwarder supervision."
        )
    }
    if (Get-Command podman -ErrorAction SilentlyContinue) {
        Invoke-Compose `
            -EnvironmentFile $current.environmentFile `
            -ComposeProject $current.projectName `
            -ComposePath $current.composeSourcePath `
            -Arguments @("ps") `
            -EchoOutput `
            -AllowFailure | Out-Null
    }
    if ($unhealthy) {
        throw "K-Comms local release health check failed"
    }
}

function Invoke-Start {
    Assert-RequiredTools -Commands @("podman", "icacls.exe")
    if (-not (Test-Path -LiteralPath $StateRoot)) {
        throw "No successful K-Comms local release is recorded"
    }
    Ensure-PodmanReady
    Initialize-OwnedStateDirectory -Path $StateRoot -ExpectedProject $ProjectName
    $operationLock = Enter-ReleaseOperationLock -Path $StateRoot -ComposeProject $ProjectName
    try {
        Invoke-StartLocked
    }
    finally {
        Exit-ReleaseOperationLock -Lock $operationLock
    }
}

function Invoke-StartLocked {
    $current = Get-CurrentReceipt
    if (-not $current) {
        throw "No successful K-Comms local release is recorded"
    }
    Assert-ImmutableRestartReceipt -Receipt $current
    $topology = Resolve-ReceiptNetworkTopology -Receipt $current
    if (Test-ReceiptRequiresLanForwarder -Receipt $current) {
        Assert-RequiredTools -Commands @("node")
    }

    $retainedImage = Get-ImageEvidence `
        -ImageReference $current.imageReference `
        -ExpectedRevision $current.revision
    if ($retainedImage.imageId -ne $current.imageId) {
        throw "Retained image tag no longer resolves to the recorded image ID"
    }
    if (
        [string]$current.imageDigest -and
        $retainedImage.imageDigest -ne [string]$current.imageDigest
    ) {
        throw "Retained image digest no longer matches the recorded image digest"
    }
    Unregister-LanForwarderSupervisor `
        -Receipt $current `
        -AllowNotRegistered
    Stop-LanForwarder -Receipt $current -AllowNotRunning

    Assert-CandidatePorts `
        -CandidateBindAddress $topology.BindAddress `
        -CandidateAppPort ([int]$current.ports.app) `
        -CandidateMinioPort ([int]$current.ports.minio) `
        -CandidateMinioConsolePort ([int]$current.ports.minioConsole) `
        -CandidateLiveKitSignalPort ([int]$current.ports.livekitSignal) `
        -CandidateLiveKitTcpPort ([int]$current.ports.livekitTcp) `
        -CandidateLiveKitUdpPort ([int]$current.ports.livekitUdp) `
        -PreviousReceipt $current `
        -ForwarderProfile $(if (
            Test-ReceiptIsCloudflareTrustedEdge -Receipt $current
        ) {
            "media-only"
        } else {
            "full"
        })

    $eventId =
        [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") +
        "-" +
        [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $eventDirectory = Split-Path -Parent $current.receiptPath
    $migrationLogPath = Join-Path $eventDirectory "start-$eventId-migration.log"
    $eventPath = Join-Path $eventDirectory "start-$eventId.json"

    try {
        Assert-GuestRollbackSafe `
            -CurrentReceipt $current `
            -TargetReceipt $current
        $migrationOutput = Restore-Release `
            -Receipt $current `
            -RunMigration `
            -UpdatePointer
        [IO.File]::WriteAllText(
            $migrationLogPath,
            [string]$migrationOutput,
            (New-Object Text.UTF8Encoding($false))
        )
        Write-JsonAtomic -Path $eventPath -Value ([ordered]@{
            startedAt = [DateTime]::UtcNow.ToString("o")
            receiptPath = $current.receiptPath
            revision = $current.revision
            imageReference = $current.imageReference
            imageId = $current.imageId
            publicAppUrl = $topology.PublicAppUrl
            network = New-ReceiptNetworkRecord `
                -Observation $topology `
                -PublicAppUrl $topology.PublicAppUrl
            migration = [ordered]@{
                command = "CommsCore.Release.migrate()"
                direction = "up"
                status = "succeeded"
                logPath = $migrationLogPath
            }
            result = "healthy"
        })
    }
    catch {
        $startError = $_
        try {
            Write-JsonAtomic -Path $eventPath -Value ([ordered]@{
                failedAt = [DateTime]::UtcNow.ToString("o")
                receiptPath = $current.receiptPath
                revision = $current.revision
                imageReference = $current.imageReference
                publicAppUrl = $topology.PublicAppUrl
                network = New-ReceiptNetworkRecord `
                    -Observation $topology `
                    -PublicAppUrl $topology.PublicAppUrl
                message = $startError.Exception.Message
                result = "failed"
            })
        }
        catch {
            Write-Warning "Could not persist the retained-release start failure: $($_.Exception.Message)"
        }
        throw $startError
    }

    Write-Host "Started retained K-Comms revision $($current.revision) without rebuilding source."
    Write-Host "Bind address: $($topology.BindAddress)"
    Write-Host "Public host: $($topology.PublicHost)"
    Write-Host (
        "Network profile: $($topology.NetworkName) " +
        "[$($topology.NetworkCategory)]"
    )
    Write-Host (
        "Public network profile override used: " +
        "$($topology.PublicNetworkProfileOverrideUsed)"
    )
    Write-Host "Application: $($topology.PublicAppUrl)/app/"
    Write-Host "Start receipt: $eventPath"
}

function Invoke-Stop {
    Assert-RequiredTools -Commands @("podman", "icacls.exe")
    if (-not (Test-Path -LiteralPath $StateRoot)) {
        Write-Host "No successful K-Comms local release is recorded."
        return
    }
    Initialize-OwnedStateDirectory -Path $StateRoot -ExpectedProject $ProjectName
    $operationLock = Enter-ReleaseOperationLock -Path $StateRoot -ComposeProject $ProjectName
    try {
        Invoke-StopLocked
    }
    finally {
        Exit-ReleaseOperationLock -Lock $operationLock
    }
}

function Invoke-StopLocked {
    $current = Get-CurrentReceipt
    if (-not $current) {
        Write-Host "No successful K-Comms local release is recorded."
        return
    }
    Assert-RetainedReleaseAssets -Receipt $current
    Unregister-LanForwarderSupervisor `
        -Receipt $current `
        -AllowNotRegistered
    Stop-LanForwarder -Receipt $current -AllowNotRunning
    Ensure-PodmanReady
    Invoke-Compose `
        -EnvironmentFile $current.environmentFile `
        -ComposeProject $current.projectName `
        -ComposePath $current.composeSourcePath `
        -Arguments @("stop", "app", "livekit", "minio", "postgres") `
        -EchoOutput | Out-Null
    Write-Host "Stopped local release containers; retained images, configuration, and data volumes."
}

switch ($Action) {
    "Deploy" { Invoke-Deploy }
    "Start" { Invoke-Start }
    "Rollback" { Invoke-Rollback }
    "Status" { Invoke-Status }
    "Stop" { Invoke-Stop }
    "Validate" { Invoke-Validate }
    "HealthCheck" { Invoke-HealthCheck }
    "Supervise" { Invoke-Supervise }
}

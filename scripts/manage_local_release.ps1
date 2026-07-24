#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet("Deploy", "Start", "Rollback", "Status", "Stop", "Validate")]
    [string]$Action = "Deploy",
    [string]$StateRoot = "",
    [ValidatePattern("^[a-z0-9][a-z0-9_-]*$")]
    [string]$ProjectName = "k-comms-release",
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

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$composeFile = Join-Path $repositoryRoot "deploy\compose.local-release.yaml"
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
        [switch]$AllowFailure
    )

    $composeArguments = @(
        "compose",
        "--project-name", $ComposeProject,
        "--env-file", $EnvironmentFile,
        "-f", $ComposePath
    ) + $Arguments

    Invoke-NativeCommand `
        -FilePath "podman" `
        -Arguments $composeArguments `
        -EchoOutput:$EchoOutput `
        -AllowFailure:$AllowFailure
}

function Assert-LiveKitImageFlags {
    $image = "docker.io/livekit/livekit-server:v1.12.0@sha256:b1281e66e35e8f9749ffbcf0fe6ab4d40d1438aa00f36c2ea7e6975e5e261e2e"
    $help = Invoke-NativeCommand `
        -FilePath "podman" `
        -Arguments @("run", "--rm", $image, "help-verbose")

    foreach ($flag in @("--rtc.enable_loopback_candidate", "--rtc.tcp_port", "--udp-port")) {
        if ($help.Output -notmatch [Regex]::Escape($flag)) {
            throw "Pinned LiveKit image does not support required local-release flag $flag"
        }
    }
}

function Protect-StateDirectory {
    param([Parameter(Mandatory)][string]$Path)

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
        if ($current.Exists) {
            $item = Get-Item -LiteralPath $current.FullName -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw (
                    "A custom local-release state root must not traverse a reparse point " +
                    "or junction: $($current.FullName)"
                )
            }
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

function Read-EnvironmentFile {
    param([Parameter(Mandatory)][string]$Path)

    $values = [ordered]@{}
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }
        $parts = $line.Split(@("="), 2)
        if ($parts.Count -ne 2) {
            throw "Invalid environment line in $Path"
        }
        $value = $parts[1]
        if (
            $value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$parts[0]] = $value.Replace('\"', '"')
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
    Read-JsonFile -Path $pointer.receiptPath
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
        WEBHOOK_SECRET_ENCRYPTION_KEY = New-UrlSafeSecret 48
        PUSH_SUBSCRIPTION_ENCRYPTION_KEY = New-UrlSafeSecret 48
        METRICS_BEARER_TOKEN = New-UrlSafeSecret 36
        WEB_PUSH_VAPID_PUBLIC_KEY = "BIdD6B2jZb5v7fwxbXdnpkOpJrsegpqJbZPPoWb3dI6m5jpkSTB_ZekUrAdKVXR4f_s5nU89TSZlDOxcTHJxAFo"
    }
}

function Get-StableEnvironment {
    $path = Join-Path $StateRoot "environment.env"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-EnvironmentFile -Path $path -Values (New-StableEnvironment)
    }
    Read-EnvironmentFile -Path $path
}

function New-ReleaseEnvironment {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Stable,
        [Parameter(Mandatory)][string]$Revision,
        [Parameter(Mandatory)][string]$ImageReference
    )

    $values = [ordered]@{}
    foreach ($entry in $Stable.GetEnumerator()) {
        $values[$entry.Key] = $entry.Value
    }
    $values["K_COMMS_RELEASE_PROJECT"] = $ProjectName
    $values["K_COMMS_RELEASE_IMAGE"] = $ImageReference
    $values["K_COMMS_RELEASE_REVISION"] = $Revision
    $values["K_COMMS_RELEASE_VERSION"] = "sha-$Revision"
    $values["K_COMMS_RELEASE_APP_PORT"] = "$AppPort"
    $values["K_COMMS_RELEASE_MINIO_PORT"] = "$MinioPort"
    $values["K_COMMS_RELEASE_MINIO_CONSOLE_PORT"] = "$MinioConsolePort"
    $values["K_COMMS_RELEASE_LIVEKIT_SIGNAL_PORT"] = "$LiveKitSignalPort"
    $values["K_COMMS_RELEASE_LIVEKIT_TCP_PORT"] = "$LiveKitTcpPort"
    $values["K_COMMS_RELEASE_LIVEKIT_UDP_PORT"] = "$LiveKitUdpPort"
    $values["POSTGRES_DB"] = "k_comms_release"
    $values["DATABASE_URL"] =
        "ecto://$($Stable.POSTGRES_USER):$($Stable.POSTGRES_PASSWORD)@postgres:5432/k_comms_release"
    $values["PHX_HOST"] = "127.0.0.1"
    $values["PUBLIC_APP_URL"] = "http://127.0.0.1:$AppPort"
    $values["CORS_ORIGINS"] =
        "http://127.0.0.1:$AppPort,http://localhost:$AppPort"
    $values["LIVEKIT_SERVER_URL"] = "ws://127.0.0.1:$LiveKitSignalPort"
    $values["S3_PUBLIC_ENDPOINT"] = "http://127.0.0.1:$MinioPort"
    $values["MINIO_API_CORS_ALLOW_ORIGIN"] =
        "http://127.0.0.1:$AppPort,http://localhost:$AppPort"
    $values["CSP_CONNECT_SOURCES"] =
        "'self' http://127.0.0.1:$AppPort ws://127.0.0.1:$AppPort " +
        "ws://127.0.0.1:$LiveKitSignalPort http://127.0.0.1:$MinioPort"
    $values["S3_BUCKET"] = "k-comms-release"
    $values["ALLOW_BOOTSTRAP"] = "true"
    $values
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
        [Parameter(Mandatory)][int]$ExpectedAppPort,
        [Parameter(Mandatory)][int]$ExpectedMinioPort,
        [Parameter(Mandatory)][int]$ExpectedLiveKitPort
    )

    $baseUri = "http://127.0.0.1:$ExpectedAppPort"
    Wait-HttpEndpoint -Uri "$baseUri/health/ready" -Description "K-Comms readiness"
    Wait-HttpEndpoint -Uri "$baseUri/app/" -Description "packaged K-Comms web client"
    Wait-HttpEndpoint `
        -Uri "http://127.0.0.1:$ExpectedMinioPort/minio/health/ready" `
        -Description "MinIO"
    Wait-HttpEndpoint `
        -Uri "http://127.0.0.1:$ExpectedLiveKitPort/" `
        -Description "LiveKit"

    $status = Invoke-RestMethod -Uri "$baseUri/api/v1/status" -TimeoutSec 10
    if (
        $status.capabilities.audio_calls -ne $true -or
        $status.capabilities.video_calls -ne $true
    ) {
        throw "K-Comms status does not report audio and video calls as available"
    }
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

function Assert-RetainedReleaseAssets {
    param([Parameter(Mandatory)]$Receipt)

    if (-not (Test-Path -LiteralPath $Receipt.environmentFile -PathType Leaf)) {
        throw "Retained release environment is missing: $($Receipt.environmentFile)"
    }
    $environmentHash =
        (Get-FileHash -LiteralPath $Receipt.environmentFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($environmentHash -ne $Receipt.environmentSha256) {
        throw "Retained release environment hash does not match its receipt"
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

    $schemaVersionProperty = $Receipt.PSObject.Properties["schemaVersion"]
    $schemaVersion = if ($schemaVersionProperty) {
        [int]$schemaVersionProperty.Value
    }
    else {
        1
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
}

function Assert-ImmutableRestartReceipt {
    param([Parameter(Mandatory)]$Receipt)

    Assert-RetainedReleaseAssets -Receipt $Receipt
    $schemaVersionProperty = $Receipt.PSObject.Properties["schemaVersion"]
    if (-not $schemaVersionProperty -or [int]$schemaVersionProperty.Value -lt 3) {
        throw (
            "Start requires a schema-v3 immutable-source receipt. " +
            "Deploy the clean committed candidate once before using Start."
        )
    }
}

function Test-LoopbackPortAvailable {
    param(
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
        $socket.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, $Port))
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

    $knownServices = @("app", "migrate", "minio-init", "livekit", "minio", "postgres")
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

    foreach ($line in ($result.Output -split "\r?\n")) {
        $candidate = $line.Trim()
        if ($candidate -match "^127\.0\.0\.1:(?<port>[0-9]+)$") {
            if ([int]$Matches["port"] -eq $ExpectedHostPort) {
                return $true
            }
        }
    }
    $false
}

function Assert-CandidatePorts {
    param(
        [Parameter(Mandatory)][int]$CandidateAppPort,
        [Parameter(Mandatory)][int]$CandidateMinioPort,
        [Parameter(Mandatory)][int]$CandidateMinioConsolePort,
        [Parameter(Mandatory)][int]$CandidateLiveKitSignalPort,
        [Parameter(Mandatory)][int]$CandidateLiveKitTcpPort,
        [Parameter(Mandatory)][int]$CandidateLiveKitUdpPort,
        $PreviousReceipt = $null
    )

    $specifications = @(
        [PSCustomObject]@{
            Name = "application"
            Protocol = "tcp"
            Port = $CandidateAppPort
            Service = "app"
            ReceiptProperty = "app"
            ContainerPort = 4000
        },
        [PSCustomObject]@{
            Name = "MinIO API"
            Protocol = "tcp"
            Port = $CandidateMinioPort
            Service = "minio"
            ReceiptProperty = "minio"
            ContainerPort = 9000
        },
        [PSCustomObject]@{
            Name = "MinIO console"
            Protocol = "tcp"
            Port = $CandidateMinioConsolePort
            Service = "minio"
            ReceiptProperty = "minioConsole"
            ContainerPort = 9001
        },
        [PSCustomObject]@{
            Name = "LiveKit signaling"
            Protocol = "tcp"
            Port = $CandidateLiveKitSignalPort
            Service = "livekit"
            ReceiptProperty = "livekitSignal"
            ContainerPort = 7880
        },
        [PSCustomObject]@{
            Name = "LiveKit media TCP"
            Protocol = "tcp"
            Port = $CandidateLiveKitTcpPort
            Service = "livekit"
            ReceiptProperty = "livekitTcp"
            ContainerPort = $CandidateLiveKitTcpPort
        },
        [PSCustomObject]@{
            Name = "LiveKit media UDP"
            Protocol = "udp"
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
        if (
            $PreviousReceipt -and
            $runningServices -contains $specification.Service
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
                    -ExpectedHostPort $specification.Port)
        }

        if ($ownedByRetainedRelease) {
            continue
        }

        $available = Test-LoopbackPortAvailable `
            -Port $specification.Port `
            -Protocol $specification.Protocol
        if (-not $available) {
            throw (
                "Candidate $($specification.Name) $($specification.Protocol.ToUpperInvariant()) " +
                "port $($specification.Port) is already in use on 127.0.0.1"
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

    $migrationOutput = Start-ReleaseServices `
        -EnvironmentFile $Receipt.environmentFile `
        -ComposeProject $Receipt.projectName `
        -ComposePath $Receipt.composeSourcePath `
        -RunMigration:$RunMigration
    Invoke-Compose `
        -EnvironmentFile $Receipt.environmentFile `
        -ComposeProject $Receipt.projectName `
        -ComposePath $Receipt.composeSourcePath `
        -Arguments @("up", "-d", "--no-build", "--force-recreate", "app") `
        -EchoOutput | Out-Null
    Wait-ContainerHealth `
        -EnvironmentFile $Receipt.environmentFile `
        -ComposeProject $Receipt.projectName `
        -ComposePath $Receipt.composeSourcePath `
        -Service "app"
    Wait-Application `
        -ExpectedAppPort ([int]$Receipt.ports.app) `
        -ExpectedMinioPort ([int]$Receipt.ports.minio) `
        -ExpectedLiveKitPort ([int]$Receipt.ports.livekitSignal)

    if ($UpdatePointer) {
        Write-JsonAtomic -Path $currentPointerPath -Value ([ordered]@{
            receiptPath = $Receipt.receiptPath
            revision = $Receipt.revision
            imageReference = $Receipt.imageReference
            imageId = $Receipt.imageId
            updatedAt = [DateTime]::UtcNow.ToString("o")
        })
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

        $blockedReparseAncestor = $false
        try {
            Assert-NoReparsePointAncestors `
                -Path (Join-Path $junctionPath "nested\state")
        }
        catch {
            $blockedReparseAncestor = $true
        }
        if (-not $blockedReparseAncestor) {
            throw "State-root safety self-test accepted a reparse-point ancestor"
        }

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
        if (Test-LoopbackPortAvailable -Port $occupiedTcpPort -Protocol "tcp") {
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
        if (Test-LoopbackPortAvailable -Port $occupiedUdpPort -Protocol "udp") {
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

function Invoke-Validate {
    Assert-RequiredTools -Commands @("podman", "python", "icacls.exe")
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
            -ImageReference ("localhost/k-comms:sha-" + ("0" * 40))
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
        Invoke-PortPreflightSelfTest
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
        [Parameter(Mandatory)][string]$ComposePath
    )

    $candidateServices = @(
        "app",
        "migrate",
        "minio-init",
        "livekit",
        "minio",
        "postgres"
    )
    $cleanupErrors = [Collections.Generic.List[string]]::new()

    foreach ($service in $candidateServices) {
        $stop = Invoke-Compose `
            -EnvironmentFile $EnvironmentFile `
            -ComposeProject $ComposeProject `
            -ComposePath $ComposePath `
            -Arguments @("stop", $service) `
            -AllowFailure
        if ($stop.ExitCode -ne 0) {
            $cleanupErrors.Add("stop $service failed: $($stop.Output)")
        }

        $remove = Invoke-Compose `
            -EnvironmentFile $EnvironmentFile `
            -ComposeProject $ComposeProject `
            -ComposePath $ComposePath `
            -Arguments @("rm", "--force", $service) `
            -AllowFailure
        if ($remove.ExitCode -ne 0) {
            $cleanupErrors.Add("remove $service failed: $($remove.Output)")
        }
    }

    $remaining = Invoke-Compose `
        -EnvironmentFile $EnvironmentFile `
        -ComposeProject $ComposeProject `
        -ComposePath $ComposePath `
        -Arguments @("ps", "--all", "--quiet") `
        -AllowFailure
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

function Invoke-Deploy {
    Assert-RequiredTools -Commands @("git", "podman", "tar", "icacls.exe")
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

    New-Item -ItemType Directory -Path (Join-Path $StateRoot "history") -Force | Out-Null

    $previousReceipt = Get-CurrentReceipt
    if ($previousReceipt -and $previousReceipt.projectName -ne $ProjectName) {
        throw (
            "The retained release uses Compose project $($previousReceipt.projectName). " +
            "Reuse that project name or select a new -StateRoot for an isolated project."
        )
    }
    Assert-CandidatePorts `
        -CandidateAppPort $AppPort `
        -CandidateMinioPort $MinioPort `
        -CandidateMinioConsolePort $MinioConsolePort `
        -CandidateLiveKitSignalPort $LiveKitSignalPort `
        -CandidateLiveKitTcpPort $LiveKitTcpPort `
        -CandidateLiveKitUdpPort $LiveKitUdpPort `
        -PreviousReceipt $previousReceipt

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
    try {
        $source = New-ImmutableSourceContext `
            -ExpectedRevision $Revision `
            -CandidateDirectory $candidateDirectory
        $snapshotComposePath =
            Join-Path $source.contextPath "deploy\compose.local-release.yaml"
        [IO.File]::Copy($snapshotComposePath, $composeSourcePath, $false)
        $composeSourceSha256 =
            (Get-FileHash -LiteralPath $composeSourcePath -Algorithm SHA256).Hash.ToLowerInvariant()

        $stableEnvironment = Get-StableEnvironment
        $releaseEnvironment = New-ReleaseEnvironment `
            -Stable $stableEnvironment `
            -Revision $Revision `
            -ImageReference $imageReference
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

        $candidateTouchedRuntime = $true
        $migrationOutput = Start-ReleaseServices `
            -EnvironmentFile $environmentFile `
            -ComposeProject $ProjectName `
            -ComposePath $composeSourcePath `
            -RunMigration
        [IO.File]::WriteAllText(
            $migrationLogPath,
            [string]$migrationOutput,
            (New-Object Text.UTF8Encoding($false))
        )
        Invoke-Compose `
            -EnvironmentFile $environmentFile `
            -ComposeProject $ProjectName `
            -ComposePath $composeSourcePath `
            -Arguments @("up", "-d", "--no-build", "--force-recreate", "app") `
            -EchoOutput | Out-Null
        Wait-ContainerHealth `
            -EnvironmentFile $environmentFile `
            -ComposeProject $ProjectName `
            -ComposePath $composeSourcePath `
            -Service "app"
        Wait-Application `
            -ExpectedAppPort $AppPort `
            -ExpectedMinioPort $MinioPort `
            -ExpectedLiveKitPort $LiveKitSignalPort

        $receipt = [ordered]@{
            schemaVersion = 3
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
            migration = [ordered]@{
                command = "CommsCore.Release.migrate()"
                direction = "up"
                status = "succeeded"
                logPath = $migrationLogPath
            }
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
        Write-JsonAtomic -Path $currentPointerPath -Value ([ordered]@{
            receiptPath = $receiptPath
            revision = $Revision
            imageReference = $imageReference
            imageId = $image.imageId
            updatedAt = [DateTime]::UtcNow.ToString("o")
        })
    }
    catch {
        $deploymentError = $_
        try {
            Write-JsonAtomic -Path (Join-Path $candidateDirectory "failure.json") -Value ([ordered]@{
                failedAt = [DateTime]::UtcNow.ToString("o")
                revision = $Revision
                candidateId = $candidateId
                imageReference = $imageReference
                environmentSha256 = $environmentSha256
                composeSourcePath = $composeSourcePath
                composeSourceSha256 = $composeSourceSha256
                sourceArchivePath = if ($source) { $source.archivePath } else { $null }
                sourceArchiveSha256 = if ($source) { $source.archiveSha256 } else { $null }
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

    Write-Host "K-Comms local release is healthy at http://127.0.0.1:$AppPort/app/"
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

function Invoke-RollbackLocked {
    $current = Get-CurrentReceipt
    if (-not $current) {
        throw "No current local release exists"
    }
    if (-not $current.previousReceiptPath) {
        throw "The current local release has no retained predecessor"
    }
    $target = Read-JsonFile -Path $current.previousReceiptPath
    Restore-Release -Receipt $target -UpdatePointer

    $eventPath = Join-Path `
        (Split-Path -Parent $current.receiptPath) `
        ("rollback-" + [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") + ".json")
    Write-JsonAtomic -Path $eventPath -Value ([ordered]@{
        rolledBackAt = [DateTime]::UtcNow.ToString("o")
        fromReceiptPath = $current.receiptPath
        toReceiptPath = $target.receiptPath
        migrationDirection = "none"
        result = "healthy"
    })
    Write-Host "Restored K-Comms revision $($target.revision) without down migrations."
    Write-Host "Application: http://127.0.0.1:$($target.ports.app)/app/"
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

function Invoke-Status {
    $current = Get-CurrentReceipt
    if (-not $current) {
        Write-Host "No successful K-Comms local release is recorded."
        return
    }
    Assert-RetainedReleaseAssets -Receipt $current
    $observation = Get-AppRuntimeObservation -Receipt $current
    Write-Host "Recorded revision: $($current.revision)"
    Write-Host "Recorded image: $($current.imageReference)"
    Write-Host "Recorded image ID: $($current.imageId)"
    Write-Host "Image digest: $($current.imageDigest)"
    Write-Host "Application: http://127.0.0.1:$($current.ports.app)/app/"
    Write-Host "Receipt: $($current.receiptPath)"
    Write-Host "Observed application state: $($observation.Status)"
    Write-Host "Observed application health: $($observation.Health)"
    if ($observation.ImageId) {
        Write-Host "Observed image ID: $($observation.ImageId)"
    }
    Write-Host "Observed image matches receipt: $($observation.ImageMatchesReceipt)"
    if (
        $observation.Status -ne "running" -or
        $observation.Health -ne "healthy" -or
        -not $observation.ImageMatchesReceipt
    ) {
        Write-Warning "Recorded release is not currently observed as healthy on its recorded image."
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

    Assert-CandidatePorts `
        -CandidateAppPort ([int]$current.ports.app) `
        -CandidateMinioPort ([int]$current.ports.minio) `
        -CandidateMinioConsolePort ([int]$current.ports.minioConsole) `
        -CandidateLiveKitSignalPort ([int]$current.ports.livekitSignal) `
        -CandidateLiveKitTcpPort ([int]$current.ports.livekitTcp) `
        -CandidateLiveKitUdpPort ([int]$current.ports.livekitUdp) `
        -PreviousReceipt $current

    $eventId =
        [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") +
        "-" +
        [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $eventDirectory = Split-Path -Parent $current.receiptPath
    $migrationLogPath = Join-Path $eventDirectory "start-$eventId-migration.log"
    $eventPath = Join-Path $eventDirectory "start-$eventId.json"

    try {
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
    Write-Host "Application: http://127.0.0.1:$($current.ports.app)/app/"
    Write-Host "Start receipt: $eventPath"
}

function Invoke-Stop {
    Assert-RequiredTools -Commands @("podman", "icacls.exe")
    if (-not (Test-Path -LiteralPath $StateRoot)) {
        Write-Host "No successful K-Comms local release is recorded."
        return
    }
    Ensure-PodmanReady
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
}

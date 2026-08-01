[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("staging", "production")]
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidatePattern("^192\.168\.1\.[0-9]{1,3}$")]
    [string]$DeployHost,

    [Parameter(Mandatory)]
    [ValidatePattern("^[a-z_][a-z0-9_-]*$")]
    [string]$DeployUser,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$SshKeyPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$KnownHostsPath,

    [Parameter(Mandatory)]
    [ValidatePattern("^ghcr\.io/soyuz-tec/k-comms@sha256:[0-9a-f]{64}$")]
    [string]$Image,

    [Parameter(Mandatory)]
    [ValidatePattern("^[0-9a-f]{40}$")]
    [string]$Revision,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$BundlePath,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$LiveKitCredentialPath,

    [switch]$Bootstrap
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "native-command.ps1")

$scpCommand = Resolve-KCommsNativeCommand -Name "scp"
$sshCommand = Resolve-KCommsNativeCommand -Name "ssh"
$tarCommand = Resolve-KCommsNativeCommand -Name "tar"

$resolvedBundle = (Resolve-Path -LiteralPath $BundlePath).Path
$resolvedKey = (Resolve-Path -LiteralPath $SshKeyPath).Path
$resolvedKnownHosts = (Resolve-Path -LiteralPath $KnownHostsPath).Path
$resolvedLiveKitCredential = if ($LiveKitCredentialPath) {
    (Resolve-Path -LiteralPath $LiveKitCredentialPath).Path
}
else {
    $null
}
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "k-comms-deploy-" + [guid]::NewGuid().ToString("N")
)
$archive = Join-Path $temporaryRoot "k-comms-proxmox.tar.gz"
$remoteArchive = "/tmp/k-comms-proxmox-$Revision.tar.gz"
$remoteDirectory = "/tmp/k-comms-proxmox-$Revision"
$remoteLiveKitCredential = "/tmp/k-comms-livekit-$Revision.json"
$target = "$DeployUser@$DeployHost"

New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    & $tarCommand -C $resolvedBundle -czf $archive .
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the deployment bundle archive"
    }

    & $scpCommand -q -i $resolvedKey -o BatchMode=yes `
        -o StrictHostKeyChecking=yes `
        -o "UserKnownHostsFile=$resolvedKnownHosts" `
        $archive "${target}:$remoteArchive"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload the deployment bundle"
    }

    if ($resolvedLiveKitCredential) {
        & $scpCommand -q -i $resolvedKey -o BatchMode=yes `
            -o StrictHostKeyChecking=yes `
            -o "UserKnownHostsFile=$resolvedKnownHosts" `
            $resolvedLiveKitCredential "${target}:$remoteLiveKitCredential"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to upload the protected LiveKit credential"
        }
    }

    $bootstrapArgument = if ($Bootstrap) { " --bootstrap" } else { "" }
    $liveKitArgument = if ($resolvedLiveKitCredential) {
        " --livekit-credential '$remoteLiveKitCredential'"
    }
    else {
        ""
    }
    $remoteScript = @(
        "set -Eeuo pipefail"
        (
            "cleanup() { rm -f '$remoteArchive' '$remoteLiveKitCredential';" +
            " rm -rf '$remoteDirectory'; }"
        )
        "trap cleanup EXIT"
        "rm -rf '$remoteDirectory'"
        "install -d -m 0755 '$remoteDirectory'"
        "tar -xzf '$remoteArchive' -C '$remoteDirectory'"
        $(if ($resolvedLiveKitCredential) {
            "chmod 0600 '$remoteLiveKitCredential'"
        })
        "sudo bash '$remoteDirectory/bin/sync-assets.sh'"
        (
            "if sudo systemctl is-active --quiet k-comms-app.service; then" +
            " sudo /opt/k-comms/bin/verify.sh" +
            " --environment '$Environment'; fi"
        )
        (
            "sudo /opt/k-comms/bin/deploy.sh" +
            " --environment '$Environment'" +
            " --image '$Image'" +
            " --revision '$Revision'" +
            $bootstrapArgument +
            $liveKitArgument
        )
    ) -join "`n"
    $encodedRemoteScript = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($remoteScript)
    )
    $remoteCommand = "printf '%s' '$encodedRemoteScript' | base64 -d | bash"

    & $sshCommand -i $resolvedKey -o BatchMode=yes `
        -o StrictHostKeyChecking=yes `
        -o "UserKnownHostsFile=$resolvedKnownHosts" `
        $target $remoteCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Remote deployment failed"
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

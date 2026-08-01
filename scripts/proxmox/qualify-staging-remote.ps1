[CmdletBinding()]
param(
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
    [string]$Revision
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "native-command.ps1")

$sshCommand = Resolve-KCommsNativeCommand -Name "ssh"

$resolvedKey = (Resolve-Path -LiteralPath $SshKeyPath).Path
$resolvedKnownHosts = (Resolve-Path -LiteralPath $KnownHostsPath).Path
$remoteScript = @'
set -Eeuo pipefail
sudo /opt/k-comms/bin/qualify-staging.sh \
  --image '@@IMAGE@@' \
  --revision '@@REVISION@@'
'@
$remoteScript = $remoteScript.Replace("@@IMAGE@@", $Image)
$remoteScript = $remoteScript.Replace("@@REVISION@@", $Revision)
$encodedRemoteScript = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($remoteScript)
)
$remoteCommand = "printf '%s' '$encodedRemoteScript' | base64 -d | bash"
$target = "$DeployUser@$DeployHost"

& $sshCommand `
    -i $resolvedKey `
    -o BatchMode=yes `
    -o ServerAliveInterval=15 `
    -o StrictHostKeyChecking=yes `
    -o "UserKnownHostsFile=$resolvedKnownHosts" `
    $target `
    $remoteCommand
if ($LASTEXITCODE -ne 0) {
    throw "Protected staging qualification failed"
}

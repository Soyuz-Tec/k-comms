[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet("192.168.1.23")][string]$DeployHost,
    [Parameter(Mandatory)][ValidatePattern("^[a-z_][a-z0-9_-]*$")][string]$DeployUser,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$SshKeyPath,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$KnownHostsPath,
    [Parameter(Mandatory)][ValidatePattern("^ghcr\.io/soyuz-tec/k-comms@sha256:[0-9a-f]{64}$")][string]$Image,
    [Parameter(Mandatory)][ValidatePattern("^[0-9a-f]{40}$")][string]$Revision
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "native-command.ps1")
. (Join-Path $PSScriptRoot "staging-reboot.ps1")
$sshCommand = Resolve-KCommsNativeCommand -Name "ssh"
$resolvedKey = (Resolve-Path -LiteralPath $SshKeyPath).Path
$resolvedKnownHosts = (Resolve-Path -LiteralPath $KnownHostsPath).Path
$transport = {
    param($action, $requestId, $previousBoot, $timeout)
    $script = "set -Eeuo pipefail`nsudo -n /opt/k-comms/bin/qualify-staging-reboot.sh" +
        " --action '$action' --request-id '$requestId' --image '$Image' --revision '$Revision'"
    if ($previousBoot) { $script += " --previous-boot-id '$previousBoot'" }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
    $arguments = @("-i", $resolvedKey, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
        "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=$resolvedKnownHosts",
        "$DeployUser@$DeployHost", "printf '%s' '$encoded' | base64 -d | bash")
    Invoke-KCommsBoundedNative -Command $sshCommand -Arguments $arguments -TimeoutSeconds $timeout
}.GetNewClosure()
$clock = [Diagnostics.Stopwatch]::StartNew()
$boot = Invoke-KCommsStagingReboot -Transport $transport `
    -ElapsedSeconds { $clock.Elapsed.TotalSeconds } -Pause { param($seconds) Start-Sleep -Seconds $seconds }
Write-Host "Protected staging reboot, readiness, timers and service environments verified."

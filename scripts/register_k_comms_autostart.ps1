#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$TaskName = "K-Comms Podman Auto Start",
    [ValidateRange(0, 300)]
    [int]$DelaySeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "start_local_stack.ps1"
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "K-Comms startup script was not found: $runner"
}

$logPath = Join-Path $env:LOCALAPPDATA "K-Comms\autostart.log"
$powerShell = Join-Path $PSHOME "powershell.exe"
$arguments = @(
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy", "Bypass",
    "-File", ('"{0}"' -f $runner),
    "-ReadyTimeoutSeconds", "300",
    "-LogPath", ('"{0}"' -f $logPath)
) -join " "

$action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$trigger.Delay = "PT${DelaySeconds}S"
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Start Podman and restore the loopback-only K-Comms Compose stack at user logon." `
    -Force | Out-Null

Write-Host "Registered scheduled task: $TaskName"
Write-Host "Startup log: $logPath"

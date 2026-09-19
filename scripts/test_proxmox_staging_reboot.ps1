$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "proxmox/staging-reboot.ps1")

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Rejected([scriptblock]$Action) {
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    Assert-True $rejected "Expected the reboot gate to reject the fixture"
}
$before = "11111111-1111-1111-1111-111111111111"
$after = "22222222-2222-2222-2222-222222222222"

# Exercise reconnects without any native transport or actual sleep.
$state = @{ elapsed = 0; verifies = 0; requests = 0 }
$transport = {
    param($action, $requestId, $previous, $timeout)
    Assert-True ($timeout -gt 0 -and $timeout -le 150) "Transport deadline is unbounded"
    if ($action -eq "request") {
        $state.requests++
        return @{ ExitCode = 0; Output = $before }
    }
    Assert-True ($previous -eq $before) "Previous boot identity was not retained"
    $state.verifies++
    if ($state.verifies -eq 1) { return @{ ExitCode = 255; Output = "" } }
    if ($state.verifies -eq 2) { return @{ ExitCode = 0; Output = $before } }
    return @{ ExitCode = 0; Output = $after }
}
$result = Invoke-KCommsStagingReboot -Transport $transport -ElapsedSeconds { $state.elapsed } `
    -Pause { param($seconds) $state.elapsed += $seconds } -TimeoutSeconds 60
Assert-True ($result -eq $after -and $state.requests -eq 1 -and $state.verifies -eq 3) "Reconnect/boot proof failed"

foreach ($exitCode in @(1, 124, 255)) {
    Assert-Rejected {
        Invoke-KCommsStagingReboot -Transport { param($a, $b, $c, $d) @{ ExitCode = $exitCode; Output = "" } } `
            -ElapsedSeconds { 0 } -Pause { throw "Must not poll a denied request" }
    }
}
Assert-Rejected {
    Invoke-KCommsStagingReboot -Transport { param($a, $b, $c, $d) @{ ExitCode = 0; Output = "not-a-boot-id" } } `
        -ElapsedSeconds { 0 } -Pause { throw "Must not poll a malformed acknowledgment" }
}
$state = @{ elapsed = 0 }
Assert-Rejected {
    Invoke-KCommsStagingReboot -Transport { param($a, $b, $c, $d) @{ ExitCode = 0; Output = $before } } `
        -ElapsedSeconds { $state.elapsed } -Pause { param($seconds) $state.elapsed += $seconds } -TimeoutSeconds 20
}
Assert-True ($state.elapsed -eq 20) "Unchanged boot identity did not stop at the deadline"
$state = @{ elapsed = 0 }
Assert-Rejected {
    Invoke-KCommsStagingReboot -Transport {
        param($action, $b, $c, $d)
        if ($action -eq "request") { return @{ ExitCode = 0; Output = $before } }
        $state.elapsed = 21
        return @{ ExitCode = 0; Output = $after }
    } -ElapsedSeconds { $state.elapsed } -Pause { throw "Late proof must fail" } -TimeoutSeconds 20
}

$key = [IO.Path]::GetTempFileName()
$knownHosts = [IO.Path]::GetTempFileName()
try {
    Assert-Rejected {
        & (Join-Path $PSScriptRoot "proxmox/qualify-staging-reboot-remote.ps1") `
            -DeployHost "192.168.1.22" -DeployUser "fixture" -SshKeyPath $key -KnownHostsPath $knownHosts `
            -Image ("ghcr.io/soyuz-tec/k-comms@sha256:" + "a" * 64) -Revision ("b" * 40)
    }
}
finally {
    Remove-Item -LiteralPath $key, $knownHosts -Force
}

# Native execution uses argument lists (no command string evaluation) and kills
# a stalled child at the configured deadline. The fixture is this same pwsh.
$pwsh = (Get-Process -Id $PID).Path
$native = Invoke-KCommsBoundedNative -Command $pwsh `
    -Arguments @("-NoProfile", "-Command", "[Console]::Write('synthetic-ok'); exit 0") -TimeoutSeconds 10
Assert-True ($native.ExitCode -eq 0 -and $native.Output -eq "synthetic-ok") "Native output contract failed"
$timedOut = Invoke-KCommsBoundedNative -Command $pwsh `
    -Arguments @("-NoProfile", "-Command", "Start-Sleep -Seconds 30") -TimeoutSeconds 1
Assert-True ($timedOut.ExitCode -eq 124 -and $timedOut.Output -eq "") "Native timeout did not fail closed"
Write-Host "Staging reboot transport regression checks passed."

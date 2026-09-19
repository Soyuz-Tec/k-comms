Set-StrictMode -Version Latest

function Invoke-KCommsBoundedNative {
    param([string]$Command, [string[]]$Arguments, [int]$TimeoutSeconds)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Command
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "Unable to start protected SSH transport" }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            return @{ ExitCode = 124; Output = "" }
        }
        # Host/SSH diagnostics can include sensitive details. Never relay them.
        $null = $errors.GetAwaiter().GetResult()
        return @{ ExitCode = $process.ExitCode; Output = $output.GetAwaiter().GetResult().Trim() }
    }
    finally { $process.Dispose() }
}

function Invoke-KCommsStagingReboot {
    param(
        [Parameter(Mandatory)][scriptblock]$Transport,
        [Parameter(Mandatory)][scriptblock]$ElapsedSeconds,
        [Parameter(Mandatory)][scriptblock]$Pause,
        [ValidateRange(1, 900)][int]$TimeoutSeconds = 600
    )
    $requestId = [guid]::NewGuid().ToString()
    $uuid = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    $requested = & $Transport "request" $requestId "" ([Math]::Min(30, $TimeoutSeconds))
    if ($requested.ExitCode -ne 0 -or $requested.Output -cnotmatch $uuid) {
        throw "Protected staging reboot request was denied or not acknowledged"
    }
    $previousBoot = $requested.Output
    while ($true) {
        $remaining = $TimeoutSeconds - [double](& $ElapsedSeconds)
        if ($remaining -lt 1) { throw "Staging reboot recovery exceeded its bounded wait" }
        $result = & $Transport "verify" $requestId $previousBoot ([int][Math]::Min(150, [Math]::Floor($remaining)))
        if ([double](& $ElapsedSeconds) -ge $TimeoutSeconds) {
            throw "Staging reboot recovery exceeded its bounded wait"
        }
        if ($result.ExitCode -eq 0 -and $result.Output -cmatch $uuid -and $result.Output -cne $previousBoot) {
            return $result.Output
        }
        $remaining = $TimeoutSeconds - [double](& $ElapsedSeconds)
        if ($remaining -lt 1) { throw "Staging reboot recovery exceeded its bounded wait" }
        & $Pause ([Math]::Min(10, $remaining))
    }
}

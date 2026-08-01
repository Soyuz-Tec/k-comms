$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "proxmox/native-command.ps1")

foreach ($name in @("scp", "ssh", "tar")) {
    $resolved = Resolve-KCommsNativeCommand -Name $name
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Resolved $name command is not a file: $resolved"
    }
}

$missingRejected = $false
try {
    Resolve-KCommsNativeCommand -Name "kcomms-command-that-must-not-exist"
}
catch {
    $missingRejected = $_.Exception.Message -eq (
        "Required native command is missing: " +
        "kcomms-command-that-must-not-exist"
    )
}
if (-not $missingRejected) {
    throw "Missing native commands must fail closed"
}

Write-Host "Proxmox native command resolution passed on $($PSVersionTable.OS)."

Set-StrictMode -Version Latest

function Resolve-KCommsNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern("^[a-z][a-z0-9-]*$")]
        [string]$Name
    )

    $candidates = if ($IsWindows) {
        @("$Name.exe", $Name)
    }
    else {
        @($Name)
    }

    foreach ($candidate in $candidates) {
        $command = Get-Command $candidate -CommandType Application `
            -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    throw "Required native command is missing: $Name"
}

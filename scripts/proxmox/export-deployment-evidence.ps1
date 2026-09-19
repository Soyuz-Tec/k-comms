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
    [ValidatePattern("^[0-9a-f]{40}$")]
    [string]$Revision,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "native-command.ps1")

$sshCommand = Resolve-KCommsNativeCommand -Name "ssh"

$resolvedKey = (Resolve-Path -LiteralPath $SshKeyPath).Path
$resolvedKnownHosts = (Resolve-Path -LiteralPath $KnownHostsPath).Path
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $resolvedOutput
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Evidence output directory does not exist: $outputDirectory"
}

$remoteScript = @'
set -Eeuo pipefail
environment='@@ENVIRONMENT@@'
revision='@@REVISION@@'
receipt="$(readlink -f /var/lib/k-comms/receipts/current.json)"
test -f "$receipt"
test "$(jq -r '.schema' "$receipt")" = k-comms-deployment-receipt-v1
test "$(jq -r '.environment' "$receipt")" = "$environment"
test "$(jq -r '.revision' "$receipt")" = "$revision"

backup_path="$(jq -r '.backup_path' "$receipt")"
backup_complete=false
backup_manifest_sha256=
if [[ -n "$backup_path" && "$backup_path" != null ]]; then
  backup_path="$(realpath -e "$backup_path")"
  backup_root="$(realpath -e /var/backups/k-comms)"
  [[ "$backup_path" == "${backup_root}/"* ]]
  [[ "$(dirname "$backup_path")" == "$backup_root" ]]
  test "$(<"${backup_path}/COMPLETE")" = k-comms-application-backup-v1
  (cd "$backup_path" && sha256sum --check --strict SHA256SUMS >/dev/null)
  backup_manifest_sha256="$(
    sha256sum "${backup_path}/SHA256SUMS" | cut -d' ' -f1
  )"
  backup_complete=true
fi

qualification=null
reboot=null
if [[ "$environment" == staging ]]; then
  qualification_path="$(
    readlink -f /var/lib/k-comms/receipts/staging-qualification.json
  )"
  test -f "$qualification_path"
  test "$(jq -r '.schema' "$qualification_path")" = \
    k-comms-staging-qualification-receipt-v1
  test "$(jq -r '.revision' "$qualification_path")" = "$revision"
  qualification="$(cat "$qualification_path")"
  reboot_path="$(readlink -f /var/lib/k-comms/receipts/staging-reboot.json)"
  test -f "$reboot_path"
  jq -e --arg revision "$revision" --arg image "$(jq -r '.image' "$receipt")" '
    .schema == "k-comms-staging-reboot-receipt-v1" and .environment == "staging" and
    .revision == $revision and .image == $image and .boot_id != .previous_boot_id and
    .readiness_verified == true and .timers_verified == true and .service_environments_verified == true
  ' "$reboot_path" >/dev/null
  test "$(jq -r '.boot_id' "$reboot_path")" = "$(cat /proc/sys/kernel/random/boot_id)"
  reboot="$(cat "$reboot_path")"
fi

jq -n \
  --arg schema k-comms-workflow-evidence-v1 \
  --arg environment "$environment" \
  --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg receipt_path "$receipt" \
  --slurpfile deployment "$receipt" \
  --arg backup_path "$backup_path" \
  --argjson backup_complete "$backup_complete" \
  --arg backup_manifest_sha256 "$backup_manifest_sha256" \
  --argjson qualification "$qualification" \
  --argjson reboot "$reboot" \
  '{
    schema: $schema,
    environment: $environment,
    captured_at: $captured_at,
    receipt_path: $receipt_path,
    deployment: $deployment[0],
    backup: {
      path: $backup_path,
      complete: $backup_complete,
      manifest_sha256: $backup_manifest_sha256
    },
    staging_qualification: $qualification,
    staging_reboot: $reboot
  }'
'@
$remoteScript = $remoteScript.Replace("@@ENVIRONMENT@@", $Environment)
$remoteScript = $remoteScript.Replace("@@REVISION@@", $Revision)
$encodedRemoteScript = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($remoteScript)
)
$remoteCommand = "printf '%s' '$encodedRemoteScript' | base64 -d | sudo bash"
$target = "$DeployUser@$DeployHost"

$output = & $sshCommand `
    -i $resolvedKey `
    -o BatchMode=yes `
    -o StrictHostKeyChecking=yes `
    -o "UserKnownHostsFile=$resolvedKnownHosts" `
    $target `
    $remoteCommand
if ($LASTEXITCODE -ne 0) {
    throw "Failed to export deployment evidence from $Environment"
}

$json = ($output -join [Environment]::NewLine).Trim()
$document = $json | ConvertFrom-Json
if (
    $document.schema -ne "k-comms-workflow-evidence-v1" -or
    $document.environment -ne $Environment -or
    $document.deployment.revision -ne $Revision -or
    -not $document.backup.complete
) {
    throw "Remote deployment evidence failed local validation"
}
if (
    $Environment -eq "staging" -and
    ($document.staging_qualification.revision -ne $Revision -or
     $document.staging_reboot.revision -ne $Revision -or
     $document.staging_reboot.image -ne $document.deployment.image -or
     $document.staging_reboot.boot_id -eq $document.staging_reboot.previous_boot_id)
) {
    throw "Staging qualification evidence does not match the revision"
}

[IO.File]::WriteAllText(
    $resolvedOutput,
    $json + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
)
Write-Host "Deployment evidence: $resolvedOutput"

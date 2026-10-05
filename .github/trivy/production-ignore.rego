package trivy

# This is a resource- and payload-specific false-positive acceptance, not a
# check-wide KSV-0109 suppression. The named ConfigMap contains durations and
# encryption-key identifiers; runtime key material remains in Kubernetes
# Secrets. Any resource, namespace, or flagged-key change fails closed.
# The Calendar identifier is accepted only with complete scanner source
# evidence of its exact public value; key bytes under that name are refused.
#
# Expiry: 2026-10-31. Remove this policy earlier if Trivy learns to distinguish
# secret material from non-secret configuration identifiers.

default ignore = false

calendar_key_id_lines = lines {
  lines := [line |
    line := input.CauseMetadata.Code.Lines[_]
    regex.match("^\\s*CALENDAR_SECRET_ENCRYPTION_KEY_ID:", line.Content)
  ]
}

ignore {
  input.ID == "KSV-0109"
  input.Namespace == "builtin.kubernetes.KSV0109"
  input.Message == "ConfigMap 'k-comms-config' in 'k-comms-production' namespace stores secrets in key(s) or value(s) '{\"ACCESS_TOKEN_TTL_SECONDS\", \"AUDIO_TOKEN_TTL_SECONDS\", \"CALENDAR_SECRET_ENCRYPTION_KEY_ID\", \"PASSWORD_RECOVERY_JITTER_MS\", \"PASSWORD_RECOVERY_MIN_RESPONSE_MS\", \"PASSWORD_RECOVERY_RETENTION_SECONDS\", \"PASSWORD_RECOVERY_TTL_SECONDS\", \"WEBHOOK_SECRET_ENCRYPTION_KEY_ID\"}'"
  count(calendar_key_id_lines) == 1
  calendar_key_id_lines[0].Truncated == false
  regex.match("^\\s*CALENDAR_SECRET_ENCRYPTION_KEY_ID:\\s*(primary|\"primary\")\\s*$", calendar_key_id_lines[0].Content)
  time.now_ns() < time.parse_rfc3339_ns("2026-10-31T00:00:00Z")
}

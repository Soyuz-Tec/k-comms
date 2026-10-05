package trivy

# Run with OPA's Trivy-compatible parser:
# opa test --v0-compatible .github/trivy/production-ignore*.rego

policy_test_now = 1791158400000000000

policy_test_input = {
  "ID": "KSV-0109",
  "Namespace": "builtin.kubernetes.KSV0109",
  "Message": "ConfigMap 'k-comms-config' in 'k-comms-production' namespace stores secrets in key(s) or value(s) '{\"ACCESS_TOKEN_TTL_SECONDS\", \"AUDIO_TOKEN_TTL_SECONDS\", \"CALENDAR_SECRET_ENCRYPTION_KEY_ID\", \"PASSWORD_RECOVERY_JITTER_MS\", \"PASSWORD_RECOVERY_MIN_RESPONSE_MS\", \"PASSWORD_RECOVERY_RETENTION_SECONDS\", \"PASSWORD_RECOVERY_TTL_SECONDS\", \"WEBHOOK_SECRET_ENCRYPTION_KEY_ID\"}'",
  "CauseMetadata": {"Code": {"Lines": [
    {"Content": "  CALENDAR_SECRET_ENCRYPTION_KEY_ID: primary", "Truncated": false}
  ]}}
}

test_exact_current_public_identifier {
  ignore with input as policy_test_input with time.now_ns as policy_test_now
}

test_quoted_public_identifier {
  value := object.union(policy_test_input, {"CauseMetadata": {"Code": {"Lines": [
    {"Content": "  CALENDAR_SECRET_ENCRYPTION_KEY_ID: \"primary\"", "Truncated": false}
  ]}}})
  ignore with input as value with time.now_ns as policy_test_now
}

test_wrong_resource_name {
  value := object.union(policy_test_input, {"Message": replace(policy_test_input.Message, "'k-comms-config'", "'another-config'")})
  not ignore with input as value with time.now_ns as policy_test_now
}

test_wrong_resource_namespace {
  value := object.union(policy_test_input, {"Message": replace(policy_test_input.Message, "'k-comms-production'", "'k-comms-staging'")})
  not ignore with input as value with time.now_ns as policy_test_now
}

test_wrong_policy_namespace {
  value := object.union(policy_test_input, {"Namespace": "unrelated.KSV0109"})
  not ignore with input as value with time.now_ns as policy_test_now
}

test_wrong_check {
  value := object.union(policy_test_input, {"ID": "KSV-0110"})
  not ignore with input as value with time.now_ns as policy_test_now
}

test_added_secret_material_key {
  value := object.union(policy_test_input, {"Message": replace(policy_test_input.Message, "\"CALENDAR_SECRET_ENCRYPTION_KEY_ID\"", "\"CALENDAR_SECRET_ENCRYPTION_KEY\", \"CALENDAR_SECRET_ENCRYPTION_KEY_ID\"")})
  not ignore with input as value with time.now_ns as policy_test_now
}

test_secret_material_in_identifier_value {
  value := object.union(policy_test_input, {"CauseMetadata": {"Code": {"Lines": [
    {"Content": "  CALENDAR_SECRET_ENCRYPTION_KEY_ID: c3ludGhldGljLWtleS1tYXRlcmlhbA==", "Truncated": false}
  ]}}})
  not ignore with input as value with time.now_ns as policy_test_now
}

test_other_public_identifier {
  value := object.union(policy_test_input, {"CauseMetadata": {"Code": {"Lines": [
    {"Content": "  CALENDAR_SECRET_ENCRYPTION_KEY_ID: another", "Truncated": false}
  ]}}})
  not ignore with input as value with time.now_ns as policy_test_now
}

test_missing_source_evidence {
  value := object.remove(policy_test_input, ["CauseMetadata"])
  not ignore with input as value with time.now_ns as policy_test_now
}

test_missing_identifier_source_line {
  value := object.union(policy_test_input, {"CauseMetadata": {"Code": {"Lines": []}}})
  not ignore with input as value with time.now_ns as policy_test_now
}

test_truncated_identifier_source {
  value := object.union(policy_test_input, {"CauseMetadata": {"Code": {"Lines": [
    {"Content": "  CALENDAR_SECRET_ENCRYPTION_KEY_ID: primary", "Truncated": true}
  ]}}})
  not ignore with input as value with time.now_ns as policy_test_now
}

test_missing_truncation_evidence {
  value := object.union(policy_test_input, {"CauseMetadata": {"Code": {"Lines": [
    {"Content": "  CALENDAR_SECRET_ENCRYPTION_KEY_ID: primary"}
  ]}}})
  not ignore with input as value with time.now_ns as policy_test_now
}

test_duplicate_identifier_source {
  value := object.union(policy_test_input, {"CauseMetadata": {"Code": {"Lines": [
    {"Content": "  CALENDAR_SECRET_ENCRYPTION_KEY_ID: primary", "Truncated": false},
    {"Content": "  CALENDAR_SECRET_ENCRYPTION_KEY_ID: c3ludGhldGlj", "Truncated": false}
  ]}}})
  not ignore with input as value with time.now_ns as policy_test_now
}

test_expired_exception {
  not ignore with input as policy_test_input with time.now_ns as 1793404800000000000
}

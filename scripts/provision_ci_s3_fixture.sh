#!/bin/sh
# Run unchanged with either the pinned mc image or the verified native build.
set -eu
umask 077

mc alias set local "$S3_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc mb --ignore-existing "local/$S3_BUCKET" >/dev/null
mc version enable "local/$S3_BUCKET" >/dev/null
version_info=$(mc version info "local/$S3_BUCKET")
case "$version_info" in
  *"versioning is enabled"*) ;;
  *) echo 'Bucket versioning was not enabled.' >&2; exit 1 ;;
esac

mc encrypt set sse-s3 "local/$S3_BUCKET" >/dev/null
encrypt_info=$(mc encrypt info "local/$S3_BUCKET")
case "$encrypt_info" in
  *sse-s3*) ;;
  *) echo 'Bucket default SSE-S3 encryption was not enabled.' >&2; exit 1 ;;
esac

policy_file=$(mktemp)
trap 'rm -f "$policy_file"' EXIT HUP INT TERM
cat > "$policy_file" <<EOF
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow",
   "Action":["s3:ListBucket","s3:ListBucketVersions","s3:GetBucketLocation"],
   "Resource":["arn:aws:s3:::$S3_BUCKET"]},
  {"Effect":"Allow",
   "Action":["s3:PutObject","s3:GetObject","s3:GetObjectVersion",
             "s3:DeleteObject","s3:DeleteObjectVersion"],
   "Resource":["arn:aws:s3:::$S3_BUCKET/*"]}]}
EOF
mc admin user add local "$S3_APP_ACCESS_KEY_ID" "$S3_APP_SECRET_ACCESS_KEY" >/dev/null
mc admin policy create local kcomms-app "$policy_file" >/dev/null
mc admin policy attach local kcomms-app --user "$S3_APP_ACCESS_KEY_ID" >/dev/null
entities=$(mc admin policy entities local --user "$S3_APP_ACCESS_KEY_ID")
case "$entities" in
  *kcomms-app*) ;;
  *) echo 'Application user is not bound to the bucket-scoped policy.' >&2; exit 1 ;;
esac
echo 'S3 fixture: versioning, SSE-S3 and bucket-scoped application identity verified.'

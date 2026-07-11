#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

parts=(.bootstrap/part-*.b64)
if (( ${#parts[@]} == 0 )); then
  echo 'No bootstrap archive parts found.' >&2
  exit 1
fi

echo "Bootstrap parts: ${#parts[@]}"
for part in "${parts[@]}"; do
  echo "  $part: $(wc -c < "$part") bytes"
done

payload=/tmp/k-comms.payload
combined_error=/tmp/k-comms-base64-error

if cat "${parts[@]}" | tr -d '\r\n' | base64 --decode > "$payload" 2>"$combined_error"; then
  echo 'Decode mode: combined Base64 stream'
else
  echo "Combined stream failed: $(tr '\n' ' ' < "$combined_error")"
  : > "$payload"
  for part in "${parts[@]}"; do
    echo "Decoding independent part: $part"
    base64 --decode "$part" >> "$payload"
  done
  echo 'Decode mode: independently encoded parts'
fi

echo "Decoded payload bytes: $(wc -c < "$payload")"
echo "Decoded payload SHA-256: $(sha256sum "$payload" | cut -d' ' -f1)"
file "$payload"
xxd -l 16 "$payload"

# Some recovery payloads were encoded twice. Decode one additional layer when
# the first result is plainly Base64 text rather than an archive.
if file -b "$payload" | grep -Eqi 'ASCII text|Unicode text'; then
  if tr -d '\r\n' < "$payload" | grep -Eq '^[A-Za-z0-9+/=]+$'; then
    echo 'Detected a second Base64 layer; decoding it.'
    base64 --decode "$payload" > /tmp/k-comms.payload.inner
    mv /tmp/k-comms.payload.inner "$payload"
    echo "Inner payload bytes: $(wc -c < "$payload")"
    file "$payload"
    xxd -l 16 "$payload"
  fi
fi

unpacked=/tmp/k-comms-unpacked
rm -rf "$unpacked"
mkdir -p "$unpacked"

if tar -tzf "$payload" > /tmp/archive-list 2>/tmp/tar-error; then
  archive_type='gzip tar'
  extractor=(tar -xzf "$payload" -C "$unpacked")
elif tar -tf "$payload" > /tmp/archive-list 2>/tmp/tar-error; then
  archive_type='tar'
  extractor=(tar -xf "$payload" -C "$unpacked")
elif unzip -tq "$payload" >/tmp/unzip-output 2>&1; then
  archive_type='zip'
  unzip -Z1 "$payload" > /tmp/archive-list
  extractor=(unzip -q "$payload" -d "$unpacked")
else
  echo 'Unsupported or corrupt bootstrap archive.' >&2
  echo "tar: $(tr '\n' ' ' < /tmp/tar-error)" >&2
  echo "unzip: $(tr '\n' ' ' < /tmp/unzip-output 2>/dev/null || true)" >&2
  exit 1
fi

if grep -Eq '(^/|(^|/)\.\.(/|$))' /tmp/archive-list; then
  echo 'Unsafe path found in bootstrap archive.' >&2
  exit 1
fi

echo "Archive type: $archive_type"
"${extractor[@]}"
echo "Extracted regular files: $(find "$unpacked" -type f | wc -l)"

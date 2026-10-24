#!/usr/bin/env bash
# Keeps trying to create the server, about once a minute, for up to ~5h40m.
# Stops at once on success (created=yes or exists) or on a real error.
set -u
END=$(( $(date +%s) + 20400 ))
n=0
while [ "$(date +%s)" -lt "$END" ]; do
  n=$((n+1))
  echo "--- attempt $n at $(date -u +%H:%M:%S) UTC"
  bash scripts/try_once.sh
  rc=$?
  if [ $rc -ne 0 ]; then echo "result=error" >> "$GITHUB_OUTPUT"; exit 1; fi
  last=$(tail -1 "$GITHUB_OUTPUT" 2>/dev/null || true)
  case "$last" in created=yes|created=exists) echo "result=done" >> "$GITHUB_OUTPUT"; exit 0;; esac
  sleep 45
done
echo "result=again" >> "$GITHUB_OUTPUT"

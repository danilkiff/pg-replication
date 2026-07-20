#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

failed=()
for t in [0-9][0-9]_*.sh; do
  echo
  if ! "./$t"; then
    failed+=("$t")
  fi
done

echo
if (( ${#failed[@]} )); then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "ALL SCENARIOS PASSED"

#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

source colors.sh

failed=()
for t in [0-9][0-9]_*.sh; do
  echo
  if ! "./$t"; then
    failed+=("$t")
  fi
done

echo
if (( ${#failed[@]} > 0 )); then
  echo "${RED}FAILED: ${failed[*]}${RESET}"
  exit 1
fi
echo "${GREEN}ALL SCENARIOS PASSED${RESET}"

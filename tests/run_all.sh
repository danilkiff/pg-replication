#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"

G='' R='' N=''
if [[ -z "${NO_COLOR:-}" && -t 1 ]] && (( $(tput colors 2>/dev/null || echo 0) >= 8 )); then
  G=$'\e[32;01m' R=$'\e[31;01m' N=$'\e[0m'
fi

failed=()
for t in [0-9][0-9]_*.sh; do
  echo
  if ! "./$t"; then
    failed+=("$t")
  fi
done

echo
if (( ${#failed[@]} )); then
  echo "${R}FAILED: ${failed[*]}${N}"
  exit 1
fi
echo "${G}ALL SCENARIOS PASSED${N}"

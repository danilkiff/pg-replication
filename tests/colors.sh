#!/usr/bin/env bash
# Terminal colors, empty when stdout is not a color-capable terminal or
# NO_COLOR is set, so redirected and CI output stays clean. Orange needs 256
# colors and falls back to yellow.

GREEN=''
RED=''
ORANGE=''
RESET=''

if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
  color_count=$(tput colors 2>/dev/null || echo 0)
  if (( color_count >= 8 )); then
    GREEN=$(tput bold; tput setaf 2)
    RED=$(tput bold; tput setaf 1)
    ORANGE=$(tput bold; tput setaf 3)
    RESET=$(tput sgr0)
  fi
  if (( color_count >= 256 )); then
    ORANGE=$(tput bold; tput setaf 208)
  fi
fi

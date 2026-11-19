#!/bin/bash
# ./zebrunner.sh mdm sources zebrunner-farm as a library into zebrunner.sh: no function and no global of zebrunner-farm
# may replace one of zebrunner.sh and of the scripts it sources (patch/*.sh).
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

FARM=roles/common/files/zebrunner-farm
HOST=(zebrunner.sh patch/*.sh)

# names <files...>: the functions (name()) and the globals (NAME= at the start of a line) of the files, one per line
names() {
  grep -ohE '^([a-z_][a-z0-9_]*\(\)|[A-Z_][A-Z0-9_]*=)' "$@" | sed -E 's/(\(\)|=)$//' | sort -u
}

check "no function or global of zebrunner-farm is one of zebrunner.sh and patch/*.sh" "" \
  "$(comm -12 <(names "$FARM") <(names "${HOST[@]}"))"

finish

#!/bin/bash
# Shared helpers of the test scripts: workspace, command stubs, assertions and template rendering.
# A test script sources it first: source "$(dirname "$0")/lib.sh"
# Keep it compatible with the macOS system bash 3.2.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "${WORK}/bin"
FAILED=0
# tput (used by delimiter) needs a terminal type
export TERM=dumb

# check <description> <expected> <actual>
check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected: '$2'"
    echo "       actual:   '$3'"
    FAILED=1
  fi
}

# check_contains <description> <expected part> <text>
check_contains() {
  if [[ "$3" == *"$2"* ]]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       '$2' is missing in:"
    echo "$3" | sed 's/^/         /'
    FAILED=1
  fi
}

# check_not_contains <description> <unexpected part> <text>
check_not_contains() {
  if [[ "$3" != *"$2"* ]]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       '$2' is present in:"
    echo "$3" | sed 's/^/         /'
    FAILED=1
  fi
}

# stub <command> <script body>: creates ${WORK}/bin/<command>, put ${WORK}/bin first in PATH to use it
stub() {
  printf '#!/bin/bash\n%s\n' "$2" > "${WORK}/bin/$1"
  chmod +x "${WORK}/bin/$1"
}

# record_stub <command>: a stub logging its arguments joined by '|' into ${WORK}/calls.log
record_stub() {
  stub "$1" "(IFS='|'; echo \"$1|\$*\") >> '${WORK}/calls.log'"
}

# calls <command>: logged arguments of a recorded command, one call per line
calls() {
  grep "^$1|" "${WORK}/calls.log" 2> /dev/null | cut -d '|' -f 2-
}

reset_calls() {
  : > "${WORK}/calls.log"
}

require_os() {
  if [[ "$(uname)" != "$1" ]]; then
    echo "skip - requires $1"
    exit 0
  fi
}

require_cmd() {
  if ! command -v "$1" > /dev/null 2>&1; then
    echo "skip - requires $1"
    exit 0
  fi
}

# render <template> <destination> [ansible arguments...]: renders a template as the playbooks do
render() {
  local src="$1"
  local dest="$2"
  shift 2
  local output
  output="$(ZEBRUNNER_MCLOUD_AGENT_DIR="$REPO" ansible localhost --connection local --module-name template \
    --args "src=${src} dest=${dest}" "$@" 2>&1)" || {
    echo "$output"
    return 1
  }
}

# render_farm <devices|mac-devices> <destination> [ansible arguments...]: zebrunner-farm with the example settings
render_farm() {
  local role="$1"
  local dest="$2"
  shift 2
  render "${REPO}/roles/${role}/templates/zebrunner-farm" "$dest" \
    --extra-vars "@${REPO}/defaults/main.yml" --extra-vars "@${REPO}/roles/${role}/vars/main.yml.original" "$@"
}

finish() {
  exit "$FAILED"
}

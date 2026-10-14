#!/bin/bash
# The helpers of the mcloud-agent tests, sourced by tests/lib.sh (CONVENTIONS.md): template rendering.
# Keep it compatible with the macOS system bash 3.2.

# tput (used by delimiter) needs a terminal type
export TERM=dumb

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

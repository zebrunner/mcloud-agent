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

# render_farm <devices|mac-devices> <destination> [ansible arguments...]: zebrunner-farm with the example settings and
# devices of the role (config/<role>.yml.original), over the values by default of the role as the playbooks load them
render_farm() {
  local role="$1"
  local dest="$2"
  shift 2
  render "${REPO}/roles/${role}/templates/zebrunner-farm" "$dest" \
    --extra-vars "@${REPO}/defaults/main.yml" --extra-vars "@${REPO}/roles/${role}/defaults/main.yml" \
    --extra-vars "@${REPO}/config/settings.yml.original" --extra-vars "@${REPO}/config/${role}.yml.original" "$@"
}

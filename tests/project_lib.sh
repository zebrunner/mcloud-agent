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
  output="$(ansible localhost --connection local --module-name template --args "src=${src} dest=${dest}" \
    --extra-vars "agent_dir=${REPO}" "$@" 2>&1)" || {
    echo "$output"
    return 1
  }
}

# the zebrunner-farm script of both OS, its settings are the env file of ZEBRUNNER_FARM_ENV; used by the tests sourcing
# this file
# shellcheck disable=SC2034
FARM_SCRIPT="${REPO}/roles/common/files/zebrunner-farm"

# render_farm <devices|mac-devices> <destination> [ansible arguments...]: the settings of zebrunner-farm (the env file)
# of the OS of the role with the example settings and devices of the role (config/<role>.yml.original), over the
# versions and the values by default of the roles as the playbooks load them
render_farm() {
  local role="$1"
  local dest="$2"
  local farm_os=linux
  [[ "$role" == "mac-devices" ]] && farm_os=macos
  shift 2
  render "${REPO}/roles/common/templates/zebrunner-farm.env" "$dest" --extra-vars "common_farm_os=${farm_os}" \
    --extra-vars "@${REPO}/roles/common/defaults/main.yml" --extra-vars "@${REPO}/roles/${role}/defaults/main.yml" \
    --extra-vars "@${REPO}/versions.yml" \
    --extra-vars "@${REPO}/config/settings.yml.original" --extra-vars "@${REPO}/config/${role}.yml.original" "$@"
}

# unwrap: stdin with the text of every callout, status and fix of patch/ui.sh (ASCII, without colors) on one line, the
# way zebrunner.sh wrote them before the wrapping: the checks of the messages do not depend on the wrapping (patch/ui.sh
# wraps at the spaces only, a longer word stays whole); the title of a callout stays on its own line
unwrap() {
  awk '
    mode == "callout" && /^  \| / {
      text = (text == "" ? $0 : text " " substr($0, 5))
      next
    }
    mode == "status" && /^        [^ ]/ || mode == "fix" && /^            [^ ]/ {
      sub(/^ +/, "")
      text = text " " $0
      next
    }
    {
      if (text != "") print text
      text = ""
      mode = ""
      if (/^  \| [A-Z][A-Z-]*$/) {
        print
        mode = "callout"
      } else if (/^   (ok  |info|warn|FAIL) /) {
        text = $0
        mode = "status"
      } else if (/^     `- fix /) {
        text = $0
        mode = "fix"
      } else {
        print
      }
    }
    END { if (text != "") print text }
  '
}

#!/bin/bash
# Renders zebrunner-farm of a role with the example settings, as the playbook does
# Usage: tests/render_farm.sh <devices|mac-devices> <destination file>
set -eu
cd "$(dirname "$0")/.."

role="$1"
dest="$2"

output="$(ZEBRUNNER_MCLOUD_AGENT_DIR="$PWD" ansible localhost --connection local --module-name template \
  --args "src=roles/${role}/templates/zebrunner-farm dest=${dest}" \
  --extra-vars @defaults/main.yml --extra-vars "@roles/${role}/vars/main.yml.original" 2>&1)" || {
  echo "$output"
  exit 1
}

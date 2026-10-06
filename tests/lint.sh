#!/bin/bash
# Static checks: playbooks syntax, shell scripts and rendered zebrunner-farm templates
set -eu
source "$(dirname "$0")/lib.sh"
cd "$REPO"

for playbook in devices.yml mac-devices.yml; do
  ansible-playbook --syntax-check --inventory hosts "$playbook"
done

for role in devices mac-devices; do
  render_farm "$role" "${WORK}/zebrunner-farm-${role}"
done

scripts=(zebrunner.sh patch/*.sh tests/*.sh roles/mac-devices/templates/zebrunner-device-listener "$WORK"/zebrunner-farm-*)
for script in "${scripts[@]}"; do
  bash -n "$script"
done
shellcheck --severity=warning "${scripts[@]}"

echo "lint: ok"

#!/bin/bash
# Static checks: playbooks syntax, shell scripts and rendered zebrunner-farm templates
set -eu
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for playbook in devices.yml mac-devices.yml; do
  ansible-playbook --syntax-check --inventory hosts "$playbook"
done

for role in devices mac-devices; do
  tests/render_farm.sh "$role" "${work}/zebrunner-farm-${role}"
done

scripts=(zebrunner.sh patch/*.sh tests/*.sh roles/mac-devices/templates/zebrunner-device-listener "$work"/zebrunner-farm-*)
for script in "${scripts[@]}"; do
  bash -n "$script"
done
shellcheck --severity=warning "${scripts[@]}"

echo "lint: ok"

#!/bin/bash
# Static checks of the project files; the tools: pip install -r tests/requirements-lint.txt
set -eu
source "$(dirname "$0")/lib.sh"
cd "$REPO"

missing=""
for tool in ansible-playbook shellcheck yamllint; do
  command -v "$tool" > /dev/null 2>&1 || missing="${missing} ${tool}"
done
if [[ -n "$missing" ]]; then
  echo "missing tools:${missing} (pip install -r tests/requirements-lint.txt)"
  exit 1
fi

echo "# yaml"
yamllint --strict .

echo "# ansible playbooks syntax"
for playbook in devices.yml mac-devices.yml; do
  ansible-playbook --syntax-check --inventory hosts "$playbook"
done

echo "# shell scripts and rendered zebrunner-farm templates"
for role in devices mac-devices; do
  render_farm "$role" "${WORK}/zebrunner-farm-${role}"
done
scripts=(zebrunner.sh patch/*.sh tests/*.sh roles/mac-devices/templates/zebrunner-device-listener "$WORK"/zebrunner-farm-*)
for script in "${scripts[@]}"; do
  bash -n "$script"
done
shellcheck --severity=warning "${scripts[@]}"

echo "lint: ok"

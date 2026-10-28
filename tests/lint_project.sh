#!/bin/bash
# shellcheck disable=SC2034
# The settings and the checks of the project for tests/lint.sh (CONVENTIONS.md): mcloud-agent.

scripts=(zebrunner.sh patch/*.sh scripts/*.sh tests/*.sh roles/mac-devices/templates/zebrunner-device-listener)
# shfmt formats the zebrunner-farm templates before rendering, the rendered ones are checked as scripts
sources=("${scripts[@]}" roles/*/templates/zebrunner-farm)
# the local data of a farm
generated=(backup logs DeveloperDiskImages)
dockerfiles=(tests/Dockerfile)
tools=(ansible-lint ansible-playbook ruff)

# project_checks: Python, the playbooks and the rendered zebrunner-farm templates
project_checks() {
  section "python"
  run_check "ruff check" ruff check --no-cache .
  run_check "ruff format" ruff format --check --no-cache .

  section "ansible"
  run_check "ansible-lint" ansible-lint --strict
  for playbook in devices.yml mac-devices.yml; do
    run_check "syntax of ${playbook}" ansible-playbook --syntax-check --inventory hosts "$playbook"
  done

  section "templates"
  # the zebrunner-farm templates are checked as scripts after rendering with the example settings
  for role in devices mac-devices; do
    run_check "render zebrunner-farm of ${role}" render_farm "$role" "${WORK}/zebrunner-farm-${role}"
  done
  scripts+=("$WORK"/zebrunner-farm-*)
}

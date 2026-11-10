#!/bin/bash
# shellcheck disable=SC2034
# The settings and the checks of the project for tests/lint.sh (CONVENTIONS.md): mcloud-agent.

scripts=(zebrunner.sh patch/*.sh scripts/*.sh tests/*.sh roles/mac-devices/templates/zebrunner-device-listener roles/common/files/zebrunner-farm)
# the local data of a farm
generated=(backup logs DeveloperDiskImages)
dockerfiles=(tests/Dockerfile)
tools=(ansible-lint ansible-playbook ruff)

# project_checks: Python, the playbooks and the rendered settings of zebrunner-farm
project_checks() {
  section "python"
  run_check "ruff check" ruff check --no-cache .
  run_check "ruff format" ruff format --check --no-cache .

  section "ansible"
  run_check "ansible-lint" ansible-lint --strict
  for playbook in agent.yml devices.yml mac-devices.yml; do
    run_check "syntax of ${playbook}" ansible-playbook --syntax-check --inventory hosts "$playbook"
  done

  section "templates"
  # the settings of zebrunner-farm (sourced by it) are rendered with the example settings and checked as shell
  for role in devices mac-devices; do
    run_check "render the settings of zebrunner-farm of ${role}" render_farm "$role" "${WORK}/zebrunner-farm-${role}.env"
    run_check "the settings of zebrunner-farm of ${role} are shell" bash -n "${WORK}/zebrunner-farm-${role}.env"
  done
}

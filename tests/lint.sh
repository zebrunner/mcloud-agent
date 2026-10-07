#!/bin/bash
# Static checks of the project files, every linter run is a check (also in JUnit XML with JUNIT_DIR);
# the tools: pip install -r tests/requirements-lint.txt
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

# lint <description> <command...>: runs a linter as a check, its output is shown when it fails
lint() {
  local output
  output="$("${@:2}" 2>&1)"
  local status=$?
  if [[ "$status" -eq 0 ]]; then
    pass "$1"
  else
    fail "$1" "exit status ${status}" "$output"
  fi
}

missing=""
for tool in actionlint ansible-lint ansible-playbook hadolint pymarkdown ruff shellcheck shfmt yamllint; do
  command -v "$tool" > /dev/null 2>&1 || missing="${missing} ${tool}"
done
if [[ -n "$missing" ]]; then
  fail "lint tools are installed" "missing:${missing}" \
    "missing tools:${missing} (pip install -r tests/requirements-lint.txt, hadolint on macOS: brew install hadolint)"
  finish
fi

section "yaml"
lint "yamllint" yamllint --strict .

section "GitHub workflows"
lint "actionlint" actionlint

section "python"
lint "ruff check" ruff check --no-cache .
lint "ruff format" ruff format --check --no-cache .

section "Dockerfile"
lint "hadolint" hadolint tests/Dockerfile

section "markdown"
lint "pymarkdown" pymarkdown scan README.md

section "ansible"
lint "ansible-lint" ansible-lint --strict
for playbook in devices.yml mac-devices.yml; do
  lint "syntax of ${playbook}" ansible-playbook --syntax-check --inventory hosts "$playbook"
done

section "shell"
for role in devices mac-devices; do
  lint "render zebrunner-farm of ${role}" render_farm "$role" "${WORK}/zebrunner-farm-${role}"
done
scripts=(zebrunner.sh patch/*.sh tests/*.sh roles/mac-devices/templates/zebrunner-device-listener "$WORK"/zebrunner-farm-*)
for script in "${scripts[@]}"; do
  lint "bash -n ${script#"${WORK}/"}" bash -n "$script"
done
lint "shellcheck" shellcheck --severity=warning "${scripts[@]}"
# style of .editorconfig
lint "shfmt" shfmt -d zebrunner.sh patch/*.sh tests/*.sh roles/mac-devices/templates/zebrunner-device-listener roles/*/templates/zebrunner-farm

[[ "$FAILED" -eq 0 ]] && echo "lint: ok"
finish

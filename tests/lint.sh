#!/bin/bash
# Static checks of the project files, every linter run is a check (also in JUnit XML with JUNIT_DIR);
# the tools: pip install -r tests/requirements-lint.txt (hadolint on macOS: brew install hadolint)
# The shared part is the same in all the repositories, see CONVENTIONS.md.
source "$(dirname "$0")/lib.sh"
cd "$REPO" || exit 1

# the shell scripts of the project
scripts=(zebrunner.sh patch/*.sh tests/*.sh roles/mac-devices/templates/zebrunner-device-listener)
# the sources of shfmt: the zebrunner-farm templates are formatted before rendering
sources=("${scripts[@]}" roles/*/templates/zebrunner-farm)
# the generated files and the local data of a farm: no text file checks
generated=(backup logs DeveloperDiskImages)
# the files indented with tabs
tab_files=(Makefile)

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
run_check "yamllint" yamllint --strict .

section "GitHub workflows"
# the files are listed: actionlint looks for the project by .git otherwise, and the sources may come without it
run_check "actionlint" actionlint .github/workflows/*.yml

section "Dockerfile"
run_check "hadolint" hadolint tests/Dockerfile

section "markdown"
run_check "pymarkdown" pymarkdown scan ./*.md

section "README"
# the license of CONVENTIONS.md: LICENSE and the README section (no image, no label)
check_contains "LICENSE is the Apache License 2.0" "Apache License" "$(head -3 LICENSE 2> /dev/null)"
check_contains "README links LICENSE" "[Apache License 2.0](LICENSE)" "$(cat README.md)"

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

section "shell"
for script in "${scripts[@]}"; do
  run_check "bash -n ${script#"${WORK}/"}" bash -n "$script"
done
run_check "shellcheck" shellcheck --severity=info "${scripts[@]}"
# style of .editorconfig
run_check "shfmt" shfmt -d "${sources[@]}"
# the rules of CONVENTIONS.md that shfmt and shellcheck do not check, the comment lines are skipped
check "tests use [[ ]] only" "" \
  "$(grep -nE '(^|[[:space:];&|(!])\[[[:space:]]' "${scripts[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
check "functions are defined without the function keyword" "" \
  "$(grep -nE '^[[:space:]]*function[[:space:]]' "${scripts[@]}")"

section "text files"
# every text file of the project but the generated ones
prune=(-name .git -o -name .venv -o -name .idea)
for path in "${generated[@]}"; do
  prune+=(-o -path "./${path}")
done
text_files=()
while IFS= read -r file; do
  grep -Iq '' "$file" 2> /dev/null && text_files+=("$file")
done < <(find . \( "${prune[@]}" \) -prune -o -type f -print | sort)
check "ASCII characters only" "" "$(LC_ALL=C grep -n '[^[:print:][:space:]]' "${text_files[@]}")"
check "LF line ends" "" "$(grep -l $'\r' "${text_files[@]}")"
check "no trailing whitespace" "" "$(grep -nE '[[:blank:]]+$' "${text_files[@]}")"
check "a final newline" "" "$(for file in "${text_files[@]}"; do [[ -z "$(tail -c 1 "$file")" ]] || echo "$file"; done)"
tabbed="$(grep -l $'\t' "${text_files[@]}")"
for file in "${tab_files[@]}"; do
  tabbed="$(grep -vxF "./${file}" <<< "$tabbed")"
done
check "tabs only in ${tab_files[*]}" "" "$tabbed"

[[ "$FAILED" -eq 0 ]] && echo "lint: ok"
finish

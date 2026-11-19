#!/bin/bash
# The helpers of the host scripts; the messages need the functions of patch/ui.sh, sourced after this file

# the colors of failed, warn and succeed
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# random_string [length]: a random string of letters and digits, 48 characters by default
random_string() {
  local length=48
  if [[ -n "$1" && $1 =~ ^[0-9]+$ ]]; then
    length="$1"
  fi
  local result=""
  # Finite chunks of /dev/urandom: with SIGPIPE ignored (e.g. under CI runners) `tr < /dev/urandom | head`
  # never ends. LC_ALL as it overrides a UTF-8 LC_ALL, which makes tr fail on random bytes.
  while [[ ${#result} -lt $length ]]; do
    result+="$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9')"
  done
  echo "${result:0:$length}"
}

# echo_warning <message>: the message as a warning callout for the person at the terminal
echo_warning() {
  ui_callout warn "$1"
}

# echo_telegram: where to get help, after an empty line
echo_telegram() {
  echo ""
  ui_muted "For more help join telegram channel: https://t.me/zebrunner"
}

# print_section <title> [detail]: the title of a section of the output, the detail (e.g. the folder) muted under it
print_section() {
  ui_section "$1"
  if [[ -n "${2:-}" ]]; then
    ui_muted "$2"
    echo ""
  fi
}

# wrap_words <text> <width>: the text wrapped at the spaces to the width, one line per line; a longer word (e.g. a path)
# stays whole on its own line, so it can be copied
wrap_words() {
  printf '%s\n' "$1" | awk -v width="$2" '{
    line = ""
    for (i = 1; i <= NF; i++) {
      if (line == "") {
        line = $i
      } else if (length(line) + 1 + length($i) <= width) {
        line = line " " $i
      } else {
        print line
        line = $i
      }
    }
    print line
  }'
}

# print_paragraph <text>: a paragraph wrapped to the width of the terminal output, an empty line after it
print_paragraph() {
  local line
  while IFS= read -r line; do
    printf '  %s\n' "$line"
  done <<< "$(wrap_words "$1" "$UI_WIDTH")"
  echo ""
}

# print_step <number> <text>: a numbered step of a list, the text wrapped under itself, an empty line after it
print_step() {
  local head="   ${UI_ACCENT}${1}.${UI_RESET} "
  local line
  while IFS= read -r line; do
    printf '%s%s\n' "$head" "$line"
    head="      "
  done <<< "$(wrap_words "$2" $((UI_WIDTH - 4)))"
  echo ""
}

# confirm_prompt <question> <default y|n>: the prompt of confirm: the question without the indent of the earlier
# callers and the hint of the default ([Y/n] or [y/N])
confirm_prompt() {
  local question="$1"
  local hint="[y/N]"
  if [[ "$2" == "y" ]]; then
    hint="[Y/n]"
  fi
  question="${question#"${question%%[![:space:]]*}"}"
  ui_prompt "$question" "$hint"
}

# confirm <message> <question> <default y|n>: asks the question until the answer is y or n, Enter is the default; 0 for
# yes
confirm() {
  local message="$1"
  local question="$2"
  local default="$3"
  local response

  while true; do
    if [[ -n $message ]]; then
      ui_info "$message"
    fi

    read -r -p "$(confirm_prompt "$question" "$default")" response
    if [[ -z "$response" ]]; then
      if [[ "$default" == "y" ]]; then
        return 0
      fi
      if [[ "$default" == "n" ]]; then
        return 1
      fi
    fi

    if [[ "$response" == "y" || "$response" == "Y" ]]; then
      return 0
    fi

    if [[ "$response" == "n" || "$response" == "N" ]]; then
      return 1
    fi

    ui_warn "Please answer y (yes) or n (no)."
  done
}

# failed <message>: the message in red; the output of zebrunner-farm and patch/mdm.sh, the other scripts print with
# patch/ui.sh
failed() {
  echo -e "${RED}${1}${NC}"
}

# warn <message>: the message in yellow, see failed
warn() {
  echo -e "${YELLOW}${1}${NC}"
}

# succeed <message>: the message in green, see failed
succeed() {
  echo -e "${GREEN}${1}${NC}"
}

# ask_for_sudo: asks for the password of sudo now (sudo -v), fails without sudo
ask_for_sudo() {
  # Check for sudo permission
  if ! sudo -n true 2> /dev/null; then
    ui_info "You need to have sudo permissions"
  fi

  # Show sudo prompt to be transparent and extend sudo timeout if the user has sudo permissions
  ui_muted "sudo -v    # Extends the sudo timeout for default period"
  if ! sudo -v; then
    ui_fail "Can't proceed without sudo"
    return 1
  fi
}

# yaml_python: a python with PyYAML for patch/settings.py and patch/enroll.py: $ZEBRUNNER_PYTHON, python3 or the python
# of ansible (ansible-core depends on PyYAML; `ansible-playbook --version` shows its path); fails when there is none
yaml_python() {
  local python
  for python in "${ZEBRUNNER_PYTHON:-}" python3; do
    if [[ -n "$python" ]] && "$python" -c 'import yaml' > /dev/null 2>&1; then
      echo "$python"
      return 0
    fi
  done
  python="$(ansible-playbook --version 2> /dev/null | sed -nE 's/^ *python version = .*[[(](\/[^])]*)[])]$/\1/p' | head -n 1)"
  if [[ -n "$python" ]] && "$python" -c 'import yaml' > /dev/null 2>&1; then
    echo "$python"
    return 0
  fi
  return 1
}

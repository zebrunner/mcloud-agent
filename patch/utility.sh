#!/bin/bash

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

# echo_warning <message>: the message as a warning for the person at the terminal
echo_warning() {
  echo "
      WARNING! $1"
}

# echo_telegram: where to get help
echo_telegram() {
  echo "
      For more help join telegram channel: https://t.me/zebrunner
      "
}

# confirm <message> <question> <default y|n>: asks the question until the answer is y or n, Enter is the default; 0 for
# yes
confirm() {
  local message="$1"
  local question="$2"
  local default="$3"

  while true; do
    if [[ -n $message ]]; then
      echo "$message"
    fi

    read -r -p "${question} y/n [${default}]:" response
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

    echo "Please answer y (yes) or n (no)."
    echo
  done
}

# failed <message>: the message in red
failed() {
  echo -e "${RED}${1}${NC}"
}

# warn <message>: the message in yellow
warn() {
  echo -e "${YELLOW}${1}${NC}"
}

# succeed <message>: the message in green
succeed() {
  echo -e "${GREEN}${1}${NC}"
}

# ask_for_sudo: asks for the password of sudo now (sudo -v), fails without sudo
ask_for_sudo() {
  # Check for sudo permission
  if ! sudo -n true 2> /dev/null; then
    echo "You need to have sudo permissions"
  fi

  # Show sudo prompt to be transparent and extend sudo timeout if the user has sudo permissions
  echo "> sudo -v    # Extends the sudo timeout for default period"
  if ! sudo -v; then
    echo_warning "Can't proceed without sudo"
    return 1
  fi
}

# delimiter [character] [text...]: a line of the character ('=' by default) over the width of the terminal, with the text
delimiter() {
  local char="="
  local text=""
  # If the first argument is a single character, use it as the delimiter
  if [[ $# -gt 0 && ${#1} -eq 1 ]]; then
    char="$1"
    shift
  fi
  # Other arguments are the text
  text="$*"

  local width
  width=$(tput cols 2> /dev/null)
  # no terminal (ssh without a tty, CI): the default width
  [[ "$width" =~ ^[0-9]+$ ]] || width=80
  printf "\n"
  if [[ -z "$text" ]]; then
    # Simple delimiter line
    printf '%*s\n' "$width" '' | tr ' ' "$char"
  else
    # Add spaces around the text
    text=" $text "
    local textlen=${#text}
    # How many chars on the left and right
    local left=4
    local right=$((width - textlen - left))
    # Print the line with text
    printf '%*s' "$left" '' | tr ' ' "$char"
    printf '%s' "$text"
    printf '%*s\n' "$right" '' | tr ' ' "$char"
  fi
  printf "\n"
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

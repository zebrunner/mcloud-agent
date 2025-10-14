#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

export_settings() {
  export -p | grep "ZBR" > backup/settings.env
}

random_string() {
  local length=48
  if [[ -n "$1" && $1 =~ ^[0-9]+$ ]]; then
    length="$1"
  fi
  cat /dev/urandom | env LC_CTYPE=C tr -dc a-zA-Z0-9 | head -c "$length"
  echo
}

echo_warning() {
  echo "
      WARNING! $1"
}

echo_telegram() {
  echo "
      For more help join telegram channel: https://t.me/zebrunner
      "
}

replace() {
  #TODO: https://github.com/zebrunner/zebrunner/issues/328 organize debug logging for setup/replace
  file=$1
  #echo "file: $file"
  content=$(< "$file") # read the file's content into
  #echo "content: $content"

  old=$2
  #echo "old: $old"

  new=$3
  #echo "new: $new"
  content=${content//"$old"/$new}

  #echo "content: $content"

  printf '%s' "$content" > "$file" # write new content to disk
}

confirm() {
  local message=$1
  local question=$2
  local default=$3

  while true; do
    if [[ ! -z $message ]]; then
      echo "$message"
    fi

    read -r -p "$question y/n [$default]:" response
    if [[ -z $response ]]; then
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

failed() {
  echo -e "${RED}${1}${NC}"
}

succeed() {
  echo -e "${GREEN}${1}${NC}"
}

ask_for_sudo() {
  # Check for sudo permission
  if ! sudo -n true 2>/dev/null ; then
    echo "You need to have sudo permissions"
  fi

  # Show sudo prompt to be transparent and extend sudo timeout if the user has sudo permissions
  echo "> sudo -v    # Extends the sudo timeout for default period"
  if ! sudo -v ; then
    echo_warning "Can't proceed without sudo"
    return 1
  fi
}

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
  width=$(tput cols)
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
    local right=$(( width - textlen - left ))
    # Print the line with text
    printf '%*s' "$left" '' | tr ' ' "$char"
    printf '%s' "$text"
    printf '%*s\n' "$right" '' | tr ' ' "$char"
  fi
  printf "\n"
}

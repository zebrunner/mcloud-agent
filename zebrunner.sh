#!/bin/bash

# Define Mcloud Agent dir environment variable name
MCLOUD_AGENT_DIR_NAME="ZEBRUNNER_MCLOUD_AGENT_DIR"
MCLOUD_AGENT_DIR_VALUE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${MCLOUD_AGENT_DIR_VALUE}" || exit

# Load utility functions
source "$MCLOUD_AGENT_DIR_VALUE/patch/utility.sh"
# Load backup/restore functions
source "$MCLOUD_AGENT_DIR_VALUE/patch/backup.sh"


setup() {
  delimiter "Setting up MCloud Agent"

  ### Detect MCloud Agent directory and set environment variable
  echo "Detected MCloud Agent directory: $MCLOUD_AGENT_DIR_VALUE"
  # Apply the variable in the current session
  echo "Applying env var '$MCLOUD_AGENT_DIR_NAME=$MCLOUD_AGENT_DIR_VALUE' in the current session"
  export $MCLOUD_AGENT_DIR_NAME="$MCLOUD_AGENT_DIR_VALUE"

  ### Install environment variable to shell profiles
  delimiter "*"
  # Array to hold target files
  TARGET_FILES=()
  echo "Shells found in this system:"
  # Bash
  if command -v bash >/dev/null 2>&1; then
    echo "BASH"
    TARGET_FILES+=("$HOME/.bashrc" "$HOME/.bash_profile")
  fi
  # Zsh
  if command -v zsh >/dev/null 2>&1; then
    echo "ZSH"
    TARGET_FILES+=("$HOME/.zshrc" "$HOME/.zprofile")
  fi
  # Other
  if [ ${#TARGET_FILES[@]} -eq 0 ]; then
    echo "Other (Except 'BASH' or 'ZSH') shell detected"
    TARGET_FILES+=("$HOME/.profile")
  fi
  # Loop through target files and add or update the environment variable
  delimiter "*"
  echo "Adding '$MCLOUD_AGENT_DIR_NAME=$MCLOUD_AGENT_DIR_VALUE' to:"
  for file in "${TARGET_FILES[@]}"; do
    if [ -f "$file" ] && grep -q "^export $MCLOUD_AGENT_DIR_NAME=" "$file"; then
      echo "$file"
      sed -i.bak "s|^export $MCLOUD_AGENT_DIR_NAME=.*|export $MCLOUD_AGENT_DIR_NAME=$MCLOUD_AGENT_DIR_VALUE|" "$file" && rm -f "$file.bak"
    else
      echo "$file"
      echo "export $MCLOUD_AGENT_DIR_NAME=$MCLOUD_AGENT_DIR_VALUE" >> "$file"
    fi
  done

  ### Create roles/.../vars/main.yml according to OS
  delimiter "*"
  os="$(uname)"
  echo "Current OS: $os"
  echo ""
  echo "Setting up 'roles/.../vars/main.yml' according to OS:"
  if [[ "$os" == "Linux" ]]; then
    if [ -f roles/devices/vars/main.yml ]; then
      echo "'roles/devices/vars/main.yml' already exists, making a backup 'roles/devices/vars/main.yml.bak'"
      cp roles/devices/vars/main.yml roles/devices/vars/main.yml.bak
    else
      echo "Creating 'roles/devices/vars/main.yml'"
      cp roles/devices/vars/main.yml.original roles/devices/vars/main.yml
    fi
  elif [[ "$os" == "Darwin" ]]; then
    if [ -f roles/mac-devices/vars/main.yml ]; then
      echo "'roles/mac-devices/vars/main.yml' already exists, making a backup 'roles/mac-devices/vars/main.yml.bak'"
      cp roles/mac-devices/vars/main.yml roles/mac-devices/vars/main.yml.bak
    else
      echo "Creating 'roles/mac-devices/vars/main.yml'"
     cp roles/mac-devices/vars/main.yml.original roles/mac-devices/vars/main.yml
    fi
  else
    echo "Unknown OS. Supported OS are Linux and macOS."
    exit 1
  fi

  ### Shell reload help message
  delimiter "*"
  current_shell="$(basename "$SHELL")"
  echo "Current shell: $current_shell"
  echo ""
  warn "To apply the changes, please restart your terminal session or run the appropriate command below:"
  case "$current_shell" in
    bash)
      if [ -f "$HOME/.bashrc" ]; then
        succeed ">\tsource ~/.bashrc"
      elif [ -f "$HOME/.bash_profile" ]; then
        succeed ">\tsource ~/.bash_profile"
      fi
      ;;
    zsh)
      if [ -f "$HOME/.zshrc" ]; then
        succeed ">\tsource ~/.zshrc"
      elif [ -f "$HOME/.zprofile" ]; then
        succeed ">\tsource ~/.zprofile"
      fi
      ;;
    *)
      if [ -f "$HOME/.profile" ]; then
        succeed ">\tsource ~/.profile"
      fi
      ;;
  esac
  echo ""
  warn ">>> Changes in other shells will be applied automatically <<<"

  ### Final message
  delimiter "*"
  #TODO: switch to master branch after official release and merge
  echo "Follow https://github.com/zebrunner/mcloud-agent/tree/master#run-ansible-playbook to deploy MCloud agent services!"

  delimiter "Setting up MCloud Agent in '$ZEBRUNNER_MCLOUD_AGENT_DIR' finished successfully"
}

ansible() {
  delimiter "Deploying MCloud Agent from '$ZEBRUNNER_MCLOUD_AGENT_DIR'"

  ### Check if the environment variable is set
  if [ -z "$ZEBRUNNER_MCLOUD_AGENT_DIR" ]; then
    echo_warning "Environment variable '$MCLOUD_AGENT_DIR_NAME' is not set."
    echo "Please, run './zebrunner.sh setup' first, or restart your terminal if you've already done so!"
    exit 1
  fi

  ### Check if the operating system is Linux or macOS
  delimiter "*"
  if [[ "$(uname)" == "Linux" ]]; then
    echo "Operating system is Linux"
    file="$ZEBRUNNER_MCLOUD_AGENT_DIR/devices.yml"
  elif [[ "$(uname)" == "Darwin" ]]; then
    echo "Operating system is macOS"
    file="$ZEBRUNNER_MCLOUD_AGENT_DIR/mac-devices.yml"
  else
    echo_warning "This script is not running on a Linux or macOS system. Run ansible manually."
    exit 1
  fi

  ### Make a list of arguments
  delimiter "*"
  if [[ "$1" == "" ]]; then
    arg="$file"
  elif [[ "$1" == "devices" ]]; then
    arg="$file --tag registerDevices"
  else
    arg="$@ $file"
  fi

  ### Run ansible with arguments
  echo_warning "Sudo permissions are required to run this script!"
  echo "ansible-playbook --ask-become-pass -i hosts $arg"
  delimiter "*"
  ansible-playbook --ask-become-pass -i hosts $arg || {
    echo_warning "Ansible playbook execution failed!"
    echo_telegram
    exit 1
  }

  delimiter "Deploying MCloud Agent from '$ZEBRUNNER_MCLOUD_AGENT_DIR' finished successfully"
}

status() {
  delimiter "Status of MCloud Agent components"

  os="$(uname)" 2>/dev/null
  echo "Env var for Mcloud Agent path:    $(env | grep $MCLOUD_AGENT_DIR_NAME 2>/dev/null || failed "$MCLOUD_AGENT_DIR_NAME not set")"
  echo ""
  echo "Current OS:                       $(if [ -n "$os" ]; then echo "$os"; else failed "OS not detected"; fi)"
  echo ""
  echo "Current user:                     $(whoami 2>/dev/null || failed username not detected)"
  echo ""
  echo "Docker version:                   $(docker --version 2>/dev/null || failed "'docker' not found")"
  echo ""
  echo "Docker compose version:           $(docker compose version 2>/dev/null || failed "'docker compose' not found")"
  echo ""
  echo "Ansible-playbook info:            $(ansible-playbook --version 2>/dev/null | head -n 1 || failed "'ansible-playbook' not found")"
  echo ""
  echo "Zebrunner-farm script path:       $(which zebrunner-farm 2>/dev/null || failed "'zebrunner-farm' not found")"
  echo ""
  if [[ "$os" == "Darwin" ]]; then
    echo "Socat tool path:                  $(which socat 2>/dev/null || failed "'socat' not found")"
    echo ""
    echo "Jq tool path:                     $(which jq 2>/dev/null || failed "'jq' not found")"
    echo ""
    echo "Go-ios tool path:                 $(which ios 2>/dev/null || failed "'ios' not found")"
    echo ""
    echo "Deployed launchctl Zebrunner files:"
    ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -i zebrunner || failed "No deployed Zebrunner plist files found"
    echo ""
    echo "Loaded launchctl Zebrunner jobs:"
    launchctl list | grep -i zebrunner || failed "No loaded Zebrunner jobs found"
    echo ""
    echo "roles/mac-devices/vars/main.yml:  $(ls "$ZEBRUNNER_MCLOUD_AGENT_DIR/roles/mac-devices/vars/main.yml" 2>/dev/null || failed "File not found")"
    echo ""
    echo "MacOS ansible-playbook:           $(ls "$ZEBRUNNER_MCLOUD_AGENT_DIR/mac-devices.yml" 2>/dev/null || failed "File not found")"
    echo ""
  else
    echo "roles/devices/vars/main.yml:      $(ls "$ZEBRUNNER_MCLOUD_AGENT_DIR/roles/devices/vars/main.yml" 2>/dev/null || failed "File not found")"
    echo ""
    echo "Linux ansible-playbook:           $(ls "$ZEBRUNNER_MCLOUD_AGENT_DIR/devices.yml" 2>/dev/null || failed "File not found")"
    echo ""
    echo "90_mcloud.rules:                  $(ls /etc/udev/rules.d/90_mcloud.rules 2>/dev/null || failed "File not found")"
    echo ""
  fi
  echo "mcloud-devices.txt path:          $(ls "/usr/local/bin/mcloud-devices.txt" 2>/dev/null || failed "File not found")"
  echo ""
  echo "defaults/main.yml:                $(ls "$ZEBRUNNER_MCLOUD_AGENT_DIR/defaults/main.yml" 2>/dev/null || failed "File not found")"

  delimiter
}

shutdown() {
  delimiter "Shutting down MCloud Agent from '$ZEBRUNNER_MCLOUD_AGENT_DIR'"

  ### Confirm shutdown
  echo_warning "Shutdown will erase all settings and data for '$ZEBRUNNER_MCLOUD_AGENT_DIR' !"
  confirm "" "      Do you want to continue?" "n" || {
    echo "Shutdown cancelled"
    exit 0
  }

  ### Ask for sudo permissions
  echo ""
  ask_for_sudo || {
    echo_warning "Sudo permissions are required to run this script!"
    exit 1
  }

  ### Remove launch agents in case of macOS
  os="$(uname)"
  if [[ "$os" == "Darwin" ]]; then
    delimiter "*"
    echo "Current OS: $os"
    delimiter "*"

    echo "Found Zebrunner launchctl files:"
    ls "$HOME/Library/LaunchAgents" | grep -i zebrunner || echo "No Zebrunner plist files found"

    delimiter "*"
    echo "Found loaded Zebrunner plists:"
    launchctl list | grep -i zebrunner || echo "No loaded Zebrunner plists found"

    delimiter "*"
    echo "Unloading and removing ZebrunnerDevicesListener.plist launchctl file:"
    if [ -f "$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist" ]; then
      if launchctl bootout gui/"$(id -u)" "$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist" 2>/dev/null; then
        echo "ZebrunnerDevicesListener.plist unloaded successfully"
      else
        echo "Failed to unload 'ZebrunnerDevicesListener.plist', it might be not loaded"
      fi
      echo ""
      echo "Removing ZebrunnerDevicesListener.plist file:"
      rm -vf "$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist"
    else
      echo "ZebrunnerDevicesListener.plist file not found"
    fi

    delimiter "*"
    echo "Unloading and removing ZebrunnerUsbmuxd.plist launchctl file:"
    if [ -f "$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" ]; then
      if launchctl bootout gui/"$(id -u)" "$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" 2>/dev/null; then
        echo "ZebrunnerUsbmuxd.plist unloaded successfully"
      else
        echo "Failed to unload 'ZebrunnerUsbmuxd.plist', it might be not loaded"
      fi
      echo ""
      echo "Removing ZebrunnerUsbmuxd.plist file:"
      rm -vf "$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist"
    else
      echo "ZebrunnerUsbmuxd.plist file not found"
    fi
  fi

  ### Remove environment variable from shell profiles
  delimiter "*"
  echo "Removing var 'ZEBRUNNER_MCLOUD_AGENT_DIR' from shell profiles:"
  TARGET_FILES+=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.profile")
  for file in "${TARGET_FILES[@]}"; do
    if [ -f "$file" ] && grep -q "export $MCLOUD_AGENT_DIR_NAME=" "$file"; then
      echo "$file"
      sed -i.bak "/^export $MCLOUD_AGENT_DIR_NAME=.*/d" "$file" && rm -f "$file.bak"
    fi
  done

  ### Stop and remove containers
  delimiter "*"
  echo "Found MCloud Agent containers:"
  docker ps -a --filter "name=device-" --format "{{.Names}}"

  delimiter "*"
  echo "Stopping and removing MCloud Agent containers:"
  if command -v zebrunner-farm >/dev/null 2>&1; then
    zebrunner-farm down
  else
    echo "Can't find 'zebrunner-farm' executable file"
  fi

  delimiter "*"
  echo "Removing volume 'appium-storage-volume':"
  if docker volume ls | grep -q "appium-storage-volume"; then
    docker volume rm appium-storage-volume
  else
    echo "Volume 'appium-storage-volume' not found"
  fi

  ### Remove files
  delimiter "*"
  echo "Removing MCloud Agent files and volumes (sudo privileges required):"
  if [ "$os" == "Darwin" ]; then
    rm -vf roles/mac-devices/vars/main.yml
  else
    rm -vf roles/devices/vars/main.yml
    sudo rm -vf /etc/udev/rules.d/90_mcloud.rules
  fi
  sudo rm -vf /usr/local/bin/zebrunner-farm
  sudo rm -vf /usr/local/bin/mcloud-devices.txt

  ### Final message
  delimiter "*"
  warn ">>> Restart current terminal session to apply all changes <<<"

  delimiter "Shutting down MCloud Agent from '$ZEBRUNNER_MCLOUD_AGENT_DIR' finished"
}

version() {
  delimiter "Zebrunner MCloud Agent components versions for '$ZEBRUNNER_MCLOUD_AGENT_DIR'"
  if [ -z "$ZEBRUNNER_MCLOUD_AGENT_DIR" ]; then
    echo_warning "Environment variable '$MCLOUD_AGENT_DIR_NAME' is not set"
    echo "Please, run './zebrunner.sh setup' first, or restart your terminal if you've already done so!"
    delimiter "*"
    echo "Versions from 'defaults/main.yml' in the current directory:"
    grep -i "version" "defaults/main.yml" | grep -v '^\s*#' || exit 1
  else
    grep -i "version" "$ZEBRUNNER_MCLOUD_AGENT_DIR/defaults/main.yml" | grep -v '^\s*#'
  fi
  delimiter
}

echo_help() {
  delimiter "Zebrunner MCloud Agent help"
  echo "
      Usage: ./zebrunner.sh [option]
      Options:
         setup                Prepare MCloud Agent environment
         ansible ['devices']  Deploy MCloud Agent with custom or predefined args
         status               Status of MCloud Agent deployment
      	 backup               Backup MCloud Agent setup
      	 restore              Restore MCloud Agent setup
      	 shutdown             Stop and remove MCloud Agent containers, clear volumes and environment
      	 version              Version of MCloud Agent components"
  echo_telegram
  delimiter
}

case "$1" in
setup)
  setup
  ;;
ansible)
  ansible "${@:2}"
  ;;
status)
  status $2
  ;;
backup)
  backup
  ;;
restore)
  restore
  ;;
shutdown)
  shutdown
  ;;
version)
  version
  ;;
*)
  echo_help
  ;;
esac

#!/bin/bash

# Load utility functions
source patch/utility.sh
# Load backup/restore functions
source patch/backup.sh

# Detect the root script directory
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${BASEDIR}" || exit

# Define Mcloud dir environment variable name and value
MCLOUD_AGENT_DIR_NAME="ZEBRUNNER_MCLOUD_AGENT_DIR"
MCLOUD_AGENT_DIR_VALUE="$BASEDIR"
# Apply the variable for the current session
export $MCLOUD_AGENT_DIR_NAME="$MCLOUD_AGENT_DIR_VALUE"

setup() {
  echo -e "\n==== Setting up MCloud Agent in '$ZEBRUNNER_MCLOUD_AGENT_DIR' ====\n"

  ### Install environment variable to shell profiles
  # Array to hold target files
  TARGET_FILES=()
  # Bash
  if command -v bash >/dev/null 2>&1; then
    echo "BASH shell found in this system"
    TARGET_FILES+=("$HOME/.bashrc" "$HOME/.bash_profile")
  fi
  # Zsh
  if command -v zsh >/dev/null 2>&1; then
    echo "ZSH shell found in this system"
    TARGET_FILES+=("$HOME/.zshrc" "$HOME/.zprofile")
  fi
  # Other
  if [ ${#TARGET_FILES[@]} -eq 0 ]; then
    echo "Other (Except 'BASH' or 'ZSH') shell detected"
    TARGET_FILES+=("$HOME/.profile")
  fi
  # Loop through target files and add or update the environment variable
  echo -e "\n*******************************************************************\n"
  for file in "${TARGET_FILES[@]}"; do
    if [ -f "$file" ] && grep -q "^export $MCLOUD_AGENT_DIR_NAME=" "$file"; then
      echo "Updating var '$MCLOUD_AGENT_DIR_NAME' in '$file'"
      sed -i.bak "s|^export $MCLOUD_AGENT_DIR_NAME=.*|export $MCLOUD_AGENT_DIR_NAME=$MCLOUD_AGENT_DIR_VALUE|" "$file" && rm -f "$file.bak"
    else
      echo "Adding '$MCLOUD_AGENT_DIR_NAME=$MCLOUD_AGENT_DIR_VALUE' to '$file'"
      echo "export $MCLOUD_AGENT_DIR_NAME=$MCLOUD_AGENT_DIR_VALUE" >> "$file"
    fi
  done
  # Apply the changes to the current shell session
  echo -e "\n*******************************************************************\n"
  current_shell="$(basename "$SHELL")"
  echo "Current shell: $current_shell"
  case "$current_shell" in
    bash)
      if [ -f "$HOME/.bashrc" ]; then
        echo "Sourcing environment from '$HOME/.bashrc'"
        source "$HOME/.bashrc"
      elif [ -f "$HOME/.bash_profile" ]; then
        echo "Sourcing environment from '$HOME/.bash_profile'"
        source "$HOME/.bash_profile"
      fi
      ;;
    zsh)
      if [ -f "$HOME/.zshrc" ]; then
        echo "Sourcing environment from '$HOME/.zshrc'"
        source "$HOME/.zshrc"
      elif [ -f "$HOME/.zprofile" ]; then
        echo "Sourcing environment from '$HOME/.zprofile'"
        source "$HOME/.zprofile"
      fi
      ;;
    *)
      echo "Detected shell '$SHELL', reloading ~/.profile if exists"
      if [ -f "$HOME/.profile" ]; then
        echo "Sourcing environment from '$HOME/.profile'"
        source "$HOME/.profile"
      fi
      ;;
  esac
  echo ">>> Changes in other detected shells will be applied automatically the next time you start the shell <<<"

  ### Create roles/.../vars/main.yml according to OS
  echo -e "\n*******************************************************************\n"
  os="$(uname)"
  echo "Current OS: $os"
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

  ### Final message
  echo -e "\n*******************************************************************\n"
  #TODO: switch to master branch after official release and merge
  echo "Follow https://github.com/zebrunner/mcloud-agent/tree/master#run-ansible-playbook to deploy MCloud agent services!"

  echo -e "\n==== Setting up MCloud Agent in '$ZEBRUNNER_MCLOUD_AGENT_DIR' finished successfully ====\n"
}

ansible() {
  echo -e "\n==== Deploying MCloud Agent from '$ZEBRUNNER_MCLOUD_AGENT_DIR' ====\n"

  ### Check sudo permissions
  if ! sudo -n true 2>/dev/null ; then
    echo "You need to have sudo permissions"
  fi

  echo "> sudo -v    # Extends the sudo timeout for 5-15 minutes"
  if ! sudo -v ; then
    echo_warning "Can't proceed without sudo"
    exit 1
  fi

  ### Check if the operating system is Linux or macOS
  echo -e "\n*******************************************************************\n"
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
  echo -e "\n*******************************************************************\n"
  if [[ "$1" == "" ]]; then
    arg="$file"
  elif [[ "$1" == "devices" ]]; then
    arg="$file --tag registerDevices"
  else
    arg="$@ $file"
  fi

  ### Run ansible with arguments
  echo "ansible-playbook -i hosts $arg"
  echo -e "\n*******************************************************************\n"
  ansible-playbook -i hosts $arg || {
    echo_warning "Ansible playbook execution failed!"
    echo_telegram
    exit 1
  }

  echo -e "\n==== Deploying MCloud Agent from '$ZEBRUNNER_MCLOUD_AGENT_DIR' finished successfully ====\n"
}

status() {
  echo -e "\n==== Status of MCloud Agent components from '$ZEBRUNNER_MCLOUD_AGENT_DIR' ====\n"

  os="$(uname)"
  echo "Env var MCLOUD_AGENT_DIR_NAME:    $ZEBRUNNER_MCLOUD_AGENT_DIR"
  echo "Current OS:                       $os"
  echo "Zebrunner-farm script path:       '$(which zebrunner-farm)'"

  if [[ "$os" == "Darwin" ]]; then
    echo "Deployed launchctl Zebrunner files:"
    ls "$HOME/Library/LaunchAgents" | grep -i zebrunner || echo "No deployed Zebrunner plist files found"
    echo "Loaded launchctl Zebrunner jobs:"
    launchctl list | grep -i zebrunner || echo "No loaded Zebrunner jobs found"
  fi

  echo "mcloud-devices.txt path:          $(ls /usr/local/bin/mcloud-devices.txt)"

  if [ "$os" == "Darwin" ]; then
    echo "roles/../vars/main.yml:           $(ls $ZEBRUNNER_MCLOUD_AGENT_DIR/roles/mac-devices/vars/main.yml)"
  else
    echo "90_mcloud.rules:                  $(ls /etc/udev/rules.d/90_mcloud.rules)"
    echo "roles/../vars/main.yml:           $(ls $ZEBRUNNER_MCLOUD_AGENT_DIR/roles/devices/vars/main.yml)"
  fi

  echo "defaults/main.yml:                $(ls $ZEBRUNNER_MCLOUD_AGENT_DIR/defaults/main.yml)"

  if [ "$os" == "Darwin" ]; then
    echo "MacOS ansible-playbook:           $(ls $ZEBRUNNER_MCLOUD_AGENT_DIR/mac-devices.yml)"
  else
    echo "Linux ansible-playbook:           $(ls $ZEBRUNNER_MCLOUD_AGENT_DIR/devices.yml)"
  fi

  echo -e "\n===================================================================\n"
}

shutdown() {
  echo -e "\n==== Shutting down MCloud Agent from '$ZEBRUNNER_MCLOUD_AGENT_DIR' ====\n"

  ### Confirm shutdown
  echo_warning "Shutdown will erase all settings and data for '$ZEBRUNNER_MCLOUD_AGENT_DIR' !"
  confirm "" "      Do you want to continue?" "n" || {
    echo "Shutdown cancelled"
    exit 0
  }

  ### Remove launch agents in case of macOS
  os="$(uname)"
  if [[ "$os" == "Darwin" ]]; then
    echo -e "\n*******************************************************************\n"
    echo "Operating system is macOS"
    echo ""

    echo "Found Zebrunner launchctl files:"
    ls "$HOME/Library/LaunchAgents" | grep -i zebrunner || echo "No Zebrunner plist files found"
    echo ""

    echo "Found loaded Zebrunner plists:"
    launchctl list | grep -i zebrunner || echo "No loaded Zebrunner plists found"
    echo ""

    if [ -f $HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist ]; then
      launchctl unload $HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist || {
        echo "Failed to unload 'ZebrunnerDevicesListener.plist', it might be not loaded"
      }
      rm -vf $HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist
    fi
    echo ""

    if [ -f $HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist ]; then
      launchctl unload $HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist || {
          echo "Failed to unload 'ZebrunnerUsbmuxd.plist', it might be not loaded"
        }
      rm -vf $HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist
    fi
  fi

  ### Remove environment variable from shell profiles
  echo -e "\n*******************************************************************\n"
  echo "Removing var 'ZEBRUNNER_MCLOUD_AGENT_DIR' from shell profiles:"
  TARGET_FILES+=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.profile")
  for file in "${TARGET_FILES[@]}"; do
    if [ -f "$file" ] && grep -q "export $MCLOUD_AGENT_DIR_NAME=" "$file"; then
      echo "Removing from $file"
      sed -i.bak "/^export $MCLOUD_AGENT_DIR_NAME=.*/d" "$file" && rm -f "$file.bak"
    fi
  done

  ### Stop and remove containers
  echo -e "\n*******************************************************************\n"
  echo "Found MCloud Agent containers:"
  docker ps -a --filter "name=device-" --format "{{.Names}}"
  echo ""

  echo "Stopping and removing MCloud Agent containers:"
  if command -v zebrunner-farm >/dev/null 2>&1; then
    zebrunner-farm down
  else
    echo "Can't find 'zebrunner-farm' executable file"
  fi
  echo ""

  echo "Removing volume 'appium-storage-volume':"
  if docker volume ls | grep -q "appium-storage-volume"; then
    docker volume rm appium-storage-volume
  else
    echo "Volume 'appium-storage-volume' not found"
  fi

  ### Remove files
  echo -e "\n*******************************************************************\n"
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
  echo -e "\n*******************************************************************\n"
  echo "Restart current terminal session or run 'source ~/.bashrc' or 'source ~/.zshrc' to apply changes"

  echo -e "\n==== Shutting down MCloud Agent from '$ZEBRUNNER_MCLOUD_AGENT_DIR' finished ====\n"
}

version() {
  echo -e "\n==== Zebrunner MCloud Agent components versions for '$ZEBRUNNER_MCLOUD_AGENT_DIR' ====\n"
  grep -i "version" defaults/main.yml | grep -v '^\s*#'
  echo -e "\n===================================================================\n"
}

echo_help() {
  echo "
      Usage: ./zebrunner.sh [option]
      Options:
         setup                Prepare MCloud Agent environment
         ansible ['devices']  Deploy MCloud Agent with custom or predefined args
         status               Status of MCloud Agent deployment
         ---------------------------------------------------
      	 backup               Backup MCloud Agent setup
      	 restore              Restore MCloud Agent setup
         ---------------------------------------------------
      	 shutdown             Stop and remove MCloud Agent containers, clear volumes and environment
         ---------------------------------------------------
      	 version              Version of MCloud Agent components"
  echo_telegram
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

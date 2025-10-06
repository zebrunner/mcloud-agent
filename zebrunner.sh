#!/bin/bash

# Detect the root script directory
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${BASEDIR}" || exit
# Define Mcloud dir environment variable name and value
MCLOUD_AGENT_DIR_NAME="ZEBRUNNER_MCLOUD_AGENT_DIR"
MCLOUD_AGENT_DIR_VALUE="$BASEDIR"

## shellcheck disable=SC1091
#source patch/utility.sh

replace() {
  #TODO: https://github.com/zebrunner/zebrunner/issues/328 organize debug logging for setup/replace
  file=$1
  #echo "file: $file"
  content=$(< $file) # read the file's content into
  #echo "content: $content"

  old=$2
  #echo "old: $old"

  new=$3
  #echo "new: $new"
  content=${content//"$old"/$new}

  #echo "content: $content"

  printf '%s' "$content" > $file # write new content to disk
}

setup() {
  ### Install environment variable to shell profiles
  # Array to hold target files
  TARGET_FILES=()
  # Bash
  if command -v bash >/dev/null 2>&1; then
    TARGET_FILES+=("$HOME/.bashrc" "$HOME/.bash_profile")
  fi
  # Zsh
  if command -v zsh >/dev/null 2>&1; then
    TARGET_FILES+=("$HOME/.zshrc" "$HOME/.zprofile")
  fi
  # Other
  if [ ${#TARGET_FILES[@]} -eq 0 ]; then
    TARGET_FILES+=("$HOME/.profile")
  fi
  # Loop through target files and add or update the environment variable
  for file in "${TARGET_FILES[@]}"; do
    if [ -f "$file" ] && grep -q "^export $MCLOUD_AGENT_DIR_NAME=" "$file"; then
      sed -i "s/^export $MCLOUD_AGENT_DIR_NAME=.*/export $MCLOUD_AGENT_DIR_NAME=\"$MCLOUD_AGENT_DIR_VALUE\"/" "$file"
      echo "Updated var $MCLOUD_AGENT_DIR_NAME in $file"
    else
      echo "export $MCLOUD_AGENT_DIR_NAME=\"$MCLOUD_AGENT_DIR_VALUE\"" >> "$file"
      echo "Added $MCLOUD_AGENT_DIR_NAME=\"$MCLOUD_AGENT_DIR_VALUE\" to $file"
    fi
  done
  ### Create roles/.../vars/main.yml according to OS
  os="$(uname)"
  echo "Detected OS: $os"
  if [[ "$os" == "Linux" ]]; then
    if [ -f roles/devices/vars/main.yml ]; then
      echo "roles/devices/vars/main.yml already exists, making a backup roles/devices/vars/main.yml.bak"
      cp roles/devices/vars/main.yml roles/devices/vars/main.yml.bak
    else
      echo "Creating roles/devices/vars/main.yml"
      cp roles/devices/vars/main.yml.original roles/devices/vars/main.yml
    fi
  elif [[ "$os" == "Darwin" ]]; then
    if [ -f roles/mac-devices/vars/main.yml ]; then
      echo "roles/mac-devices/vars/main.yml already exists, making a backup roles/mac-devices/vars/main.yml.bak"
      cp roles/mac-devices/vars/main.yml roles/mac-devices/vars/main.yml.bak
    else
      echo "Creating roles/mac-devices/vars/main.yml"
     cp roles/mac-devices/vars/main.yml.original roles/mac-devices/vars/main.yml
    fi
  else
    echo "Unknown OS. Supported OS are Linux and macOS."
    exit 1
  fi

  #TODO: switch to master branch after oficial release and merge
  echo "Follow https://github.com/zebrunner/mcloud-agent/tree/master#run-ansible-playbook to deploy MCloud agent services!"
}

shutdown() {
  ### Check if services are setup
  if [ ! -f /usr/local/bin/zebrunner-farm ]; then
    echo_warning "You have to setup services in advance using: ./zebrunner.sh setup"
    echo_telegram
    exit 1
  fi

  ### Confirm shutdown
  echo_warning "Shutdown will erase all settings and data for \"${BASEDIR}\"!"
  confirm "" "      Do you want to continue?" "n"
  if [[ $? -eq 0 ]]; then
    exit
  fi

  ### Remove launch agents
  if [ -f $HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist ]; then
    launchctl unload $HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist
    rm -f $HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist
  fi

  if [ -f $HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist ]; then
    launchctl unload $HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist
    rm -f $HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist
  fi

  ### Remove environment variable from shell profiles
  TARGET_FILES+=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.profile")
  for file in "${TARGET_FILES[@]}"; do
    if [ -f "$file" ] && grep -q "export $MCLOUD_AGENT_DIR_NAME=" "$file"; then
      sed -i "/^export $MCLOUD_AGENT_DIR_NAME=.*/d" "$file"
      echo "Removed var $MCLOUD_AGENT_DIR_NAME in $file"
    fi
  done

  ### Stop and remove containers
  down

  ### Remove files and volumes
  sudo rm -f /usr/local/bin/zebrunner-farm
  sudo rm -f /usr/local/bin/mcloud-devices.txt
  sudo rm -f /etc/udev/rules.d/90_mcloud.rules
  # restore original main.yml
  rm -f roles/devices/vars/main.yml
  rm -f roles/mac-devices/vars/main.yml

  docker volume rm appium-storage-volume
}

status() {
  if [[ ! -f /usr/local/bin/zebrunner-farm ]]; then
    echo_warning "MCloud agent is not configured yet! Use: ./zebrunner.sh setup"
    echo_telegram
    exit 1
  fi

  /usr/local/bin/zebrunner-farm status $1
}

start() {
  if [[ ! -f /usr/local/bin/zebrunner-farm ]]; then
    echo_warning "You have to setup services in advance using: ./zebrunner.sh setup"
    echo_telegram
    exit 1
  fi

  /usr/local/bin/zebrunner-farm start $1
}

stop() {
  /usr/local/bin/zebrunner-farm stop $1
}

down() {
  /usr/local/bin/zebrunner-farm down $1
}

backup() {
  confirm "" "      Do you want to do a backup now?" "n"
  if [[ $? -eq 0 ]]; then
    exit
  fi

  # copy udev related files into ./backup folder
  cp /usr/local/bin/zebrunner-farm backup/
  cp /usr/local/bin/mcloud-devices.txt backup/
  cp /etc/udev/rules.d/90_mcloud.rules backup/
  cp roles/devices/vars/main.yml roles/devices/vars/main.yml.bak
  cp roles/mac-devices/vars/main.yml roles/mac-devices/vars/main.yml.bak

  if [ -f backup/zebrunner-farm ] && [ -f backup/mcloud-devices.txt ] && [ -f backup/90_mcloud.rules ] && [ -f roles/devices/vars/main.yml.bak ] && [ -f roles/mac-devices/vars/main.yml.bak ]; then
    echo "MCloud backup succeed."
  else
    echo_warning "MCloud backup failed!"
    echo_telegram
  fi
}

restore() {
  confirm "" "      Your services will be stopped and current data might be lost. Do you want to do a restore now?" "n"
  if [[ $? -eq 0 ]]; then
    exit
  fi

  sudo cp backup/zebrunner-farm /usr/local/bin/zebrunner-farm
  sudo cp backup/mcloud-devices.txt /usr/local/bin/mcloud-devices.txt
  sudo cp backup/90_mcloud.rules /etc/udev/rules.d/90_mcloud.rules
  cp roles/devices/vars/main.yml.bak roles/devices/vars/main.yml
  cp roles/mac-devices/vars/main.yml.bak roles/mac-devices/vars/main.yml

  # reload udevadm rules
  sudo udevadm control --reload-rules

  if [ -f /usr/local/bin/zebrunner-farm ] && [ -f /usr/local/bin/mcloud-devices.txt ] && [ -f /etc/udev/rules.d/90_mcloud.rules ] && [ -f roles/devices/vars/main.yml ] && [ -f roles/mac-devices/vars/main.yml ]; then
    echo "MCloud restore succeed."
  else
    echo_warning "MCloud restore failed!"
    echo_telegram
  fi

  down

  echo_warning "Your services needs to be started after restore."
  confirm "" "      Start now?" "y"
  if [[ $? -eq 1 ]]; then
    start
  fi
}

confirm() {
  local message=$1
  local question=$2
  local isEnabled=$3

  if [[ "$isEnabled" == "1" ]]; then
    isEnabled="y"
  fi
  if [[ "$isEnabled" == "0" ]]; then
    isEnabled="n"
  fi

  while true; do
    if [[ ! -z $message ]]; then
      echo "$message"
    fi

    read -r -p "$question y/n [$isEnabled]:" response
    if [[ -z $response ]]; then
      if [[ "$isEnabled" == "y" ]]; then
        return 1
      fi
      if [[ "$isEnabled" == "n" ]]; then
        return 0
      fi
    fi

    if [[ "$response" == "y" || "$response" == "Y" ]]; then
      return 1
    fi

    if [[ "$response" == "n" || "$response" == "N" ]]; then
      return 0
    fi

    echo "Please answer y (yes) or n (no)."
    echo
  done
}

version() {
  echo "Zebrunner MCloud Agent"
  device_version=$(cat defaults/main.yml | grep DEVICE_VERSION | cut -d ":" -f 2)
  echo "zebrunner/mcloud-device:${device_version}"
  appium_version=$(cat defaults/main.yml | grep APPIUM_VERSION | cut -d ":" -f 2)
  echo "public.ecr.aws/zebrunner/appium:${appium_version}"
}

# IMPORTANT! In case of any changes please copy them in both zebrunner-farm files!
ansible() {

  echo -e "\n*******************************************************************\n"

  if ! sudo -n true 2>/dev/null ; then
    echo "You need to have sudo permissions"
  fi

  echo "> sudo -v    # Extends the sudo timeout"
  if ! sudo -v ; then
    echo "You need to have sudo permissions"
    exit 1
  fi

  echo -e "\n*******************************************************************\n"

  # Check if the operating system is Linux or macOS
  if [[ "$(uname)" == "Linux" ]]; then
    echo "Operating system is Linux"
    file="$MCLOUD_AGENT_DIR_NAME/devices.yml"
  elif [[ "$(uname)" == "Darwin" ]]; then
    echo "Operating system is macOS"
    file="$MCLOUD_AGENT_DIR_NAME/mac-devices.yml"
  else
    echo "This script is not running on a Linux or macOS system. Run ansible manually."
    exit 1
  fi

  echo -e "\n*******************************************************************\n"

  # Make a list of arguments
  if [[ "$1" == "" ]]; then
    arg="$file"
  elif [[ "$1" == "devices" ]]; then
    arg="$file --tag registerDevices"
  else
    arg="$@ $file"
  fi

  # Run ansible with arguments
  echo "ansible-playbook -i hosts $arg"
  echo -e "\n*******************************************************************\n"
  ansible-playbook -i hosts $arg
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

echo_help() {
  echo "
      Usage: ./zebrunner.sh [option]
      Arguments:
         status [udid]        Status of MCloud Agent whitelisted devices or exact device by udid
         start [udid]         Start devices containers or exact device by udid
         stop [udid]          Stop and keep devices containers or exact device by udid
         restart [udid]       Restart all devices containers or exact device by udid
         down [udid]          Stop and remove devices containers
         ansible ['devices']  Run ansible-playbook script with custom or predefined args
      	 shutdown             Stop and remove devices containers, clear volumes
      	 backup               Backup MCloud agent setup
      	 restore              Restore MCloud agent setup
      	 version              Version of MCloud"
  echo_telegram
  exit 0
}

case "$1" in
status)
  status $2
  ;;
setup)
  setup
  ;;
start)
  start $2
  ;;
stop)
  stop $2
  ;;
restart)
  down $2
  start $2
  ;;
down)
  down $2
  ;;
ansible)
  ansible "${@:2}"
  ;;
shutdown)
  shutdown
  ;;
backup)
  backup
  ;;
restore)
  restore
  ;;
version)
  version
  ;;
--help | -h)
  echo_help
  ;;
*)
  echo_help
  exit 1
  ;;
esac

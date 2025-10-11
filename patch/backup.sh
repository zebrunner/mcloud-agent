#!/bin/bash

backup() {
  echo -e "\n==== Backup MCloud Agent in '$ZEBRUNNER_MCLOUD_AGENT_DIR' ====\n"

  confirm "" "      Do you want to do a backup now?" "n" || exit 0

  os="$(uname)" 2>/dev/null
  required=( \
  "backup/defaults/main.yml" \
  "backup/templates/zebrunner-farm" \
  "backup/templates/mcloud-devices.txt" \
  "backup/vars/main.yml" )

  echo "Backing up MCloud Agent related files:"

  if [ ! -d "backup/defaults" ]; then
    echo "Creating directory for defaults/main.yml backup"
    mkdir -vp backup/defaults
  fi

  if [ ! -d "backup/vars" ]; then
    echo "Creating directory for roles/.../vars/main.yml backup"
    mkdir -vp backup/vars
  fi

  if [ ! -d "backup/templates" ]; then
    echo "Creating directory for rules backup"
    mkdir -vp backup/templates
  fi

  cp -av defaults/main.yml backup/defaults/

  cp -av /usr/local/bin/zebrunner-farm backup/templates/
  cp -av /usr/local/bin/mcloud-devices.txt backup/templates/

  if [ "$os" == "Darwin" ]; then
    required+=( "backup/templates/ZebrunnerDevicesListener.plist" "backup/templates/ZebrunnerUsbmuxd.plist" )
    cp -av "$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist" backup/templates/
    cp -av "$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" backup/templates/
    cp -av roles/mac-devices/vars/main.yml backup/vars/
  else
    required+=( "backup/templates/90_mcloud.rules" )
    cp -av /etc/udev/rules.d/90_mcloud.rules backup/templates/
    cp -av roles/devices/vars/main.yml backup/vars/
  fi

  missing=()
  for f in "${required[@]}"; do
    [[ -f "$f" ]] || missing+=("$f")
  done

  if (( ${#missing[@]} == 0 )); then
    echo "MCloud backup succeeded."
  else
    echo_warning "MCloud backup failed! Missing: ${missing[*]}"
    echo_telegram
  fi

  echo -e "\n===================================================================\n"
}

restore() {
  confirm "" "      Your services will be stopped and current data might be lost. Do you want to do a restore now?" "n" || exit 0

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
}

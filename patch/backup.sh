#!/bin/bash

backup() {
  echo -e "\n==== Backup MCloud Agent in '$ZEBRUNNER_MCLOUD_AGENT_DIR' ====\n"

  confirm "" "      Do you want to do a backup now?" "n" || exit 0
  echo ""
  echo -en "Creating new backup directory:\n    "
  local backup_dir_name
  backup_dir_name="backup/bak_$(date +%d-%m-%Y_%H-%M)_$(random_string 5)"
  if mkdir -vp "$backup_dir_name" 2>/dev/null; then
   echo ""
  else
    failed "mkdir for '$backup_dir_name' failed"
    exit 1
  fi

  if [ ! -d "$backup_dir_name/defaults" ]; then
    echo -en "Creating directory for $backup_dir_name/main.yml backup:\n    "
    mkdir -vp "$backup_dir_name/defaults" 2>/dev/null || failed "mkdir for '$backup_dir_name/defaults' failed"
    echo ""
  fi

  if [ ! -d "$backup_dir_name/vars" ]; then
    echo -en "Creating directory for roles/.../vars/main.yml backup:\n    "
    mkdir -vp "$backup_dir_name/vars" 2>/dev/null || failed "mkdir for '$backup_dir_name/vars' failed"
    echo ""
  fi

  if [ ! -d "$backup_dir_name/templates" ]; then
    echo -en "Creating directory for rules backup:\n    "
    mkdir -vp "$backup_dir_name/templates" 2>/dev/null || failed "mkdir for '$backup_dir_name/defaults' failed"
    echo ""
  fi

  echo "Backing up MCloud Agent related files:"
  required=( \
    "$backup_dir_name/defaults/main.yml" \
    "$backup_dir_name/templates/zebrunner-farm" \
    "$backup_dir_name/templates/mcloud-devices.txt" \
    "$backup_dir_name/vars/main.yml"\
    )
  echo -n "    "
  cp -av defaults/main.yml "$backup_dir_name/defaults/" 2>/dev/null || failed "cp for 'defaults/main.yml' failed"
  echo -n "    "
  cp -av /usr/local/bin/zebrunner-farm "$backup_dir_name/templates/" 2>/dev/null || failed "cp for '/usr/local/bin/zebrunner-farm' failed"
  echo -n "    "
  cp -av /usr/local/bin/mcloud-devices.txt "$backup_dir_name/templates/" 2>/dev/null || failed "cp for '/usr/local/bin/mcloud-devices.txt' failed"
  if [ "$(uname)" == "Darwin" ]; then
    required+=( "$backup_dir_name/templates/ZebrunnerDevicesListener.plist" "$backup_dir_name/templates/ZebrunnerUsbmuxd.plist" )
    echo -n "    "
    cp -av "$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist" "$backup_dir_name/templates/" 2>/dev/null || failed "cp for '$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist' failed"
    echo -n "    "
    cp -av "$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" "$backup_dir_name/templates/" 2>/dev/null || failed "cp for '$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist' failed"
    echo -n "    "
    cp -av roles/mac-devices/vars/main.yml "$backup_dir_name/vars/" 2>/dev/null || failed "cp for 'roles/mac-devices/vars/main.yml' failed"
  else
    required+=( "$backup_dir_name/templates/90_mcloud.rules" )
    echo -n "    "
    cp -av /etc/udev/rules.d/90_mcloud.rules "$backup_dir_name/templates/" 2>/dev/null || failed "cp for '/etc/udev/rules.d/90_mcloud.rules' failed"
    echo -n "    "
    cp -av roles/devices/vars/main.yml "$backup_dir_name/vars/" 2>/dev/null || failed "cp for 'roles/devices/vars/main.yml' failed"
  fi

  missing=()
  for f in "${required[@]}"; do
    [[ -f "$f" ]] || missing+=("$f")
  done

  echo -e "\n*******************************************************************\n"
  echo "Status:"
  if (( ${#missing[@]} == 0 )); then
    echo -n "    "
    succeed "MCloud backup succeeded!"
    echo -n "    "
    succeed "Backup directory: $backup_dir_name"
  else
    echo -n "    "
    failed "MCloud backup failed!"
    echo -n "    "
    failed "Missing: ${missing[*]}"
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

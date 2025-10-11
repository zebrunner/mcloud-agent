#!/bin/bash

backup() {
  echo -e "\n==== Backup MCloud Agent in '$ZEBRUNNER_MCLOUD_AGENT_DIR' ====\n"

  confirm "" "      Do you want to do a backup now?" "n" || exit 0
  echo ""
  echo "Creating new backup directory:"
  echo -n "    "
  local backup_dir_name
  backup_dir_name="backup/bak_$(date +%d-%m-%Y_%H-%M)_$(random_string 5)"
  if mkdir -vp "$backup_dir_name" 2>/dev/null; then
   echo ""
  else
    failed "mkdir for '$backup_dir_name' failed"
    exit 1
  fi

  if [ ! -d "$backup_dir_name/defaults" ]; then
    echo "Creating directory for $backup_dir_name/main.yml backup:"
    echo -n "    "
    mkdir -vp "$backup_dir_name/defaults" 2>/dev/null || failed "mkdir for '$backup_dir_name/defaults' failed"
    echo ""
  fi

  if [ ! -d "$backup_dir_name/vars" ]; then
    echo "Creating directory for roles/.../vars/main.yml backup:"
    echo -n "    "
    mkdir -vp "$backup_dir_name/vars" 2>/dev/null || failed "mkdir for '$backup_dir_name/vars' failed"
    echo ""
  fi

  if [ ! -d "$backup_dir_name/templates" ]; then
    echo "Creating directory for rules backup:"
    echo -n "    "
    mkdir -vp "$backup_dir_name/templates" 2>/dev/null || failed "mkdir for '$backup_dir_name/defaults' failed"
    echo ""
  fi

  echo "Backing up MCloud Agent related files:"
  echo -n "    "
  cp -av defaults/main.yml "$backup_dir_name/defaults/" 2>/dev/null || failed "cp for 'defaults/main.yml' failed"
  echo -n "    "
  cp -av /usr/local/bin/zebrunner-farm "$backup_dir_name/templates/" 2>/dev/null || failed "cp for '/usr/local/bin/zebrunner-farm' failed"
  echo -n "    "
  cp -av /usr/local/bin/mcloud-devices.txt "$backup_dir_name/templates/" 2>/dev/null || failed "cp for '/usr/local/bin/mcloud-devices.txt' failed"
  if [ "$(uname)" == "Darwin" ]; then
    echo -n "    "
    cp -av "$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist" "$backup_dir_name/templates/" 2>/dev/null || failed "cp for '$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist' failed"
    echo -n "    "
    cp -av "$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" "$backup_dir_name/templates/" 2>/dev/null || failed "cp for '$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist' failed"
    echo -n "    "
    cp -av roles/mac-devices/vars/main.yml "$backup_dir_name/vars/" 2>/dev/null || failed "cp for 'roles/mac-devices/vars/main.yml' failed"
  else
    echo -n "    "
    cp -av /etc/udev/rules.d/90_mcloud.rules "$backup_dir_name/templates/" 2>/dev/null || failed "cp for '/etc/udev/rules.d/90_mcloud.rules' failed"
    echo -n "    "
    cp -av roles/devices/vars/main.yml "$backup_dir_name/vars/" 2>/dev/null || failed "cp for 'roles/devices/vars/main.yml' failed"
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

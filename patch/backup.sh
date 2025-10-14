#!/bin/bash

backup() {
  echo -e "\n==== Backup MCloud Agent in '$ZEBRUNNER_MCLOUD_AGENT_DIR' ====\n"

  confirm "" "      Do you want to do a backup now?" "n" || exit 0
  echo ""
  echo "Creating backup directories:"
  echo -n "    "
  local backup_dir_name
  backup_dir_name="backup/bak_$(date +%d-%m-%Y_%H-%M)_$(random_string 5)"
  if ! mkdir -vp "$backup_dir_name" 2>/dev/null; then
    failed "mkdir for '$backup_dir_name' failed"
    exit 1
  fi

  if [ ! -d "$backup_dir_name/defaults" ]; then
    echo -n "    "
    mkdir -vp "$backup_dir_name/defaults" 2>/dev/null || failed "mkdir for '$backup_dir_name/defaults' failed"
  fi

  if [ ! -d "$backup_dir_name/tasks" ]; then
    echo -n "    "
    mkdir -vp "$backup_dir_name/tasks" 2>/dev/null || failed "mkdir for '$backup_dir_name/tasks' failed"
  fi

  if [ ! -d "$backup_dir_name/templates" ]; then
    echo -n "    "
    mkdir -vp "$backup_dir_name/templates" 2>/dev/null || failed "mkdir for '$backup_dir_name/defaults' failed"
  fi

  if [ ! -d "$backup_dir_name/vars" ]; then
    echo -n "    "
    mkdir -vp "$backup_dir_name/vars" 2>/dev/null || failed "mkdir for '$backup_dir_name/vars' failed"
  fi

  if [ ! -d "$backup_dir_name/download" ]; then
    echo -n "    "
    mkdir -vp "$backup_dir_name/download" 2>/dev/null || failed "mkdir for '$backup_dir_name/download' failed"
  fi

  echo ""
  echo "Backing up MCloud Agent related files:"
  echo -n "    "
  cp -av "zebrunner.sh" "$backup_dir_name/zebrunner.sh" 2>/dev/null || failed "cp for 'zebrunner.sh' failed"
  echo -n "    "
  cp -av "defaults/main.yml" "$backup_dir_name/defaults/" 2>/dev/null || failed "cp for 'defaults/main.yml' failed"
  echo -n "    "
  cp -av "roles/download/tasks/main.yml" "$backup_dir_name/download/" 2>/dev/null || failed "cp for 'roles/download/tasks/main.yml' failed"

  if [ "$(uname)" == "Darwin" ]; then
    echo -n "    "
    cp -av "roles/mac-devices/tasks/usbmuxd.yml" "$backup_dir_name/tasks/" 2>/dev/null || failed "cp for 'roles/mac-devices/tasks/usbmuxd.yml' failed"
    echo -n "    "
    cp -av "roles/mac-devices/templates/zebrunner-farm" "$backup_dir_name/templates/" 2>/dev/null || failed "cp for 'roles/mac-devices/templates/zebrunner-farm' failed"
    echo -n "    "
    cp -av "roles/mac-devices/vars/main.yml" "$backup_dir_name/vars/" 2>/dev/null || failed "cp for 'roles/mac-devices/vars/main.yml' failed"
  else
    echo -n "    "
    cp -av "roles/devices/tasks/udev.yml" "$backup_dir_name/tasks/" 2>/dev/null || failed "cp for 'roles/devices/tasks/udev.yml' failed"
    echo -n "    "
    cp -av "roles/devices/templates/zebrunner-farm" "$backup_dir_name/templates/" 2>/dev/null || failed "cp for 'roles/devices/templates/zebrunner-farm' failed"
    echo -n "    "
    cp -av "roles/devices/vars/main.yml" "$backup_dir_name/vars/" 2>/dev/null || failed "cp for 'roles/devices/vars/main.yml' failed"
  fi

  echo -e "\n===================================================================\n"
}

restore() {
  echo -e "\n==== Backup MCloud Agent in '$ZEBRUNNER_MCLOUD_AGENT_DIR' ====\n"

  confirm "" "      Your services will be stopped and current data might be lost. Do you want to do a restore now?" "n" || exit 0

  echo ""
  ask_for_sudo || {
    echo_warning "Sudo permissions are required to run this script!"
    exit 1
  }
  echo ""
  echo "Backups found in 'backup' directory:"
  for bup in backup/bak_*; do
    if [ -d "$bup" ]; then
      echo "    $(basename "$bup")"
    fi
  done

  echo ""
  while true; do
    read -r -p "Please enter the backup directory name you want to restore: " backup_dir_name
    if [ -d "backup/$backup_dir_name" ]; then
      backup_dir_name="backup/$backup_dir_name"
      break
    else
      echo -n "    "
      echo "Directory 'backup/$backup_dir_name' does not exist. Please try again."
      echo ""
    fi
  done

  echo ""
  echo "Restoring from 'backup_dir_name':"
  echo -n "    "
  cp -av "$backup_dir_name/zebrunner.sh" "zebrunner.sh" 2>/dev/null || failed "cp for '$backup_dir_name/zebrunner.sh' failed"
  echo -n "    "
  cp -av "$backup_dir_name/defaults/main.yml" "defaults/" 2>/dev/null || failed "cp for '$backup_dir_name/defaults/main.yml' failed"
  echo -n "    "
  cp -av "$backup_dir_name/download/main.yml" "roles/download/tasks/"  2>/dev/null || failed "cp for '$backup_dir_name/download/main.yml' failed"

  if [ "$(uname)" == "Darwin" ]; then
    echo -n "    "
    cp -av "$backup_dir_name/tasks/usbmuxd.yml" "roles/mac-devices/tasks/" 2>/dev/null || failed "cp for '$backup_dir_name/tasks/usbmuxd.yml' failed"
    echo -n "    "
    cp -av "$backup_dir_name/templates/zebrunner-farm" "roles/mac-devices/templates/" 2>/dev/null || failed "cp for '$backup_dir_name/templates/zebrunner-farm' failed"
    echo -n "    "
    cp -av "$backup_dir_name/vars/main.yml" "roles/mac-devices/vars/" 2>/dev/null || failed "cp for '$backup_dir_name/vars/main.yml' failed"
  else
    echo -n "    "
    cp -av "$backup_dir_name/tasks/udev.yml" "roles/devices/tasks/" 2>/dev/null || failed "cp for '$backup_dir_name/tasks/udev.yml' failed"
    echo -n "    "
    cp -av "$backup_dir_name/templates/zebrunner-farm" "roles/devices/templates/" 2>/dev/null || failed "cp for '$backup_dir_name/templates/zebrunner-farm' failed"
    echo -n "    "
    cp -av "$backup_dir_name/vars/main.yml" "roles/devices/vars/" 2>/dev/null || failed "cp for '$backup_dir_name/vars/main.yml' failed"
  fi

  echo_warning "Your services needs to be restarted after restore."

  echo -e "\n===================================================================\n"
}

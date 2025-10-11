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
    else
      echo "Directory 'backup/$backup_dir_name' does not exist. Please try again."
    fi
  done

  echo "Backing up:"
  echo -n "    "
  cp -av "$backup_dir_name/defaults/main.yml" "defaults/main.yml" 2>/dev/null || failed "cp for 'defaults/main.yml' failed"
  echo -n "    "
  sudo cp -av "$backup_dir_name/templates/zebrunner-farm" "/usr/local/bin/zebrunner-farm" 2>/dev/null || failed "cp for '$backup_dir_name/templates/zebrunner-farm' failed"
  echo -n "    "
  sudo cp -av "$backup_dir_name/templates/mcloud-devices.txt" "/usr/local/bin/mcloud-devices.txt" 2>/dev/null || failed "cp for '$backup_dir_name/templates/mcloud-devices.txt' failed"
  if [ "$(uname)" == "Darwin" ]; then
    echo -n "    "
    cp -av "$backup_dir_name/vars/main.yml" "roles/mac-devices/vars/main.yml" 2>/dev/null || failed "cp for 'roles/mac-devices/vars/main.yml' failed"

    echo -n "    "
    echo "Unloading ZebrunnerDevicesListener.plist, replacing, loading again:"
    if launchctl list com.zebrunner.mcloud; then
       if launchctl bootout gui/"$(id -u)" "$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist" 2>/dev/null; then
         echo -n "    "; echo -n "    "
         echo "'$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist' stopped"
         echo -n "    "; echo -n "    "
          if sudo cp -av "$backup_dir_name/templates/ZebrunnerDevicesListener.plist" "$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist" 2>/dev/null; then
            if launchctl bootstrap gui/"$(id -u)" "$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist" 2>/dev/null && launchctl enable gui/"$(id -u)"/com.zebrunner.mcloud; then
              echo -n "    "; echo -n "    "
              echo "'$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist' started"
            else
              echo -n "    "; echo -n "    "
              failed "launchctl bootstrap for '$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist' failed"
            fi
          else
            echo -n "    "; echo -n "    "
            failed "cp for '$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist' failed"
          fi
       fi
    else
      echo -n "    "; echo -n "    "
      echo "'$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist' is not running"
      echo -n "    "; echo -n "    "
      sudo cp -av "$backup_dir_name/templates/ZebrunnerDevicesListener.plist" "$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist" 2>/dev/null || failed "cp for '$HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist' failed"
    fi

    echo -n "    "
    echo "Unloading ZebrunnerUsbmuxd.plist, replacing, loading again:"
    if launchctl list com.zebrunner.usbmuxd; then
       if launchctl bootout gui/"$(id -u)" "$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" 2>/dev/null; then
         echo -n "    "; echo -n "    "
         echo "'$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist' stopped"
         echo -n "    "; echo -n "    "
          if sudo cp -av "$backup_dir_name/templates/ZebrunnerUsbmuxd.plist" "$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" 2>/dev/null; then
            if launchctl bootstrap gui/"$(id -u)" "$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" 2>/dev/null && launchctl enable gui/"$(id -u)"/com.zebrunner.usbmuxd; then
              echo -n "    "; echo -n "    "
              echo "'$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist' started"
            else
              echo -n "    "; echo -n "    "
              failed "launchctl bootstrap for '$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist' failed"
            fi
          else
            echo -n "    "; echo -n "    "
            failed "cp for '$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist' failed"
          fi
       fi
    else
      echo -n "    "; echo -n "    "
      echo "'$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist' is not running"
      echo -n "    "; echo -n "    "
      sudo cp -av "$backup_dir_name/templates/ZebrunnerUsbmuxd.plist" "$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist" 2>/dev/null || failed "cp for '$HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist' failed"
    fi

  else
    echo -n "    "
    sudo cp -av "$backup_dir_name/templates/90_mcloud.rules" "/etc/udev/rules.d/90_mcloud.rules" 2>/dev/null || failed "cp for 'roles/devices/vars/main.yml' failed"
    echo -n "    "
    cp -av "$backup_dir_name/vars/main.yml" "roles/devices/vars/main.yml" 2>/dev/null || failed "cp for 'roles/devices/vars/main.yml' failed"

    # reload udevadm rules
    sudo udevadm control --reload-rules
  fi

  echo_warning "Your services needs to be restarted after restore."

  echo -e "\n===================================================================\n"
}

#!/bin/bash

backup() {
  confirm "" "      Do you want to do a backup now?" "n" || exit 0

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

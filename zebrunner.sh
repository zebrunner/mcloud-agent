#!/bin/bash

## shellcheck disable=SC1091
#source patch/utility.sh

  setup() {
    cp roles/devices/vars/main.yml.original roles/devices/vars/main.yml
    echo "Follow https://github.com/zebrunner/mcloud-android#readme to setup MCloud agent as of now!"
  }

  shutdown() {
    if [ ! -f /usr/local/bin/zebrunner-farm ]; then
      echo_warning "You have to setup services in advance using: ./zebrunner.sh setup"
      echo_telegram
      exit -1
    fi

    echo_warning "Shutdown will erase all settings and data for \"${BASEDIR}\"!"
    confirm "" "      Do you want to continue?" "n"
    if [[ $? -eq 0 ]]; then
      exit
    fi

    sudo rm -f /usr/local/bin/zebrunner-farm
    sudo rm -f /usr/local/bin/devices.txt
    sudo rm -f /etc/udev/rules.d/90_mcloud.rules
    # restore original main.yml
    rm -f roles/devices/vars/main.yml
  }


  start() {
    if [[ ! -f /usr/local/bin/zebrunner-farm ]]; then
      echo_warning "You have to setup services in advance using: ./zebrunner.sh setup"
      echo_telegram
      exit -1
    fi

    /usr/local/bin/zebrunner-farm start
  }

  stop() {
    /usr/local/bin/zebrunner-farm stop
  }

  down() {
    /usr/local/bin/zebrunner-farm down
  }

  backup() {
    confirm "" "      Do you want to do a backup now?" "n"
    if [[ $? -eq 0 ]]; then
      exit
    fi

    # copy udev related files into ./backup folder
    cp /usr/local/bin/zebrunner-farm backup/
    cp /usr/local/bin/devices.txt backup/
    cp /etc/udev/rules.d/90_mcloud.rules backup/
    cp roles/devices/vars/main.yml roles/devices/vars/main.yml.bak

    if [ -f backup/zebrunner-farm ] && [ -f backup/devices.txt ] && [ -f backup/90_mcloud.rules ] && [ -f roles/devices/vars/main.yml.bak ]; then
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
    sudo cp backup/devices.txt /usr/local/bin/devices.txt
    sudo cp backup/90_mcloud.rules /etc/udev/rules.d/90_mcloud.rules
    cp roles/devices/vars/main.yml.bak roles/devices/vars/main.yml

    # reload udevadm rules
    sudo udevadm control --reload-rules

    if [ -f /usr/local/bin/zebrunner-farm ] && [ -f /usr/local/bin/devices.txt ] && [ -f /etc/udev/rules.d/90_mcloud.rules ] && [ -f roles/devices/vars/main.yml ]; then
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


  restore() {
    stop

    sudo cp backup/zebrunner-farm /usr/local/bin/
    sudo cp backup/devices.txt /usr/local/bin/
    sudo cp backup/90_mcloud.rules /etc/udev/rules.d/
    # reload udevadm rules
    sudo udevadm control --reload-rules

    down
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

      if [[ "$response" == "n" ||  "$response" == "N" ]]; then
        return 0
      fi

      echo "Please answer y (yes) or n (no)."
      echo
    done
  }

  version() {
    source .env
    echo "Zebrunner MCloud Agent: ${MCLOUD_VERSION}"
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
      	  start          Start container
      	  stop           Stop and keep container
      	  restart        Restart container
      	  down           Stop and remove container
      	  shutdown       Stop and remove container, clear volumes
      	  backup         Backup container
      	  restore        Restore container
      	  version        Version of container"
      echo_telegram
      exit 0
  }


BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${BASEDIR}" || exit

case "$1" in
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
        echo "Invalid option detected: $1"
        echo_help
        exit 1
        ;;
esac


#!/bin/bash

## shellcheck disable=SC1091
#source patch/utility.sh

  setup() {
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
    cp /usr/local/bin/zebrunner-farm backup/
    cp /usr/local/bin/devices.txt backup/
    cp /etc/udev/rules.d/90_mcloud.rules backup/
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

  version() {
    source .env
    echo "MCloud Agent: ${MCLOUD_VERSION}"
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


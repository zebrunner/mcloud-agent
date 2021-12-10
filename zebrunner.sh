#!/bin/bash

# shellcheck disable=SC1091
source patch/utility.sh

  setup() {
    # load default interactive installer settings
    source backup/settings.env.original

    # load ./backup/settings.env if exist to declare ZBR* vars from previous run!
    if [[ -f backup/settings.env ]]; then
      source backup/settings.env
    fi

    set_mcloud_settings
    url="$ZBR_PROTOCOL://$ZBR_HOSTNAME:$ZBR_MCLOUD_PORT"

    cp .env.original .env
    #TODO: Think about parametrization and asking actual value
    replace .env "TCP_RETHINK_DB=" "TCP_RETHINK_DB=tcp://$ZBR_HOSTNAME:28015"
    #TODO: verify connection to rethinkdb 28015 tcpip port is available!

    cp variables.env.original variables.env
    replace variables.env "STF_URL=" "STF_URL=${url}"

    # export all ZBR* variables to save user input
    export_settings
  }

  shutdown() {
    if [ ! -f .env ]; then
      echo_warning "You have to setup services in advance using: ./zebrunner.sh setup"
      echo_telegram
      exit -1
    fi

    echo_warning "Shutdown will erase all settings and data for \"${BASEDIR}\"!"
    confirm "" "      Do you want to continue?" "n"
    if [[ $? -eq 0 ]]; then
      exit
    fi

    docker-compose --env-file .env -f docker-compose.yml down -v

    rm -f backup/settings.env
    rm -f variables.env
    rm -f .env
  }


  start() {
    # create infra network only if not exist
    docker network inspect infra >/dev/null 2>&1 || docker network create infra

    if [[ ! -f .env ]]; then
      # need proceed with setup steps in advance!
      setup
    fi

    docker-compose --env-file .env -f docker-compose.yml up -d
  }

  stop() {
    docker-compose --env-file .env -f docker-compose.yml stop
  }

  down() {
    docker-compose --env-file .env -f docker-compose.yml down
  }

  backup() {
    cp .env .env.bak
    cp variables.env variables.env.bak
    cp backup/settings.env backup/settings.env.bak
  }

  restore() {
    stop
    cp .env.bak .env
    cp variables.env.bak variables.env
    cp backup/settings.env.bak backup/settings.env
    down
  }

  version() {
    source .env.original
    echo "MCloud Agent: ${TAG_STF}"
  }

  set_mcloud_settings() {
    echo "Zebrunner MCloud Settings"
    local is_confirmed=0
    if [[ -z $ZBR_HOSTNAME ]]; then
      ZBR_HOSTNAME=`curl -s ifconfig.me`
    fi

    while [[ $is_confirmed -eq 0 ]]; do
      read -r -p "Protocol [$ZBR_PROTOCOL]: " local_protocol
      if [[ ! -z $local_protocol ]]; then
        ZBR_PROTOCOL=$local_protocol
      fi

      read -r -p "Fully qualified domain name (ip) [$ZBR_HOSTNAME]: " local_hostname
      if [[ ! -z $local_hostname ]]; then
        ZBR_HOSTNAME=$local_hostname
      fi

      read -r -p "Port [$ZBR_MCLOUD_PORT]: " local_port
      if [[ ! -z $local_port ]]; then
        ZBR_MCLOUD_PORT=$local_port
      fi

      confirm "Zebrunner MCloud STF URL: $ZBR_PROTOCOL://$ZBR_HOSTNAME:$ZBR_MCLOUD_PORT/stf" "Continue?" "y"
      is_confirmed=$?
    done

    export ZBR_PROTOCOL=$ZBR_PROTOCOL
    export ZBR_HOSTNAME=$ZBR_HOSTNAME
    export ZBR_MCLOUD_PORT=$ZBR_MCLOUD_PORT

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

  replace() {
    #TODO: https://github.com/zebrunner/zebrunner/issues/328 organize debug logging for setup/replace
    file=$1
    #echo "file: $file"
    content=$(<"$file") # read the file's content into
    #echo "content: $content"

    old=$2
    #echo "old: $old"

    new=$3
    #echo "new: $new"
    content=${content//"$old"/$new}

    #echo "content: $content"
    printf '%s' "$content" >"$file"    # write new content to disk
  }


BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${BASEDIR}" || exit

case "$1" in
    setup)
        setup
        ;;
    start)
	start
        ;;
    stop)
        stop
        ;;
    restart)
        down
        start
        ;;
    down)
        down
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


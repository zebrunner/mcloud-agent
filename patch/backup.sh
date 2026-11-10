#!/bin/bash
# `./zebrunner.sh backup` and `restore` (README.md#settings): the local settings of config/ only, the code of the agent
# comes from git. Sourced by zebrunner.sh after patch/utility.sh.

# backup_files: the files of a backup, relative to the agent folder
backup_files() {
  echo "$SETTINGS_FILE" "$DEVICES_FILE"
}

backup() {
  delimiter "Backup MCloud Agent in '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"

  confirm "" "      Do you want to do a backup now?" "n" || exit 0
  echo ""
  local backup_dir_name
  backup_dir_name="backup/bak_$(date +%d-%m-%Y_%H-%M)_$(random_string 5)"
  echo "Creating backup directory:"
  echo -n "    "
  # the settings have secrets: the backup is private
  if ! (umask 077 && mkdir -vp "${backup_dir_name}/config" 2> /dev/null); then
    failed "mkdir for '${backup_dir_name}/config' failed"
    exit 1
  fi

  echo ""
  echo "Backing up the settings:"
  local file
  for file in $(backup_files); do
    echo -n "    "
    cp -pv "$file" "${backup_dir_name}/config/" 2> /dev/null || failed "cp for '${file}' failed"
  done

  delimiter
}

restore() {
  delimiter "Restore MCloud Agent in '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"

  warn "\tBefore restoring do the following:"
  warn ">\tzebrunner-farm down"
  echo ""

  confirm "" "      Current data might be lost. Do you want to do a restore now?" "n" || exit 0

  echo ""
  echo "Backups found in 'backup' directory:"
  for bup in backup/bak_*; do
    if [[ -d "$bup" ]]; then
      echo "    $(basename "$bup")"
    fi
  done

  echo ""
  while true; do
    read -r -p "Please enter the backup directory name you want to restore: " backup_dir_name || exit 1
    if [[ -n "$backup_dir_name" && -d "backup/${backup_dir_name}" ]]; then
      backup_dir_name="backup/${backup_dir_name}"
      break
    else
      echo -n "    "
      echo "Directory '${backup_dir_name}' does not exist. Please try again."
      echo ""
    fi
  done

  # a backup of an earlier version: the settings in vars/main.yml, the code of that version beside them
  if [[ ! -d "${backup_dir_name}/config" ]]; then
    echo_warning "'${backup_dir_name}' is a backup of an earlier version: ./zebrunner.sh migrate ${backup_dir_name}/vars/main.yml ${backup_dir_name}/defaults/main.yml moves its settings to '${SETTINGS_FILE}' and its devices: to '${DEVICES_FILE}' (README.md#settings)."
    exit 1
  fi

  echo ""
  echo "Restoring from '${backup_dir_name}':"
  mkdir -p config
  local file
  for file in $(backup_files); do
    echo -n "    "
    cp -pv "${backup_dir_name}/${file}" "$file" 2> /dev/null || failed "cp for '${backup_dir_name}/${file}' failed"
  done

  echo_warning "After recovery, you need to reapply the settings:"
  warn ">\t./zebrunner.sh ansible"
  warn ">\tzebrunner-farm start"

  delimiter
}

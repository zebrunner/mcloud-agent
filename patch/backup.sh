#!/bin/bash
# `./zebrunner.sh backup` and `restore` (README.md#settings): the local settings of config/ only, the code of the agent
# comes from git. Sourced by zebrunner.sh after patch/utility.sh and patch/ui.sh.

# backup_files: the files of a backup, relative to the agent folder
backup_files() {
  echo "$SETTINGS_FILE" "$DEVICES_FILE"
}

# backup: the settings of config/ into a private folder of backup/ (README.md#settings)
backup() {
  ui_section "Backup" "" "Backup MCloud Agent in '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"

  confirm "" "Do you want to do a backup now?" "n" || exit 0
  local backup_dir_name
  backup_dir_name="backup/bak_$(date +%d-%m-%Y_%H-%M)_$(random_string 5)"
  # the settings have secrets: the backup is private
  if ! (umask 077 && mkdir -p "${backup_dir_name}/config" 2> /dev/null); then
    ui_fail "mkdir for '${backup_dir_name}/config' failed"
    exit 1
  fi
  ui_ok "Creating backup directory: ${backup_dir_name}"

  local file
  for file in $(backup_files); do
    if cp -p "$file" "${backup_dir_name}/config/" 2> /dev/null; then
      ui_ok "Backing up the settings: '${file}' -> '${backup_dir_name}/config/'"
    else
      ui_fail "cp for '${file}' failed"
    fi
  done

  echo ""
  ui_rule
}

# restore: the settings of config/ from a folder of backup/, asks which one
restore() {
  ui_section "Restore" "" "Restore MCloud Agent in '${ZEBRUNNER_MCLOUD_AGENT_DIR}'"

  ui_warn "Before restoring do the following:" "zebrunner-farm down"

  confirm "" "Current data might be lost. Do you want to do a restore now?" "n" || exit 0

  echo ""
  ui_info "Backups found in 'backup' directory:"
  for bup in backup/bak_*; do
    if [[ -d "$bup" ]]; then
      ui_muted "  $(basename "$bup")"
    fi
  done

  echo ""
  while true; do
    read -r -p "$(ui_prompt "Please enter the backup directory name you want to restore:")" backup_dir_name || exit 1
    if [[ -n "$backup_dir_name" && -d "backup/${backup_dir_name}" ]]; then
      backup_dir_name="backup/${backup_dir_name}"
      break
    else
      ui_warn "Directory '${backup_dir_name}' does not exist. Please try again."
    fi
  done

  # a backup of an earlier version: the settings in vars/main.yml, the code of that version beside them
  if [[ ! -d "${backup_dir_name}/config" ]]; then
    echo_warning "'${backup_dir_name}' is a backup of an earlier version: ./zebrunner.sh migrate ${backup_dir_name}/vars/main.yml ${backup_dir_name}/defaults/main.yml moves its settings to '${SETTINGS_FILE}' and its devices: to '${DEVICES_FILE}' (README.md#settings)."
    exit 1
  fi

  echo ""
  mkdir -p config
  local file
  for file in $(backup_files); do
    if cp -p "${backup_dir_name}/${file}" "$file" 2> /dev/null; then
      ui_ok "Restoring from '${backup_dir_name}': '${file}'"
    else
      ui_fail "cp for '${backup_dir_name}/${file}' failed"
    fi
  done

  echo_warning "After recovery, you need to reapply the settings: ./zebrunner.sh ansible, then zebrunner-farm start"

  echo ""
  ui_rule
}

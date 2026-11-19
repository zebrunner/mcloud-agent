#!/bin/bash
# patch/utility.sh helpers: confirm, random_string and the message helpers with patch/ui.sh, without a terminal (plain
# text) and in ASCII
source "$(dirname "$0")/lib.sh"
source "${REPO}/patch/utility.sh"
# shellcheck source=../patch/ui.sh
source "${REPO}/patch/ui.sh"
UI_ASCII=true UI_COLOR=never COLUMNS=80 ui_init

section "confirm"
# answer <stdin text> <default>: exit code of confirm
answer() {
  printf '%b' "$1" | confirm "" "question?" "$2" > /dev/null
  echo "$?"
}
check "y confirms" "0" "$(answer 'y\n' n)"
check "Y confirms" "0" "$(answer 'Y\n' n)"
check "n declines" "1" "$(answer 'n\n' y)"
check "N declines" "1" "$(answer 'N\n' y)"
check "empty answer takes the default y" "0" "$(answer '\n' y)"
check "empty answer takes the default n" "1" "$(answer '\n' n)"
check "another answer is asked again" "0" "$(answer 'maybe\ny\n' n)"
check_contains "another answer is explained" "   warn Please answer y (yes) or n (no)." "$(printf 'maybe\ny\n' | confirm "" "question?" n)"
check_contains "the message is shown" "   info the message" "$(printf 'y\n' | confirm "the message" "question?" n)"
check "the prompt hints the default n" "  > Continue? [y/N] " "$(confirm_prompt "Continue?" n)"
check "the prompt hints the default y" "  > Continue? [Y/n] " "$(confirm_prompt "Continue?" y)"
check "the indent of an earlier caller is dropped" "  > Continue? [y/N] " "$(confirm_prompt "      Continue?" n)"

section "random_string"
check "default length" "48" "$(random_string | tr -d '\n' | wc -c | tr -d ' ')"
check "custom length" "5" "$(random_string 5 | tr -d '\n' | wc -c | tr -d ' ')"
check "letters and digits only" "" "$(random_string 200 | tr -d 'a-zA-Z0-9\n')"
check "invalid length takes the default" "48" "$(random_string abc | tr -d '\n' | wc -c | tr -d ' ')"
check "zero length is empty" "" "$(random_string 0)"
check "long string" "500" "$(random_string 500 | tr -d '\n' | wc -c | tr -d ' ')"
# CI runners set a UTF-8 LC_ALL (tr failed with "Illegal byte sequence") and start processes with SIGPIPE ignored
[[ "$(uname)" == "Darwin" ]] && utf8=en_US.UTF-8 || utf8=C.UTF-8
check "UTF-8 locale" "5" \
  "$(LC_ALL="$utf8" /bin/bash -c "source '${REPO}/patch/utility.sh'; random_string 5" 2> /dev/null | tr -d '\n' | wc -c | tr -d ' ')"
(
  trap '' PIPE
  random_string 5 > "${WORK}/random"
) &
random_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$random_pid" 2> /dev/null || break
  sleep 0.5
done
random_state="finished"
if kill -0 "$random_pid" 2> /dev/null; then
  pkill -P "$random_pid"
  kill "$random_pid"
  random_state="hung"
fi
check "ignored SIGPIPE does not hang" "finished" "$random_state"
check "ignored SIGPIPE result" "5" "$(tr -d '\n' < "${WORK}/random" | wc -c | tr -d ' ')"

section "messages"
check "failed is red" $'\033[0;31mtext\033[0m' "$(failed text)"
check "warn is yellow" $'\033[1;33mtext\033[0m' "$(warn text)"
check "succeed is green" $'\033[0;32mtext\033[0m' "$(succeed text)"
check "echo_warning is a warning callout" $'\n  | WARNING\n  | text' "$(echo_warning text)"
check_not_contains "echo_warning has no prefix of the earlier versions" "WARNING!" "$(echo_warning text)"
check "echo_telegram is muted text after an empty line" $'\n  For more help join telegram channel: https://t.me/zebrunner' "$(echo_telegram)"
check "print_section shows the detail under the title" $'\n  '"[ TITLE ] $(ui_repeat - 66)"$'\n\n  the detail' "$(print_section Title "the detail")"
check "print_step wraps the text under itself" $'   1. aaaa bbbb\n      cccc' "$(UI_WIDTH=14 print_step 1 "aaaa bbbb cccc")"
check "print_paragraph wraps the text" $'  aaaa bbbb\n  cccc' "$(UI_WIDTH=10 print_paragraph "aaaa bbbb cccc")"

section "yaml_python"
yaml="$(command -v "$(yaml_python)")"
if [[ -n "$yaml" ]]; then
  check "ZEBRUNNER_PYTHON goes first" "$yaml" "$(ZEBRUNNER_PYTHON="$yaml" yaml_python)"
  # python3 without PyYAML: the python of ansible-playbook --version
  stub python3 'exit 1'
  stub ansible-playbook "echo '  python version = 3.12.2 (main, Feb 27 2024) [Clang 14.0.6] (${yaml})'"
  check "the python of ansible" "$yaml" "$(PATH="${WORK}/bin:${PATH}" ZEBRUNNER_PYTHON="" yaml_python)"
  stub ansible-playbook "echo '  python version = 3.9.6 (default) [/nonexistent/python3]'"
  PATH="${WORK}/bin:${PATH}" ZEBRUNNER_PYTHON="" yaml_python > /dev/null
  check "no python with PyYAML fails" "1" "$?"
  rm -f "${WORK}/bin/python3" "${WORK}/bin/ansible-playbook"
else
  skip_check "yaml_python" "no python3 with PyYAML"
fi

finish

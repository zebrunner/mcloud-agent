#!/bin/bash
# patch/utility.sh helpers: confirm, random_string, delimiter, replace and the message helpers
source "$(dirname "$0")/lib.sh"
source "${REPO}/patch/utility.sh"

echo "# confirm"
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
check_contains "another answer is explained" "Please answer y (yes) or n (no)." "$(printf 'maybe\ny\n' | confirm "" "question?" n)"
check_contains "the message is shown" "the message" "$(printf 'y\n' | confirm "the message" "question?" n)"

echo "# random_string"
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
(trap '' PIPE; random_string 5 > "${WORK}/random") &
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

echo "# delimiter"
width="$(tput cols)"
line="$(delimiter | grep -v '^$')"
check "plain delimiter has the terminal width" "$width" "${#line}"
check "plain delimiter is made of =" "" "$(echo "$line" | tr -d '=')"
line="$(delimiter "*" | grep -v '^$')"
check "custom delimiter character" "" "$(echo "$line" | tr -d '*')"
line="$(delimiter "Title text" | grep -v '^$')"
check "titled delimiter has the terminal width" "$width" "${#line}"
check_contains "titled delimiter shows the title" "==== Title text ==" "$line"

echo "# replace"
printf 'a=old\nb=old\n' > "${WORK}/file"
replace "${WORK}/file" "old" "new"
check "all occurrences are replaced" "a=new
b=new" "$(cat "${WORK}/file")"

echo "# messages"
check "failed is red" $'\033[0;31mtext\033[0m' "$(failed text)"
check "warn is yellow" $'\033[1;33mtext\033[0m' "$(warn text)"
check "succeed is green" $'\033[0;32mtext\033[0m' "$(succeed text)"
check_contains "echo_warning prefix" "WARNING! text" "$(echo_warning text)"

finish

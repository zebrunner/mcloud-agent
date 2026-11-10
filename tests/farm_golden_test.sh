#!/bin/bash
# zebrunner-farm of both OS against the golden files tests/golden/farm-<os>.txt: the docker and launchctl calls and the
# output of the commands for every kind of device, so a change of the containers is a visible change of these files.
# After an intended change regenerate them and review the diff: UPDATE_GOLDEN=1 tests/farm_golden_test.sh
source "$(dirname "$0")/lib.sh"
require_cmd ansible

# udid|platform|name|location|appium|adb|min|max|connection|wda file|wda bundle id|address|wda port|mjpeg port|connect port
cat > "${WORK}/devices.txt" << 'EOF'
R28M1384YQY|android|Galaxy|loc|7421|7422|7425|7430|usb|/dev/null|x|||
192.168.1.50|android|WiFi|loc|7431|7432|7435|7440|wireless|/dev/null|x||||7499
d6afc6b3a65584ca0813eb8957c6479b9b6ebb11|ios|iPhone_8_Plus|loc|7441|7442|7445|7450|usb|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|||
aaaa1111|ios|AppleTV|loc|7451|7452|7455|7460|proxy|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|10.0.0.5|8100|
bbbb2222|ios|iPhoneWiFi|loc|7461|7462|7465|7470|wireless|/dev/null|com.facebook.WebDriverAgentRunner.xctrunner|192.168.1.60||
emu1|android|Emu|loc|7471|7472|7475|7480|android-sim|/dev/null|x|host.docker.internal:5557||
B1B07E76|ios|Sim|loc|7481|7482|7485|7490|ios-sim|/tmp/wda-sim.zip|com.facebook.WebDriverAgentRunner.xctrunner||8110|
EOF

# the calls of docker and launchctl go to ${WORK}/calls.log; docker ps lists no container
# the stub body is expanded when the stub runs
# shellcheck disable=SC2016
stub docker '(IFS="|"; echo "docker|$*") >> "${STUB_DIR}/calls.log"
[[ "$1" == run ]] && echo "id"
exit 0'
record_stub launchctl
# all the devices are plugged in: lsusb (Linux) and ioreg (macOS) list them
stub lsusb "cut -d'|' -f1 '${WORK}/devices.txt'"
stub ioreg "cut -d'|' -f1 '${WORK}/devices.txt'"
# the USB bus of the udev symlink: readlink -f of a missing file differs on Linux and macOS
stub readlink 'echo /dev/bus/usb/001/002'

# a secret with '$' is passed as it is
# shellcheck disable=SC2016
settings='{"MCLOUD_NODE_TOKEN": "token", "STF_PROVIDER_HOST": "10.1.1.1", "PUBLIC_IP": "mcloud.example.com",
  "PUBLIC_IP_PORT": "443", "PUBLIC_IP_PROTOCOL": "https", "STF_PROVIDER_CONNECT_SUB": "tcp://10.1.1.2:7250",
  "STF_PROVIDER_CONNECT_PUSH": "tcp://10.1.1.2:7270", "STF_PROVIDER_CONNECT_APP_DEALER": "tcp://10.1.1.2:7160",
  "STF_PROVIDER_CONNECT_DEV_DEALER": "tcp://10.1.1.2:7260", "SELENIUM_HUB_HOST": "10.1.1.2", "SELENIUM_HUB_PORT": "4446",
  "STF_ZMQ_CURVE_SERVER_PUBLIC_KEY": "server-key", "STF_ZMQ_CURVE_SECRET_KEY": "secret-key", "S3_BUCKET": "bucket",
  "S3_TENANT": "tenant", "S3_SECRET": "s3 $ecret", "WDA_FILE": "/opt/wda.ipa", "REMOTE_CONNECT_HOST": "relay.example.com"}'

# golden <devices|mac-devices>: the calls and the output of the commands; the paths of the test replaced, without the
# colors and the indent of the status table (column -t of util-linux keeps its empty first column, the one of macOS not)
golden() {
  local role="$1"
  local args
  render_farm "$role" "${WORK}/farm.env" --extra-vars "$settings" || return 1
  # the user of the deploy is the one of the test
  sed -i.bak -e "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${WORK}/devices.txt|" -e "s|^HOST_SSH_USER=.*|HOST_SSH_USER=tester|" "${WORK}/farm.env"
  for args in "start R28M1384YQY" "start WiFi" "start iPhone_8_Plus" "start AppleTV" "start iPhoneWiFi" "start Emu" \
    "start Sim" "start" "stop" "restart android" "down ios" "status"; do
    reset_calls
    echo "### zebrunner-farm ${args}"
    # the arguments are words
    # shellcheck disable=SC2086
    env -i HOME="$WORK" PATH="${WORK}/bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb STUB_DIR="$WORK" MCLOUD_LOCK_DIR="$WORK" \
      ZEBRUNNER_FARM_ENV="${WORK}/farm.env" /bin/bash "$FARM_SCRIPT" $args < /dev/null 2>&1
    echo "### calls"
    cat "${WORK}/calls.log" 2> /dev/null
  done | sed -e "s|${WORK}|<work>|g" -e "s|${REPO}|<agent>|g" -e $'s/\033\\[[0-9;]*m//g' -e 's/^ *|/|/'
}

for role in devices mac-devices; do
  os=linux
  [[ "$role" == "mac-devices" ]] && os=macos
  file="${REPO}/tests/golden/farm-${os}.txt"
  section "golden calls of ${os}"
  actual="$(golden "$role")" || exit 1
  if [[ -n "${UPDATE_GOLDEN:-}" ]]; then
    printf '%s\n' "$actual" > "$file"
    skip_check "${os}: the calls" "written to tests/golden/farm-${os}.txt"
    continue
  fi
  if [[ "$actual" == "$(cat "$file" 2> /dev/null)" ]]; then
    pass "${os}: the calls are the golden ones"
  else
    fail "${os}: the calls are not the golden ones" "regenerate with UPDATE_GOLDEN=1 after an intended change" \
      "$(diff <(cat "$file" 2> /dev/null) <(printf '%s\n' "$actual") | head -n 40)"
  fi
done

finish

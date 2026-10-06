#!/bin/bash
# macOS device listener with stubbed usbmuxd_watch and zebrunner-farm, run with the system bash 3.2
# in a launchd-like environment: debounce, serialized actions of a device with the newest event
# winning, action timeout, stale device locks, lock ownership and the log rotation.
source "$(dirname "$0")/lib.sh"
require_os Darwin

# run_listener <debounce seconds> <action timeout seconds>: runs the listener until the
# usbmuxd_watch stub ends; zebrunner-farm stub calls are logged into ${WORK}/farm.log,
# the listener log is ${WORK}/listener.log
run_listener() {
  rm -rf "${WORK}/tmp" "${WORK}/farm.log" "${WORK}/listener.log"*
  mkdir -p "${WORK}/tmp"
  sed -e "s/^DEBOUNCE_SECONDS=5\$/DEBOUNCE_SECONDS=$1/" -e "s/^ACTION_TIMEOUT_SECONDS=100\$/ACTION_TIMEOUT_SECONDS=$2/" \
    -e "s|^LISTENER_LOG=.*|LISTENER_LOG=\"${WORK}/listener.log\"|" \
    "${REPO}/roles/mac-devices/templates/zebrunner-device-listener" > "${WORK}/listener"
  env -i HOME="$HOME" TMPDIR="${WORK}/tmp" STUB_DIR="$WORK" PATH="${WORK}/bin:/bin:/usr/bin:/usr/sbin:/sbin" \
    /bin/bash "${WORK}/listener" > "${WORK}/listener.out" 2>&1
}

# actions <udid>: START/END sequence of the zebrunner-farm calls of a device
actions() {
  grep " $1\$" "${WORK}/farm.log" | cut -d ' ' -f 1,2 | paste -s -d ' ' -
}

# line <pattern>: number of the first farm.log line matching the pattern
line() {
  grep -n "$1" "${WORK}/farm.log" | head -1 | cut -d ':' -f 1
}

echo "# debounce, serialization and timeout"
cat > "${WORK}/bin/usbmuxd_watch" <<'EOF'
#!/bin/bash
echo "ATTACH udid=BURST handle=1"; sleep 0.3
echo "DETACH udid=BURST handle=1"; sleep 0.3
echo "ATTACH udid=BURST handle=2"
echo "ATTACH udid=SLOW1 handle=3"
echo "ATTACH udid=SLOW2 handle=4"
echo "ATTACH udid=HANG handle=5"
sleep 1.5; echo "DETACH udid=SLOW2 handle=4"
sleep 0.5; echo "DETACH udid=SLOW1 handle=3"
sleep 1;   echo "ATTACH udid=SLOW2 handle=6"
sleep 15
EOF
# an action takes 4 seconds, HANG never ends
cat > "${WORK}/bin/zebrunner-farm" <<'EOF'
#!/bin/bash
echo "START $1 $2" >> "${STUB_DIR}/farm.log"
if [[ "$2" == HANG ]]; then sleep 3013 & wait; else sleep 4; fi
echo "END $1 $2" >> "${STUB_DIR}/farm.log"
EOF
chmod +x "${WORK}/bin/"*
run_listener 1 6

check "a burst of events runs the newest action once" "START restart END restart" "$(actions BURST)"
check "DETACH during restart waits for it" "START restart END restart START down END down" "$(actions SLOW1)"
check "an outdated pending action is skipped" "START restart END restart START restart END restart" "$(actions SLOW2)"
check "a hung action does not finish" "START restart" "$(actions HANG)"
check "a hung action is reported" "1" "$(grep -c "'zebrunner-farm restart HANG' timed out" "${WORK}/listener.log")"
check "a hung action is killed with its children" "0" "$(pgrep -f 'sleep 3013' | wc -l | tr -d ' ')"
check "no device locks are left" "0" "$(find "${WORK}/tmp" -name '*.lock' | wc -l | tr -d ' ')"
check "no debounce jobs are left" "0" "$(pgrep -f 'usb-debounce:' | wc -l | tr -d ' ')"
check "no bash job reports in the log" "0" "$(grep -c 'Terminated' "${WORK}/listener.out")"

echo "# stale locks and lock ownership"
# STALE: a lock left by a killed job; OWN: a live job whose lock looks stale after a sleep of the Mac
cat > "${WORK}/bin/usbmuxd_watch" <<'EOF'
#!/bin/bash
state="$(ls -d "${TMPDIR}"/zebrunner-listener.*)"
mkdir "${state}/STALE.lock"
echo 999 > "${state}/STALE.lock/owner"
touch -t "$(date -v-2M +%Y%m%d%H%M.%S)" "${state}/STALE.lock"
echo "ATTACH udid=STALE handle=1"
echo "ATTACH udid=OWN handle=2"
sleep 1.5; echo "DETACH udid=OWN handle=2"
sleep 2;   echo "ATTACH udid=OWN handle=3"
sleep 14
EOF
cat > "${WORK}/bin/zebrunner-farm" <<'EOF'
#!/bin/bash
echo "START $1 $2" >> "${STUB_DIR}/farm.log"
if [[ "$1 $2" == "restart OWN" && ! -f "${STUB_DIR}/own-first" ]]; then
  touch "${STUB_DIR}/own-first"
  touch -t "$(date -v-2M +%Y%m%d%H%M.%S)" "${TMPDIR}"/zebrunner-listener.*/OWN.lock
  sleep 4
elif [[ "$1 $2" == "down OWN" ]]; then
  sleep 5
else
  sleep 1
fi
echo "END $1 $2" >> "${STUB_DIR}/farm.log"
EOF
chmod +x "${WORK}/bin/"*
run_listener 1 10

check "a stale lock of a killed job is removed" "START restart END restart" "$(actions STALE)"
check "removing a stale lock is reported" "1" "$(grep -c 'removing stale lock of STALE' "${WORK}/listener.log")"
check "a stale looking lock of a live job is taken over" "1" "$(grep -c 'removing stale lock of OWN' "${WORK}/listener.log")"
check "the newest action of the device runs last" "START restart END restart" "$(actions OWN | awk '{print $(NF-3), $(NF-2), $(NF-1), $NF}')"
# had the first restart released the lock taken over by down, the last restart would start before down ends
last_restart="$(grep -n '^START restart OWN' "${WORK}/farm.log" | tail -1 | cut -d ':' -f 1)"
check "a job does not release the lock of its successor" "yes" \
  "$([[ "${last_restart:-0}" -gt "$(line '^END down OWN')" ]] && echo yes || echo no)"
check "no device locks are left" "0" "$(find "${WORK}/tmp" -name '*.lock' | wc -l | tr -d ' ')"

echo "# log rotation"
# the log is renamed between two actions, as newsyslog does
cat > "${WORK}/bin/usbmuxd_watch" <<'EOF'
#!/bin/bash
echo "ATTACH udid=ROT1 handle=1"
sleep 3
mv "${STUB_DIR}/listener.log" "${STUB_DIR}/listener.log.0"
echo "ATTACH udid=ROT2 handle=2"
sleep 3
EOF
cat > "${WORK}/bin/zebrunner-farm" <<'EOF'
#!/bin/bash
echo "START $1 $2" >> "${STUB_DIR}/farm.log"
echo "output of $1 $2"
EOF
chmod +x "${WORK}/bin/"*
run_listener 1 10

check "action output before the rotation is in the rotated log" "1" "$(grep -c 'output of restart ROT1' "${WORK}/listener.log.0")"
check "action output after the rotation is in the new log" "1" "$(grep -c 'output of restart ROT2' "${WORK}/listener.log")"
check "listener messages after the rotation are in the new log" "1" "$(grep -c 'Device listener fall' "${WORK}/listener.log")"
check "nothing is written to the launchd stdout/stderr files" "" "$(cat "${WORK}/listener.out")"

if [[ "$FAILED" -ne 0 ]]; then
  echo "--- zebrunner-farm calls:"; cat "${WORK}/farm.log"
  echo "--- listener output:"; cat "${WORK}/listener.out" "${WORK}/listener.log" 2> /dev/null
fi
finish

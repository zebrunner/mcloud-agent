#!/bin/bash
# macOS device listener with stubbed usbmuxd_watch and zebrunner-farm: debounce,
# serialized actions of a device with the newest event winning, and the action timeout.
# Runs with the system bash 3.2 and a launchd-like environment.
set -u
cd "$(dirname "$0")/.." || exit 1

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/bin" "${work}/tmp"
log="${work}/farm.log"

# shorter delays keep the test fast, an action of the zebrunner-farm stub takes 4 seconds
sed -e 's/^DEBOUNCE_SECONDS=5$/DEBOUNCE_SECONDS=1/' -e 's/^ACTION_TIMEOUT_SECONDS=100$/ACTION_TIMEOUT_SECONDS=6/' \
  roles/mac-devices/templates/zebrunner-device-listener > "${work}/listener"

cat > "${work}/bin/usbmuxd_watch" <<'EOF'
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
cat > "${work}/bin/zebrunner-farm" <<EOF
#!/bin/bash
echo "START \$1 \$2" >> "$log"
if [[ "\$2" == HANG ]]; then sleep 3013 & wait; else sleep 4; fi
echo "END \$1 \$2" >> "$log"
EOF
chmod +x "${work}/bin/"*

env -i HOME="$HOME" TMPDIR="${work}/tmp" PATH="${work}/bin:/bin:/usr/bin:/usr/sbin:/sbin" \
  /bin/bash "${work}/listener" > "${work}/listener.out" 2>&1

fail=0
check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    echo "       expected: '$2'"
    echo "       actual:   '$3'"
    fail=1
  fi
}
actions() {
  grep " $1\$" "$log" | cut -d ' ' -f 1,2 | paste -s -d ' ' -
}

check "a burst of events runs the newest action once" "START restart END restart" "$(actions BURST)"
check "DETACH during restart waits for it" "START restart END restart START down END down" "$(actions SLOW1)"
check "an outdated pending action is skipped" "START restart END restart START restart END restart" "$(actions SLOW2)"
check "a hung action does not finish" "START restart" "$(actions HANG)"
check "a hung action is reported" "1" "$(grep -c "'zebrunner-farm restart HANG' timed out" "${work}/listener.out")"
check "a hung action is killed with its children" "0" "$(pgrep -f 'sleep 3013' | wc -l | tr -d ' ')"
check "no device locks are left" "0" "$(find "${work}/tmp" -name '*.lock' | wc -l | tr -d ' ')"

if [[ "$fail" -ne 0 ]]; then
  echo "--- zebrunner-farm calls:"; cat "$log"
  echo "--- listener output:"; cat "${work}/listener.out"
fi
exit "$fail"

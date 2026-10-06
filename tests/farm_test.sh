#!/bin/bash
# Device selection of zebrunner-farm: exact udid or name, platform or all devices
set -u
cd "$(dirname "$0")/.." || exit 1

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/bin"

cat > "${work}/devices.txt" <<'EOF'
R28M1384YQY|android|Galaxy|loc|7421|7422|7423|7424|7425|7430|false|/dev/null|x
192.168.1.50|android|WiFi|loc|7431|7432|7433|7434|7435|7440|true|/dev/null|x
d6afc6b3a65584ca0813eb8957c6479b9b6ebb11|ios|iPhone_8_Plus|loc|7441|7442|7443|7444|7445|7450|false|/dev/null|x
EOF

# docker stub records the removed device volumes, launchctl stub is for macOS
cat > "${work}/bin/docker" <<EOF
#!/bin/bash
[[ "\$1 \$2" == "volume rm" ]] && echo "\$3" >> "${work}/removed"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "${work}/bin/launchctl"
chmod +x "${work}/bin/"*

fail=0
for role in devices mac-devices; do
  farm="${work}/zebrunner-farm-${role}"
  tests/render_farm.sh "$role" "$farm" || exit 1
  sed -i.bak "s|^MCLOUD_DEVICES=.*|MCLOUD_DEVICES=${work}/devices.txt|" "$farm"

  while IFS='=' read -r query expected; do
    : > "${work}/removed"
    PATH="${work}/bin:${PATH}" bash "$farm" down "$query" > /dev/null 2>&1
    actual="$(sed 's/^device-//; s/-.*//' "${work}/removed" | paste -s -d ' ' -)"
    if [[ "$actual" == "$expected" ]]; then
      echo "ok   - ${role}: down '${query}' -> '${actual}'"
    else
      echo "FAIL - ${role}: down '${query}' -> '${actual}', expected '${expected}'"
      fail=1
    fi
  done <<'EOF'
R28M1384YQY=Galaxy
Galaxy=Galaxy
iPhone_8_Plus=iPhone_8_Plus
R28=
7421=
ios=iPhone_8_Plus
android=Galaxy WiFi
=Galaxy WiFi iPhone_8_Plus
EOF
done

exit "$fail"

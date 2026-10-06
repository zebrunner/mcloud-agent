#!/bin/bash
# Temporary diagnostics of the slow Ansible fact gathering on the GitHub macOS runner (about 70 seconds
# per playbook): host names and DNS settings, timing of the hostname lookups, of the commands and Python
# calls of the minimal facts, of every minimal facts collector alone, of the Python interpreter discovery
# and of playbooks with and without facts. To be removed together with its CI step once the cause is known.
cd "$(dirname "$0")/.." || exit 1
TIMEFORMAT='%Rs'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# measure <label> <command...>: prints the wall time of the command, its output is dropped
measure() {
  local label="$1"
  shift
  local duration
  duration="$({ time "$@" > /dev/null 2>&1; } 2>&1)"
  printf '%-62s %s\n' "$label" "$duration"
}

# py <code>: runs Python code, for measure
py() {
  python3 -c "$1"
}

echo "# host"
uname -a
if [[ "$(uname)" == "Darwin" ]]; then
  sw_vers
  for name in ComputerName LocalHostName HostName; do
    echo "scutil --get ${name}: $(scutil --get "$name" 2>&1)"
  done
  echo "--- scutil --dns:"
  scutil --dns | grep -E 'nameserver|search domain|^  domain' | sort -u | head -10
else
  echo "--- /etc/resolv.conf:"
  grep -v '^#' /etc/resolv.conf
fi
echo "--- /etc/hosts:"
grep -v -E '^#|^$' /etc/hosts
echo "python3: $(command -v python3), $(python3 --version 2>&1)"
echo "ansible: $(ansible --version 2>&1 | head -1)"
py 'import socket; print("gethostname:", socket.gethostname()); print("getfqdn:", socket.getfqdn())'

echo "# hostname lookups"
measure "python3 startup" py 'pass'
measure "socket.gethostname()" py 'import socket; socket.gethostname()'
measure "socket.getfqdn()" py 'import socket; socket.getfqdn()'
measure "socket.gethostbyname(gethostname())" py 'import socket; socket.gethostbyname(socket.gethostname())'
measure "socket.gethostbyaddr(gethostname())" py 'import socket; socket.gethostbyaddr(socket.gethostname())'
measure "socket.getaddrinfo(gethostname())" py 'import socket; socket.getaddrinfo(socket.gethostname(), None)'
measure "socket.gethostbyaddr('127.0.0.1')" py 'import socket; socket.gethostbyaddr("127.0.0.1")'
measure "socket.getaddrinfo('localhost')" py 'import socket; socket.getaddrinfo("localhost", None)'
if [[ "$(uname)" == "Darwin" ]]; then
  measure "dscacheutil -q host -a name $(hostname)" dscacheutil -q host -a name "$(hostname)"
fi

echo "# commands and Python calls of the minimal facts"
measure "platform.uname()" py 'import platform; platform.uname()'
measure "platform.architecture()" py 'import platform; platform.architecture()'
measure "platform.mac_ver()" py 'import platform; platform.mac_ver()'
measure "getconf LONG_BIT" getconf LONG_BIT
measure "ps -p 1 -o comm" ps -p 1 -o comm
measure "file -b python3" file -b "$(command -v python3)"
if [[ "$(uname)" == "Darwin" ]]; then
  measure "sw_vers -productVersion" /usr/bin/sw_vers -productVersion
  measure "sysctl -n kern.version" /sbin/sysctl -n kern.version
fi

echo "# ansible"
measure "ad-hoc ping (no facts)" ansible localhost --connection local --module-name ping
measure "ad-hoc ping, explicit interpreter (no discovery)" ansible localhost --connection local --module-name ping \
  --extra-vars "ansible_python_interpreter=$(command -v python3)"
measure "setup gather_subset=min" ansible localhost --connection local --module-name setup --args gather_subset=min
for collector in platform distribution service_mgr dns user env date_time python local ssh_pub_keys fips pkg_mgr lsb selinux apparmor caps cmdline; do
  measure "setup ${collector} collector only" ansible localhost --connection local --module-name setup \
    --args "gather_subset=!all,!min,${collector}"
done
for facts in false true; do
  printf -- '- hosts: localhost\n  connection: local\n  gather_facts: %s\n  gather_subset: [min]\n  tasks:\n    - ansible.builtin.ping:\n' \
    "$facts" > "${work}/play.yml"
  measure "playbook, gather_facts: ${facts}" ansible-playbook "${work}/play.yml"
done

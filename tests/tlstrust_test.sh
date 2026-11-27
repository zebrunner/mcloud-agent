#!/bin/bash
# patch/tlstrust.py: the certificate of MCloud the containers of STF trust, against a local https server with a
# self-signed certificate of localhost
source "$(dirname "$0")/lib.sh"
require_cmd python3
require_cmd openssl

# a configuration file, not -addext: the openssl of macOS is LibreSSL
printf '%s\n' '[req]' 'distinguished_name = dn' 'x509_extensions = ext' 'prompt = no' '[dn]' 'CN = localhost' '[ext]' \
  'subjectAltName = DNS:localhost' 'basicConstraints = critical, CA:TRUE' > "${WORK}/openssl.cnf"
run_check "a self-signed certificate of localhost" openssl req -x509 -newkey rsa:2048 -nodes -config "${WORK}/openssl.cnf" \
  -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" -days 2
pin="$(openssl x509 -in "${WORK}/cert.pem" -pubkey -noout | openssl pkey -pubin -outform der |
  openssl dgst -sha256 -binary | base64)"
# the server answers until the test ends (the cleanup of lib.sh removes WORK, the server stops with its file)
python3 - "$WORK" > "${WORK}/server.log" 2>&1 << 'PYTHON' &
import os, socketserver, ssl, sys, threading, time
work = sys.argv[1]
print("the server starts", flush=True)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(os.path.join(work, "cert.pem"), os.path.join(work, "key.pem"))
# a TCP server, not HTTPServer: its bind asks the DNS for the name of the address (slow on the macOS runners);
# tlstrust.py needs the TLS handshake only
server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), socketserver.BaseRequestHandler)
server.daemon_threads = True
server.socket = context.wrap_socket(server.socket, server_side=True)
open(os.path.join(work, "port"), "w").write(str(server.server_address[1]))
threading.Thread(target=server.serve_forever, daemon=True).start()
while os.path.exists(os.path.join(work, "cert.pem")):
    time.sleep(0.5)
PYTHON
for _ in $(seq 1 150); do
  [[ -s "${WORK}/port" ]] && break
  sleep 0.1
done
if [[ ! -s "${WORK}/port" ]]; then
  fail "the https server of the test" "no port" "$(cat "${WORK}/server.log")"
  finish
fi
port="$(cat "${WORK}/port")"

trust() {
  python3 "${REPO}/patch/tlstrust.py" "$@" 2>&1
  echo "rc=$?"
}

section "tlstrust.py"
check "the pinned self-signed certificate is printed" "-----BEGIN CERTIFICATE-----" "$(trust localhost "$port" "$pin" | sed -n 1p)"
check "it is the certificate of the server" "$(openssl x509 -in "${WORK}/cert.pem" -outform der | openssl dgst -sha256)" \
  "$(python3 "${REPO}/patch/tlstrust.py" localhost "$port" "$pin" | openssl x509 -outform der | openssl dgst -sha256)"
check_contains "another key is refused" "is not the pinned one of the join string" "$(trust localhost "$port" "AAAA${pin:4}")"
check_contains "a certificate of another host is refused" "is not valid for 127.0.0.1" "$(trust 127.0.0.1 "$port" "$pin")"
check_contains "no pin: no trust" "MCLOUD_TLS_PIN is empty" "$(trust localhost "$port" "")"
check_contains "a closed port" "is not reachable over https" "$(trust localhost 1 "$pin")"
check_contains "the errors exit with 1" "rc=1" "$(trust localhost "$port" "")"
check "the usage" "rc=2" "$(trust localhost | tail -n 1)"
check "an unknown option is the usage" "rc=2" "$(trust localhost "$port" "$pin" --pin | tail -n 1)"

section "tlstrust.py: the pin of the containers (STF_TLS_PIN)"
check "--pin-required: the pinned self-signed certificate is printed" "-----BEGIN CERTIFICATE-----" \
  "$(trust localhost "$port" "$pin" --pin-required | sed -n 1p)"
check_contains "--pin-required: another key is refused" "is not the pinned one of the join string" \
  "$(trust localhost "$port" "AAAA${pin:4}" --pin-required)"
check "--pin-only (STF_TLS_INSECURE): the pinned key of a certificate of another name passes, nothing is printed" "rc=0" \
  "$(trust 127.0.0.1 "$port" "$pin" --pin-only)"
check_contains "--pin-only: another key is refused" "is not the pinned one of the join string" \
  "$(trust 127.0.0.1 "$port" "AAAA${pin:4}" --pin-only)"
check "--pin-only without a pin checks nothing" "rc=0" "$(trust 127.0.0.1 "$port" "" --pin-only)"
check_contains "--pin-only: a closed port" "is not reachable over https" "$(trust localhost 1 "$pin" --pin-only)"
# a certificate of a public CA: publicly_trusted() of the module answers true for the server of the test
public() {
  python3 - "$@" 2>&1 << 'PYTHON'
import sys
sys.path.insert(0, sys.argv[1])
import tlstrust
tlstrust.publicly_trusted = lambda host, port: True
sys.exit(tlstrust.main(["tlstrust.py"] + sys.argv[2:]))
PYTHON
  echo "rc=$?"
}
check "a public CA: nothing is printed without --pin-required, whatever the key" "rc=0" \
  "$(public "${REPO}/patch" localhost "$port" "AAAA${pin:4}")"
check "a public CA and --pin-required: the pinned key passes, nothing is printed" "rc=0" \
  "$(public "${REPO}/patch" localhost "$port" "$pin" --pin-required)"
check_contains "a public CA and --pin-required: another key is refused" "(a certificate of a public CA) is not the pinned one" \
  "$(public "${REPO}/patch" localhost "$port" "AAAA${pin:4}" --pin-required)"
check "a public CA and --pin-required without a pin: as before" "rc=0" "$(public "${REPO}/patch" localhost "$port" "" --pin-required)"
rm -f "${WORK}/cert.pem"
finish

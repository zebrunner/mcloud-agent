#!/usr/bin/env python3
"""The certificate of MCloud the containers of STF trust (README.md#tls-of-mcloud).

Usage: tlstrust.py <host> <port> <pin>

Prints nothing when a public CA of this host signs the certificate of <host>:<port> for <host>: the containers trust it
already. Otherwise prints the certificates the server sends (PEM) when their key is the pinned one of the join string
(<pin>: sha256 of the public key in base64, MCLOUD_TLS_PIN) and they are valid for <host>, for NODE_EXTRA_CA_CERTS of
the containers. Exits with 1 and the reason on stderr for another key, a certificate of another host or no server.
"""

import base64
import hashlib
import socket
import ssl
import sys
import tempfile

TIMEOUT = 15


class TrustError(Exception):
    pass


def der_item(data, offset):
    """The (start of the content, end) of the DER item at offset."""
    if offset + 2 > len(data):
        raise TrustError("not a certificate: truncated")
    length = data[offset + 1]
    start = offset + 2
    if length & 0x80:
        count = length & 0x7F
        if count == 0 or count > 4 or start + count > len(data):
            raise TrustError("not a certificate: invalid length")
        length = int.from_bytes(data[start : start + count], "big")
        start += count
    end = start + length
    if end > len(data):
        raise TrustError("not a certificate: truncated")
    return start, end


def public_key_info(cert):
    """The DER of the SubjectPublicKeyInfo of a certificate: the key the pin of curl (--pinnedpubkey) hashes."""
    start, _ = der_item(cert, 0)  # Certificate
    start, end = der_item(cert, start)  # tbsCertificate
    offset = start
    fields = []
    while offset < end:
        item_start, item_end = der_item(cert, offset)
        fields.append((cert[offset], offset, item_end))
        offset = item_end
    # [0] version is optional: serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo
    if fields and fields[0][0] == 0xA0:
        fields = fields[1:]
    if len(fields) < 6 or fields[5][0] != 0x30:
        raise TrustError("not a certificate: no public key")
    _, key_start, key_end = fields[5]
    return cert[key_start:key_end]


def pin_of(cert):
    return base64.b64encode(hashlib.sha256(public_key_info(cert)).digest()).decode()


def connect(host, port, context):
    with (
        socket.create_connection((host, port), timeout=TIMEOUT) as sock,
        context.wrap_socket(sock, server_hostname=host) as tls,
    ):
        leaf = tls.getpeercert(binary_form=True)
        chain = tls.get_unverified_chain() if hasattr(tls, "get_unverified_chain") else None
        return [bytes(cert) for cert in (chain or [leaf])]


def publicly_trusted(host, port):
    try:
        connect(host, port, ssl.create_default_context())
        return True
    except ssl.SSLCertVerificationError:
        return False


def pem(certs):
    return "".join(ssl.DER_cert_to_PEM_cert(cert) for cert in certs)


def trusted_with(host, port, chain):
    """Whether the server is valid for host with the chain as the only trusted certificates."""
    with tempfile.NamedTemporaryFile("w", suffix=".pem") as cafile:
        cafile.write(chain)
        cafile.flush()
        context = ssl.create_default_context(cafile=cafile.name)
        try:
            connect(host, port, context)
            return True
        except ssl.SSLCertVerificationError as err:
            raise TrustError(
                f"the pinned certificate of {host}:{port} is not valid for {host} ({err.verify_message}): use the "
                "name or the address of the certificate in PUBLIC_IP, or set STF_TLS_INSECURE: true "
                "(README.md#tls-of-mcloud)"
            ) from err


def certificate(host, port, pin):
    """The PEM to trust: empty for a certificate of a public CA, the pinned chain otherwise."""
    try:
        if publicly_trusted(host, port):
            return ""
        unverified = ssl.create_default_context()
        unverified.check_hostname = False
        unverified.verify_mode = ssl.CERT_NONE
        certs = connect(host, port, unverified)
    except (OSError, ssl.SSLError) as err:
        raise TrustError(f"MCloud {host}:{port} is not reachable over https: {err}") from err
    if not pin:
        raise TrustError(
            f"the certificate of {host}:{port} is not of a public CA and MCLOUD_TLS_PIN is empty: ./zebrunner.sh join, "
            "or set STF_TLS_INSECURE: true (README.md#tls-of-mcloud)"
        )
    if pin_of(certs[0]) != pin:
        raise TrustError(
            f"the TLS key of {host}:{port} is not the pinned one of the join string (MCLOUD_TLS_PIN): another server "
            "or a man in the middle"
        )
    chain = pem(certs)
    trusted_with(host, port, chain)
    return chain


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    _, host, port, pin = argv
    try:
        sys.stdout.write(certificate(host, int(port), pin.strip()))
    except (TrustError, ValueError) as err:
        print(err, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

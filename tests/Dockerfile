# Linux environment of the tests and linters, e.g. to run them on macOS:
#   docker build -t mcloud-agent-tests tests
#   docker run --rm -v "$PWD":/repo:ro mcloud-agent-tests bash -c '/repo/tests/lint.sh && /repo/tests/run_all.sh'
FROM ubuntu:24.04
COPY requirements-lint.txt /tmp/requirements-lint.txt
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 python3-venv bsdextrautils procps ca-certificates \
 && python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --quiet --no-cache-dir -r /tmp/requirements-lint.txt \
 && mkdir -p /etc/udev/rules.d \
 && rm -rf /var/lib/apt/lists/*
ENV PATH=/opt/venv/bin:$PATH

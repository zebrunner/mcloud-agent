# Project checks; `make check` runs the linters and all tests on this machine, then in the Linux docker image
SHELL := /bin/bash
VENV := .venv
export PATH := $(CURDIR)/$(VENV)/bin:$(PATH)

.DEFAULT_GOAL := help
.PHONY: help check lint test docker

help: ## this list
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/'

check: lint test docker ## the linters and all tests on this machine, then in the Linux docker image

lint: $(VENV)/.installed ## the linters (tests/lint.sh)
	tests/lint.sh

test: $(VENV)/.installed ## all tests (tests/run_all.sh), the tests of another OS skip themselves
	tests/run_all.sh

docker: ## the linters and all tests in the Linux image of tests/Dockerfile (Linux branches on macOS)
	docker build --quiet --tag mcloud-agent-tests tests
	docker run --rm --volume "$(CURDIR)":/repo:ro mcloud-agent-tests bash -c '/repo/tests/lint.sh && /repo/tests/run_all.sh'

# The tools of tests/requirements-lint.txt in .venv; the hadolint-py wheel for macOS is broken, brew provides it there
$(VENV)/.installed: tests/requirements-lint.txt
	python3 -m venv $(VENV)
	@if [[ "$$(uname)" == Darwin ]]; then \
	  grep -v '^hadolint-py' tests/requirements-lint.txt > $(VENV)/requirements.txt; \
	else \
	  cp tests/requirements-lint.txt $(VENV)/requirements.txt; \
	fi
	$(VENV)/bin/pip install --quiet --disable-pip-version-check --requirement $(VENV)/requirements.txt
	@command -v hadolint > /dev/null || { echo "hadolint is missing: brew install hadolint"; exit 1; }
	touch $@

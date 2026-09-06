# Makefile — the dozers repo's own test command.
#
# The dev lane's test gate (GSAI-27) looks for a `test` script in package.json or a
# `test:` target here. This repo is bash + python with no package manager, so before
# GSAI-30 it had neither: the harness that blocks ungated merges could not clear its
# own gate, and every dozers task would have landed on dozer:blocked. This target is
# that command — it runs the whole regression suite and exits non-zero if any test
# fails. Keep it working; the repo is deliberately NOT opted out of its own gate.

SHELL := /usr/bin/env bash

.PHONY: test
test:                       ## run the full regression suite (tests/*-test.sh)
	@bash tests/run-all.sh

.PHONY: help
help:
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  %-10s %s\n", $$1, $$2}'

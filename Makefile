SHELL := /usr/bin/env bash

IMAGE ?= localhost/coolify-bootc-worker:dev

.PHONY: build build-worker lint test validate clean

build: build-worker

build-worker:
	IMAGE_NAME=$(IMAGE) ./scripts/build.sh worker

lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck is required" >&2; exit 1; }
	shellcheck scripts/*.sh tests/*.sh

test:
	./tests/test-image.sh
	./tests/test-worker.sh

validate: lint test
	./scripts/validate-image.sh $(IMAGE)

clean:
	@echo "No build artifacts are written to the repository. Remove $(IMAGE) with your container engine if desired."

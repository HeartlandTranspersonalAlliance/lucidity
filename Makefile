SHELL := /usr/bin/env bash

IMAGE ?= localhost/coolify-bootc-worker:dev

.PHONY: build build-worker lint test validate image-worker ami-worker validate-disk-worker vm-init-worker vm-start-worker vm-validate-worker vm-stop-worker vm-clean-worker clean

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

image-worker: build-worker
	IMAGE_NAME=$(IMAGE) ./scripts/build-disk.sh worker qcow2

ami-worker: build-worker
	IMAGE_NAME=$(IMAGE) ./scripts/build-disk.sh worker ami

validate-disk-worker:
	./scripts/validate-disk.sh image-output/worker/coolify-worker-qcow2.qcow2

vm-init-worker:
	./scripts/vm-init.sh worker

vm-start-worker:
	./scripts/vm-start.sh

vm-validate-worker:
	./scripts/vm-validate.sh

vm-stop-worker:
	./scripts/vm-stop.sh

vm-clean-worker: vm-stop-worker
	@if test -d image-output/vm; then \
		find image-output/vm -mindepth 1 -maxdepth 1 -type f -delete; \
	fi

clean:
	@echo "Images and image-output/ artifacts are retained intentionally; remove explicit targets with your container tooling when desired."

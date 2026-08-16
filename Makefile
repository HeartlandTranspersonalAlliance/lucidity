SHELL := /usr/bin/env bash

IMAGE ?= localhost/coolify-bootc-worker:dev
CONTROLLER_IMAGE ?= localhost/coolify-bootc-controller:dev
TOFU_DIR ?= tofu/environments/aws

.PHONY: build build-controller build-worker lint test validate validate-controller image-controller image-worker ami-controller ami-worker validate-disk-controller validate-disk-worker vm-init-controller vm-init-worker vm-start-controller vm-start-worker vm-validate-controller vm-validate-worker vm-registry-start-controller vm-registry-start-worker vm-update-rollback-controller vm-update-rollback-worker vm-registry-stop-controller vm-registry-stop-worker vm-stop-controller vm-stop-worker vm-clean-controller vm-clean-worker tofu-fmt tofu-fmt-check tofu-init tofu-validate tofu-test tofu-check clean

build: build-worker

build-controller:
	IMAGE_NAME=$(CONTROLLER_IMAGE) ./scripts/build.sh controller

build-worker:
	IMAGE_NAME=$(IMAGE) ./scripts/build.sh worker

lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck is required" >&2; exit 1; }
	shellcheck scripts/*.sh tests/*.sh

test:
	./tests/test-image.sh
	./tests/test-ami-import.sh
	./tests/test-controller.sh
	./tests/test-worker.sh

validate: lint test
	./scripts/validate-image.sh $(IMAGE)

validate-controller: lint test
	./scripts/validate-image.sh $(CONTROLLER_IMAGE)

image-controller: build-controller
	IMAGE_NAME=$(CONTROLLER_IMAGE) ./scripts/build-disk.sh controller qcow2

image-worker: build-worker
	IMAGE_NAME=$(IMAGE) ./scripts/build-disk.sh worker qcow2

ami-controller: build-controller
	IMAGE_NAME=$(CONTROLLER_IMAGE) ./scripts/build-disk.sh controller ami

ami-worker: build-worker
	IMAGE_NAME=$(IMAGE) ./scripts/build-disk.sh worker ami

validate-disk-controller:
	./scripts/validate-disk.sh image-output/controller/coolify-controller-qcow2.qcow2

validate-disk-worker:
	./scripts/validate-disk.sh image-output/worker/coolify-worker-qcow2.qcow2

vm-init-controller:
	./scripts/vm-init.sh controller

vm-init-worker:
	./scripts/vm-init.sh worker

vm-start-controller:
	./scripts/vm-start.sh controller

vm-start-worker:
	./scripts/vm-start.sh worker

vm-validate-controller:
	./scripts/vm-validate.sh controller

vm-validate-worker:
	./scripts/vm-validate.sh worker

vm-registry-start-controller:
	./scripts/vm-registry.sh start controller

vm-registry-start-worker:
	./scripts/vm-registry.sh start worker

vm-update-rollback-controller:
	./scripts/vm-validate-update.sh controller

vm-update-rollback-worker:
	./scripts/vm-validate-update.sh worker

vm-registry-stop-controller:
	./scripts/vm-registry.sh stop controller

vm-registry-stop-worker:
	./scripts/vm-registry.sh stop worker

vm-stop-controller:
	./scripts/vm-stop.sh controller

vm-stop-worker:
	./scripts/vm-stop.sh worker

vm-clean-controller: vm-stop-controller
	@if test -d image-output/vm-controller; then \
		find image-output/vm-controller -mindepth 1 -maxdepth 1 -type f -delete; \
	fi

vm-clean-worker: vm-stop-worker
	@if test -d image-output/vm; then \
		find image-output/vm -mindepth 1 -maxdepth 1 -type f -delete; \
	fi

tofu-fmt:
	tofu fmt -recursive tofu

tofu-fmt-check:
	tofu fmt -check -recursive tofu

tofu-init:
	tofu -chdir=$(TOFU_DIR) init -backend=false

tofu-validate: tofu-init
	tofu -chdir=$(TOFU_DIR) validate

tofu-test: tofu-init
	tofu -chdir=$(TOFU_DIR) test

tofu-check: tofu-fmt-check tofu-validate tofu-test

clean:
	@echo "Images and image-output/ artifacts are retained intentionally; remove explicit targets with your container tooling when desired."

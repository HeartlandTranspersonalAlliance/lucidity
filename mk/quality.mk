style:
	@command -v codespell >/dev/null || { echo "codespell is required" >&2; exit 1; }
	git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD
	bash ./scripts/check-text-style.sh
	codespell

lint: style
	@command -v shellcheck >/dev/null || { echo "shellcheck is required" >&2; exit 1; }
	shellcheck scripts/*.sh tests/*.sh

test:
	bash ./tests/test-text-style.sh
	./tests/test-image.sh
	./tests/test-ami-import.sh
	./tests/test-ami-resource-audit.sh
	./tests/test-deployment-validation.sh
	./tests/test-controller.sh
	./tests/test-worker.sh

.DEFAULT_GOAL := help

.PHONY: clean help image/build image/extract image/test bundle/tar lint setup

##@ Bootstrap & Build

setup: ## Install local Git hook scripts
	uvx pre-commit install

image/build: ## Build the scratch container image containing the portable files
	podman build -t flm-portable-scratch -f Containerfile .

image/extract: ## Extract the portable files from the built container image to the workspace
	rm -rf bin lib64 share flm-wrapper
	mkdir -p bin lib64 share
	podman create --name flm-portable-extract localhost/flm-portable-scratch:latest
	podman cp flm-portable-extract:/bin/. bin/
	podman cp flm-portable-extract:/lib64/. lib64/
	podman cp flm-portable-extract:/share/. share/
	podman cp flm-portable-extract:/flm-wrapper flm-wrapper
	podman rm flm-portable-extract

##@ Development & Testing

lint: ## Lint staged files using pre-commit hooks
	uvx pre-commit run --all-files

image/test: ## Run the flm help command inside a clean Fedora container to verify libraries
	podman run --rm -v $(PWD):/workspace:z registry.fedoraproject.org/fedora:44 /workspace/flm-wrapper --help

bundle/tar: ## Create the compressed distribution tarball (excluding source/git files)
	tar -czf ../flm-portable.tar.gz --exclude=.git --exclude=.github --exclude=.pre-commit-config.yaml --exclude=Containerfile --exclude=Makefile --exclude=README.md -C .. flm-portable

clean: ## Remove build outputs from the workspace
	rm -rf bin lib64 share flm-wrapper

##@ Utilities

help: ## Show this help menu
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	  /^[a-zA-Z0-9_/-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

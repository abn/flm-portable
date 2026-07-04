.DEFAULT_GOAL := help

.PHONY: clean help image/build image/extract image/test bundle/tar lint setup

##@ Bootstrap & Build

setup: ## Install local Git hook scripts
	uvx pre-commit install

image/build: ## Build the scratch container image containing the portable files
	podman build -t flm-portable-scratch -f Containerfile .

image/extract: ## Extract the portable files from the built container image to the workspace under dist/
	rm -rf dist
	mkdir -p dist
	podman create --name flm-portable-extract localhost/flm-portable-scratch:latest
	podman cp flm-portable-extract:/usr dist/
	podman rm flm-portable-extract
	# Create relative root-level symlinks for backward compatibility
	cd dist && ln -s usr/bin bin \
		&& ln -s usr/lib64 lib64 \
		&& ln -s usr/share share \
		&& ln -s usr/bin/flm flm

##@ Development & Testing

lint: ## Lint staged files using pre-commit hooks
	uvx pre-commit run --all-files

image/test: ## Run the flm help command inside a clean Fedora container to verify libraries in dist/
	podman run --rm -v $(PWD):/workspace:z registry.fedoraproject.org/fedora:44 /workspace/dist/flm --help

bundle/tar: ## Create the compressed distribution tarball from dist/ (wrapped in flm-portable/)
	rm -rf /tmp/flm-portable
	mkdir -p /tmp/flm-portable
	cp -rp dist/* /tmp/flm-portable/
	tar -czf flm-portable.tar.gz -C /tmp flm-portable
	rm -rf /tmp/flm-portable

clean: ## Remove build outputs from the workspace
	rm -rf dist flm-portable.tar.gz

##@ Utilities

help: ## Show this help menu
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	  /^[a-zA-Z0-9_/-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

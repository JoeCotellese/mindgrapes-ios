# ABOUTME: Entry points for building and testing MindGrapes.
# ABOUTME: `make test` is the loop signal; it needs no simulator or server.

SIMULATOR ?= platform=iOS Simulator,name=iPhone 17 Pro
REPEAT ?= 5

# The app needs the iOS 27 SDK for the `.notes.createNote` app schema. Pinning
# Xcode here rather than trusting `xcode-select` keeps builds on 27 even when the
# machine's active developer directory points somewhere else.
# ponytail: one variable, no toolchain-detection logic; override on the command
# line (`make build DEVELOPER_DIR=...`) if Xcode lives elsewhere.
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.PHONY: test
test: ## Run the MindGrapesKit unit suite on the host (no simulator needed)
	cd MindGrapesKit && swift test

.PHONY: test-repeat
test-repeat: ## Run the unit suite $(REPEAT) times to surface flaky failures
	cd MindGrapesKit && swift build --build-tests
	# `--no-parallel` is the gate's insurance against the SPEC 4.3 segfault:
	# concurrent ModelContainer schema setup crashes CoreData, and serial
	# execution removes the concurrency that triggers it. This is a test-harness
	# artifact (the app builds one container, once), so it hides nothing real.
	@i=1; while [ $$i -le $(REPEAT) ]; do \
		echo "--- run $$i of $(REPEAT) ---"; \
		(cd MindGrapesKit && swift test --skip-build --no-parallel) || exit 1; \
		i=$$((i + 1)); \
	done

.PHONY: build-kit
build-kit: ## Build the package for the host, iOS, and watchOS
	cd MindGrapesKit && swift build
	cd MindGrapesKit && xcodebuild -scheme MindGrapesKit \
		-destination 'generic/platform=iOS' -derivedDataPath .build/xcode build
	cd MindGrapesKit && xcodebuild -scheme MindGrapesKit \
		-destination 'generic/platform=watchOS' -derivedDataPath .build/xcode build

.PHONY: hooks
hooks: ## Install the local git hooks (run once per clone)
	git config core.hooksPath .githooks

.PHONY: generate
generate: ## Regenerate MindGrapes.xcodeproj from project.yml
	xcodegen generate

.PHONY: build
build: generate ## Build the app for the simulator
	xcodebuild -project MindGrapes.xcodeproj -scheme MindGrapes \
		-destination '$(SIMULATOR)' \
		CODE_SIGNING_ALLOWED=NO build

# An upload can't be taken back, and the build number is the commit count, so a
# release must come from a committed tree that passes the suite. test-repeat is
# the same serial gate the pre-push hook runs; check-clean goes first so a dirty
# tree fails before any tests run.
.PHONY: check-clean
check-clean: ## Fail if the working tree has uncommitted or untracked changes
	@[ -z "$$(git status --porcelain)" ] || { \
		echo "error: working tree is not clean; commit or stash before releasing" >&2; \
		git status --short >&2; exit 1; }

# Recipes run under /bin/sh, so sourcing .env here works from any login shell.
LOAD_ENV = if [ -f .env ]; then set -a; . ./.env; set +a; fi

.PHONY: release-validate
release-validate: check-clean test-repeat generate ## Archive and validate against App Store Connect (no submit; needs .env)
	@$(LOAD_ENV); VALIDATE=1 ./scripts/appstore-upload.sh

.PHONY: release
release: check-clean test-repeat generate ## Archive, export, and upload the app to App Store Connect (needs .env)
	@$(LOAD_ENV); ./scripts/appstore-upload.sh

.PHONY: devices
devices: ## List connected devices and their identifiers
	xcrun devicectl list devices

.PHONY: device
device: generate ## Build signed and install on a device (DEVICE="Development iPhone")
	./scripts/install-device.sh

.PHONY: clean
clean:
	rm -rf .build MindGrapesKit/.build DerivedData MindGrapes.xcodeproj

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

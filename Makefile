# ABOUTME: Entry points for building and testing MindGrapes.
# ABOUTME: `make test` is the loop signal; it needs no simulator or server.

SIMULATOR ?= platform=iOS Simulator,name=iPhone 17 Pro
REPEAT ?= 5

.PHONY: test
test: ## Run the MindGrapesKit unit suite on the host (no simulator needed)
	cd MindGrapesKit && swift test

.PHONY: test-repeat
test-repeat: ## Run the unit suite $(REPEAT) times to surface flaky failures
	cd MindGrapesKit && swift build --build-tests
	@i=1; while [ $$i -le $(REPEAT) ]; do \
		echo "--- run $$i of $(REPEAT) ---"; \
		(cd MindGrapesKit && swift test --skip-build) || exit 1; \
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

.PHONY: clean
clean:
	rm -rf .build MindGrapesKit/.build DerivedData MindGrapes.xcodeproj

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

APP_NAME      := ScreenLock
SCHEME        := $(APP_NAME)
WORKSPACE     := $(APP_NAME).xcworkspace
CONFIGURATION := Release
BUILD_DIR     := build
APP_PATH      := $(BUILD_DIR)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app
INSTALL_DIR   := $(HOME)/Applications

TUIST ?= tuist

.DEFAULT_GOAL := help
.PHONY: help install-tuist generate edit build install uninstall clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

install-tuist: ## Install Tuist (via mise or Homebrew) if missing
	@if command -v $(TUIST) >/dev/null 2>&1; then \
		echo "Tuist already installed: $$($(TUIST) version)"; \
	elif command -v mise >/dev/null 2>&1; then \
		mise use --global tuist@latest; \
	elif command -v brew >/dev/null 2>&1; then \
		brew install --formula tuist; \
	else \
		echo "Neither mise nor Homebrew found: see https://docs.tuist.dev/en/guides/quick-start/install-tuist" >&2; \
		exit 1; \
	fi

generate: ## Generate ScreenLock.xcodeproj / .xcworkspace with Tuist
	$(TUIST) generate --no-open

edit: ## Open the Tuist manifests in Xcode
	$(TUIST) edit

build: generate ## Build the Release configuration into ./build
	xcodebuild \
		-workspace $(WORKSPACE) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination 'platform=macOS' \
		-derivedDataPath $(BUILD_DIR) \
		build
	@echo "App built: $(APP_PATH)"

install: build ## Install the Release app into ~/Applications
	@if pgrep -x $(APP_NAME) >/dev/null; then \
		echo "$(APP_NAME) is running: quit it before installing." >&2; \
		exit 1; \
	fi
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	ditto "$(APP_PATH)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

uninstall: ## Remove the app from ~/Applications
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"

clean: ## Remove build output and the generated project
	rm -rf $(BUILD_DIR) Derived $(APP_NAME).xcodeproj $(WORKSPACE)

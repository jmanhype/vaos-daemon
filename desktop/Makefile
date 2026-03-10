# =============================================================================
# OSA Desktop — Makefile
# Standard targets for building, packaging, and maintaining OSA Desktop.
# Requires: node >= 18, cargo (Rust stable), npm
# =============================================================================

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
APP_NAME    := OSA
VERSION     := $(shell node -p "require('./package.json').version" 2>/dev/null || echo "0.0.0")
OS          := $(shell uname -s 2>/dev/null || echo "Windows")
ARCH        := $(shell uname -m 2>/dev/null || echo "x86_64")

# Directories
BUNDLE_DIR  := src-tauri/target/release/bundle
BUILD_DIR   := build

# Tooling (use local npm binaries when available)
NPM         := npm
TAURI       := $(NPM) run tauri --
SVELTE_KIT  := node_modules/.bin/svelte-kit
SVELTE_CHK  := node_modules/.bin/svelte-check

# Colours (only when stdout is a terminal)
ifeq ($(shell [ -t 1 ] && echo yes),yes)
  BOLD  := \033[1m
  GREEN := \033[0;32m
  CYAN  := \033[0;36m
  RESET := \033[0m
else
  BOLD :=
  GREEN :=
  CYAN :=
  RESET :=
endif

# --------------------------------------------------------------------------- #
# Phony declarations
# --------------------------------------------------------------------------- #
.PHONY: all help dev build build-debug check lint format clean install \
        package package-macos package-linux package-windows \
        deps cargo-fetch doctor

# --------------------------------------------------------------------------- #
# Default target
# --------------------------------------------------------------------------- #
all: help

help:
	@printf "$(BOLD)OSA Desktop v$(VERSION) — available targets$(RESET)\n\n"
	@printf "  $(CYAN)%-20s$(RESET) %s\n" "make dev"             "Start development server with hot-reload"
	@printf "  $(CYAN)%-20s$(RESET) %s\n" "make build"           "Production build (Tauri + SvelteKit)"
	@printf "  $(CYAN)%-20s$(RESET) %s\n" "make build-debug"     "Debug build (includes debug symbols)"
	@printf "  $(CYAN)%-20s$(RESET) %s\n" "make check"           "Run svelte-check + cargo check + clippy"
	@printf "  $(CYAN)%-20s$(RESET) %s\n" "make lint"            "Run prettier + eslint"
	@printf "  $(CYAN)%-20s$(RESET) %s\n" "make format"          "Auto-format all files"
	@printf "  $(CYAN)%-20s$(RESET) %s\n" "make clean"           "Remove all build artifacts"
	@printf "  $(CYAN)%-20s$(RESET) %s\n" "make install"         "Install app on the current platform"
	@printf "  $(CYAN)%-20s$(RESET) %s\n" "make package"         "Create distributable for current platform"
	@printf "  $(CYAN)%-20s$(RESET) %s\n" "make deps"            "Install all dependencies (npm + cargo fetch)"
	@printf "  $(CYAN)%-20s$(RESET) %s\n" "make doctor"          "Verify all build prerequisites"
	@printf "\n"

# --------------------------------------------------------------------------- #
# Development
# --------------------------------------------------------------------------- #
dev: node_modules
	@printf "$(BOLD)Starting OSA Desktop in dev mode...$(RESET)\n"
	$(NPM) run tauri:dev

# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #
node_modules: package.json package-lock.json
	@printf "$(BOLD)Installing npm dependencies...$(RESET)\n"
	$(NPM) ci --prefer-offline
	@touch node_modules  # update timestamp so make knows deps are fresh

build: node_modules
	@printf "$(BOLD)Building OSA Desktop $(VERSION) (release)...$(RESET)\n"
	$(NPM) run tauri:build
	@printf "$(GREEN)Build complete. Artifacts: $(BUNDLE_DIR)/$(RESET)\n"

build-debug: node_modules
	@printf "$(BOLD)Building OSA Desktop $(VERSION) (debug)...$(RESET)\n"
	$(NPM) run tauri:build:debug
	@printf "$(GREEN)Debug build complete.$(RESET)\n"

# --------------------------------------------------------------------------- #
# Quality checks
# --------------------------------------------------------------------------- #
check: node_modules
	@printf "$(BOLD)Running svelte-check...$(RESET)\n"
	$(NPM) run check
	@printf "$(BOLD)Running cargo check...$(RESET)\n"
	cd src-tauri && cargo check
	@printf "$(BOLD)Running cargo clippy...$(RESET)\n"
	cd src-tauri && cargo clippy -- -D warnings
	@printf "$(GREEN)All checks passed.$(RESET)\n"

lint: node_modules
	@printf "$(BOLD)Linting (prettier + eslint)...$(RESET)\n"
	$(NPM) run lint

format: node_modules
	@printf "$(BOLD)Formatting all files...$(RESET)\n"
	$(NPM) run format

# --------------------------------------------------------------------------- #
# Clean
# --------------------------------------------------------------------------- #
clean:
	@printf "$(BOLD)Cleaning build artifacts...$(RESET)\n"
	rm -rf $(BUILD_DIR)
	rm -rf src-tauri/target
	rm -rf src-tauri/gen
	@printf "$(GREEN)Clean complete.$(RESET)\n"

clean-js:
	@printf "$(BOLD)Cleaning JS artifacts only...$(RESET)\n"
	rm -rf $(BUILD_DIR)
	rm -rf node_modules
	@printf "$(GREEN)Done.$(RESET)\n"

# --------------------------------------------------------------------------- #
# Dependencies
# --------------------------------------------------------------------------- #
deps: node_modules cargo-fetch

cargo-fetch:
	@printf "$(BOLD)Pre-fetching Rust crates...$(RESET)\n"
	cd src-tauri && cargo fetch
	@printf "$(GREEN)Cargo fetch complete.$(RESET)\n"

# --------------------------------------------------------------------------- #
# Install (platform-aware)
# --------------------------------------------------------------------------- #
install: build
ifeq ($(OS),Darwin)
	@printf "$(BOLD)Installing $(APP_NAME) to /Applications/...$(RESET)\n"
	@APP=$$(find $(BUNDLE_DIR)/macos -name "*.app" -maxdepth 1 | head -1); \
	if [ -z "$$APP" ]; then echo "No .app bundle found in $(BUNDLE_DIR)/macos/"; exit 1; fi; \
	rm -rf "/Applications/$$(basename $$APP)"; \
	cp -r "$$APP" /Applications/; \
	printf "$(GREEN)Installed: /Applications/$$(basename $$APP)$(RESET)\n"
else ifeq ($(OS),Linux)
	@printf "$(BOLD)Installing $(APP_NAME) AppImage to ~/.local/bin/...$(RESET)\n"
	@APPIMAGE=$$(find $(BUNDLE_DIR)/appimage -name "*.AppImage" -maxdepth 1 | head -1); \
	if [ -z "$$APPIMAGE" ]; then echo "No .AppImage found in $(BUNDLE_DIR)/appimage/"; exit 1; fi; \
	mkdir -p $(HOME)/.local/bin; \
	cp "$$APPIMAGE" $(HOME)/.local/bin/osa; \
	chmod +x $(HOME)/.local/bin/osa; \
	printf "$(GREEN)Installed: $(HOME)/.local/bin/osa$(RESET)\n"
else
	@printf "Windows install: run the generated .msi from $(BUNDLE_DIR)/msi/\n"
endif

# --------------------------------------------------------------------------- #
# Package (create distributable artifacts)
# --------------------------------------------------------------------------- #
package: build
ifeq ($(OS),Darwin)
	$(MAKE) package-macos
else ifeq ($(OS),Linux)
	$(MAKE) package-linux
else
	$(MAKE) package-windows
endif

package-macos: build
	@printf "$(BOLD)Packaging for macOS...$(RESET)\n"
	@ls -la $(BUNDLE_DIR)/macos/ 2>/dev/null || echo "No macOS bundle found"
	@ls -la $(BUNDLE_DIR)/dmg/  2>/dev/null || echo "No .dmg found"
	@printf "$(GREEN)macOS artifacts ready in $(BUNDLE_DIR)/$(RESET)\n"

package-linux: build
	@printf "$(BOLD)Packaging for Linux...$(RESET)\n"
	@ls -la $(BUNDLE_DIR)/appimage/ 2>/dev/null || echo "No AppImage found"
	@ls -la $(BUNDLE_DIR)/deb/      2>/dev/null || echo "No .deb found"
	@ls -la $(BUNDLE_DIR)/rpm/      2>/dev/null || echo "No .rpm found"
	@printf "$(GREEN)Linux artifacts ready in $(BUNDLE_DIR)/$(RESET)\n"

package-windows: build
	@printf "$(BOLD)Packaging for Windows...$(RESET)\n"
	@ls -la $(BUNDLE_DIR)/msi/  2>/dev/null || echo "No .msi found"
	@ls -la $(BUNDLE_DIR)/nsis/ 2>/dev/null || echo "No NSIS installer found"
	@printf "$(GREEN)Windows artifacts ready in $(BUNDLE_DIR)/$(RESET)\n"

# --------------------------------------------------------------------------- #
# Doctor — verify prerequisites
# --------------------------------------------------------------------------- #
doctor:
	@printf "$(BOLD)Checking OSA Desktop prerequisites...$(RESET)\n\n"
	@# Node.js
	@if command -v node >/dev/null 2>&1; then \
	  printf "  $(GREEN)[OK]$(RESET)   node:  $$(node --version)\n"; \
	else \
	  printf "  \033[0;31m[FAIL]\033[0m node:  not found (install Node.js >= 18)\n"; \
	fi
	@# npm
	@if command -v npm >/dev/null 2>&1; then \
	  printf "  $(GREEN)[OK]$(RESET)   npm:   $$(npm --version)\n"; \
	else \
	  printf "  \033[0;31m[FAIL]\033[0m npm:   not found\n"; \
	fi
	@# Rust
	@if command -v rustc >/dev/null 2>&1; then \
	  printf "  $(GREEN)[OK]$(RESET)   rustc: $$(rustc --version)\n"; \
	else \
	  printf "  \033[0;31m[FAIL]\033[0m rustc: not found (install via rustup.rs)\n"; \
	fi
	@# cargo
	@if command -v cargo >/dev/null 2>&1; then \
	  printf "  $(GREEN)[OK]$(RESET)   cargo: $$(cargo --version)\n"; \
	else \
	  printf "  \033[0;31m[FAIL]\033[0m cargo: not found\n"; \
	fi
	@# git
	@if command -v git >/dev/null 2>&1; then \
	  printf "  $(GREEN)[OK]$(RESET)   git:   $$(git --version)\n"; \
	else \
	  printf "  \033[0;31m[FAIL]\033[0m git:   not found\n"; \
	fi
	@# Platform-specific
	@if [ "$(OS)" = "Darwin" ]; then \
	  if xcode-select -p >/dev/null 2>&1; then \
	    printf "  $(GREEN)[OK]$(RESET)   Xcode CLT: present\n"; \
	  else \
	    printf "  \033[0;31m[FAIL]\033[0m Xcode CLT: not found (run: xcode-select --install)\n"; \
	  fi; \
	elif [ "$(OS)" = "Linux" ]; then \
	  if pkg-config --exists webkit2gtk-4.1 2>/dev/null || pkg-config --exists webkit2gtk-4.0 2>/dev/null; then \
	    printf "  $(GREEN)[OK]$(RESET)   WebKit2GTK: present\n"; \
	  else \
	    printf "  \033[0;31m[WARN]\033[0m WebKit2GTK: not found (install libwebkit2gtk-4.1-dev)\n"; \
	  fi; \
	fi
	@printf "\n"

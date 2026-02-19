SHELL = /bin/bash
APP_NAME = WisperKbd
VERSION = 0.1.0
SCHEME = $(APP_NAME)
PROJECT = $(APP_NAME).xcodeproj
CONFIG = Debug
INSTALL_DIR = $(HOME)/Library/Input Methods
DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData
BUILD_DIR = $(shell ls -d $(DERIVED_DATA)/$(APP_NAME)-* 2>/dev/null | head -1)/Build/Products/$(CONFIG)
RELEASE_BUILD_DIR = $(shell ls -d $(DERIVED_DATA)/$(APP_NAME)-* 2>/dev/null | head -1)/Build/Products/Release
PKG_DIR = dist
PKG_FILE = $(PKG_DIR)/$(APP_NAME)-$(VERSION).pkg

.PHONY: generate build install run clean uninstall

# Generate Xcode project from project.yml
generate:
	xcodegen generate

# Build the project
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		build -destination 'platform=macOS' \
		2>&1 | grep -E "(error:|warning:|BUILD)" | grep -v "appintentsmetadataprocessor"

# Kill running instance, build, and install
install: build
	@killall $(APP_NAME) 2>/dev/null || true
	@sleep 0.5
	@mkdir -p "$(INSTALL_DIR)"
	cp -R "$(BUILD_DIR)/$(APP_NAME).app" "$(INSTALL_DIR)/"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"
	@echo "If first install: System Settings > Keyboard > Input Sources > + > $(APP_NAME)"

# Build, install, and launch
run: install
	@echo "Launching $(APP_NAME)..."
	@open "$(INSTALL_DIR)/$(APP_NAME).app"

# Clean build artifacts
clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true
	@echo "Cleaned build artifacts"

# Remove from Input Methods
uninstall:
	@killall $(APP_NAME) 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Uninstalled $(APP_NAME) from $(INSTALL_DIR)"

# --- Distribution ---

# Build release version
release:
	xcodegen generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		build -destination 'platform=macOS' \
		2>&1 | grep -E "(error:|warning:|BUILD)" | grep -v "appintentsmetadataprocessor"

# Create ZIP for distribution (requires release build)
dist: release
	@RELEASE_DIR=$$(ls -d $(DERIVED_DATA)/$(APP_NAME)-*/Build/Products/Release 2>/dev/null | head -1); \
	if [ -z "$$RELEASE_DIR" ]; then echo "ERROR: Release build not found"; exit 1; fi; \
	cd "$$RELEASE_DIR" && \
	ditto -c -k --keepParent $(APP_NAME).app $(APP_NAME).zip && \
	echo "Created $$RELEASE_DIR/$(APP_NAME).zip"

# Create .pkg installer (installs to /Library/Input Methods/)
pkg: release
	@mkdir -p $(PKG_DIR)
	@rm -rf $(PKG_DIR)/payload
	@mkdir -p "$(PKG_DIR)/payload/Library/Input Methods"
	cp -R "$(RELEASE_BUILD_DIR)/$(APP_NAME).app" "$(PKG_DIR)/payload/Library/Input Methods/"
	pkgbuild \
		--root "$(PKG_DIR)/payload" \
		--scripts pkg/scripts \
		--identifier com.tomasen.inputmethod.WisperKbd \
		--version $(VERSION) \
		--install-location / \
		"$(PKG_FILE)"
	@rm -rf $(PKG_DIR)/payload
	@echo "Created $(PKG_FILE)"

# Notarize (requires APPLE_ID, TEAM_ID, APP_PASSWORD env vars)
notarize: pkg
	xcrun notarytool submit "$(PKG_FILE)" \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(TEAM_ID)" \
		--password "$(APP_PASSWORD)" \
		--wait
	xcrun stapler staple "$(PKG_FILE)"

# Show current status
status:
	@echo "=== $(APP_NAME) Status ==="
	@echo -n "Installed: "; test -d "$(INSTALL_DIR)/$(APP_NAME).app" && echo "Yes" || echo "No"
	@echo -n "Running:   "; pgrep -x $(APP_NAME) > /dev/null && echo "Yes (PID $$(pgrep -x $(APP_NAME)))" || echo "No"
	@echo -n "Build dir: "; echo "$(BUILD_DIR)"

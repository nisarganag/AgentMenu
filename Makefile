VERSION  := 1.6.0

# macOS 27's SDK implements SwiftUI's @State as a macro whose compiler
# plugin (SwiftUIMacros) ships only with full Xcode, not Command Line Tools,
# so every @State fails to expand and the build dies. The 26.x SDK still
# ships @State as a plain property wrapper. Pin to it when present; override
# with `make SDKROOT=...` once building under full Xcode.
SDKROOT ?= $(shell xcrun --sdk macosx26.5 --show-sdk-path 2>/dev/null)
export SDKROOT
APP      := dist/AgentMenu.app
BIN      := .build/apple/Products/Release/AgentMenuApp
DMG      := dist/AgentMenu-$(VERSION).dmg
STAGING  := dist/dmg-staging

.PHONY: all test build bundle dmg install run clean

all: bundle

test:
	swift test

# Universal so the DMG also runs on Intel Macs.
#
# DEVIATION from the task brief's literal recipe: `swift build -c release
# --arch arm64 --arch x86_64` in one invocation requires Xcode's XCBuild
# engine to merge the fat binary -- confirmed by running it here, where it
# fails with:
#   error: xcbuild executable at
#   '/Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild'
#   does not exist or is not executable
# even with `--build-system native` forced explicitly. Only Command Line
# Tools are installed on this machine, not full Xcode, so XCBuild is
# unavailable. Building each arch separately uses the native SwiftPM
# planner (no XCBuild involved) and succeeds for both; `lipo -create`
# merges the two single-arch Mach-O binaries into one genuine universal
# binary at the exact BIN path the rest of this Makefile already expects,
# so bundle/dmg/install/run below are unchanged from the brief.
# One invocation with both --arch flags yields a universal binary directly.
# Swift 6.4 moved every build into a shared .build/out/Products/<config>, so the
# old per-triple paths (.build/<triple>/release/) no longer exist and building
# the two slices separately makes the second silently overwrite the first.
# --show-bin-path asks SwiftPM where it put the result instead of assuming.
build:
	swift build -c release --arch arm64 --arch x86_64
	mkdir -p .build/apple/Products/Release
	cp "$$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AgentMenuApp" $(BIN)
	lipo -info $(BIN)

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(BIN) $(APP)/Contents/MacOS/AgentMenu
	cp Resources/pricing.json $(APP)/Contents/Resources/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	mkdir -p $(APP)/Contents/Resources/Scripts
	cp Scripts/*.sh $(APP)/Contents/Resources/Scripts/
	chmod +x $(APP)/Contents/Resources/Scripts/*.sh
	codesign -s - --force --deep $(APP)
	@echo "built $(APP)"

dmg: bundle
	rm -rf $(STAGING) $(DMG)
	mkdir -p $(STAGING)
	cp -R $(APP) $(STAGING)/
	ln -s /Applications $(STAGING)/Applications
	cp Resources/dmg-README.txt $(STAGING)/README.txt
	hdiutil create -volname "AgentMenu" -srcfolder $(STAGING) \
		-ov -format UDZO $(DMG)
	rm -rf $(STAGING)
	@echo "built $(DMG)"

install: bundle
	rm -rf /Applications/AgentMenu.app
	cp -R $(APP) /Applications/
	@echo "installed to /Applications/AgentMenu.app"

run: bundle
	$(APP)/Contents/MacOS/AgentMenu

clean:
	rm -rf .build dist

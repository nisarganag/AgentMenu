VERSION  := 1.2.1
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
build:
	swift build -c release --arch arm64
	swift build -c release --arch x86_64
	mkdir -p .build/apple/Products/Release
	lipo -create \
		.build/arm64-apple-macosx/release/AgentMenuApp \
		.build/x86_64-apple-macosx/release/AgentMenuApp \
		-output .build/apple/Products/Release/AgentMenuApp

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

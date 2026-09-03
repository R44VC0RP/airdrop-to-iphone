SHELL := /bin/bash
APP := build/Airdrop to iPhone.app
EXT := $(APP)/Contents/PlugIns/IPhoneFinderExtension.appex
SIGN_IDENTITY ?= Developer ID Application: Ryan Vogel (9G68SMNHEU)
INSTALL_APP := $(HOME)/Applications/Airdrop to iPhone.app
SWIFT_FLAGS := -O -target arm64-apple-macosx14.0

.PHONY: build install
build:
	mkdir -p "$(APP)/Contents/MacOS" "$(EXT)/Contents/MacOS"
	xcrun swiftc $(SWIFT_FLAGS) -parse-as-library App.swift -o "$(APP)/Contents/MacOS/AirdropToIPhone"
	xcrun swiftc $(SWIFT_FLAGS) -application-extension -parse-as-library -emit-executable -Xlinker -e -Xlinker _NSExtensionMain FinderExtension.swift -o "$(EXT)/Contents/MacOS/IPhoneFinderExtension"
	cp App-Info.plist "$(APP)/Contents/Info.plist"
	cp Extension-Info.plist "$(EXT)/Contents/Info.plist"
	codesign --force --options runtime --timestamp=none --sign "$(SIGN_IDENTITY)" --entitlements Extension.entitlements "$(EXT)"
	codesign --force --options runtime --timestamp=none --sign "$(SIGN_IDENTITY)" "$(APP)"
	codesign --verify --deep --strict "$(APP)"

install: build
	ditto "$(APP)" "$(INSTALL_APP)"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(INSTALL_APP)"
	pluginkit -a "$(INSTALL_APP)/Contents/PlugIns/IPhoneFinderExtension.appex"

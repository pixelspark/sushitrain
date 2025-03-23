# Copyright (C) 2025 Tommy van der Vorst
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at https://mozilla.org/MPL/2.0/.
.PHONY: lint format macos ios clean build cleanup

build: macos ios

format: Sushitrain/*.swift
	swift format format -r -i .

lint: Sushitrain/*.swift
	swift format lint -r .

BUILD_DIR=$(shell pwd)/Build
KEYCHAIN_PATH=$(BUILD_DIR)/keychain.db
CODESIGN_IDENTITY="Apple Development: Tommy van der Vorst (NG3J47D2S7)"
KEYCHAIN_PASSWORD="not so secret"

# Apple developer team ID (must match certificate and provisioning profile)
TEAM_ID=2N89DJPQ2P

# UUID of Assets/synctrain-ios-ci.mobileprovision
PROVISIONING_PROFILE_UUID_IOS=$(shell security cms -D -i ./Assets/synctrain-ios-ci.mobileprovision | plutil -extract UUID raw -)
PROVISIONING_PROFILE_PATH_IOS=~/Library/MobileDevice/Provisioning\ Profiles/$(PROVISIONING_PROFILE_UUID_IOS).mobileprovision
PROVISIONING_PROFILE_UUID_MACOS=$(shell security cms -D -i ./Assets/synctrain-macos-ci.provisionprofile | plutil -extract UUID raw -)
PROVISIONING_PROFILE_PATH_MACOS=~/Library/MobileDevice/Provisioning\ Profiles/$(PROVISIONING_PROFILE_UUID_MACOS).provisionprofile

clean:
	rm -rf $(BUILD_DIR)
	cd SushitrainCore && make clean

core:
	cd SushitrainCore && make deps
	cd SushitrainCore && make

provisioning:
ifndef P12_PASSWORD
	echo You need to set 'P12_PASSWORD' to the password of the .p12 certificate.
	exit 1
endif

	echo $(PROVISIONING_PROFILE_UUID_IOS) $(PROVISIONING_PROFILE_PATH_IOS)
	echo $(PROVISIONING_PROFILE_UUID_MACOS) $(PROVISIONING_PROFILE_PATH_MACOS)
	mkdir -p $(BUILD_DIR)

	# Set up a keychain
	security create-keychain -p $(KEYCHAIN_PASSWORD) $(KEYCHAIN_PATH)
	security set-keychain-settings -lut 21600 $(KEYCHAIN_PATH)
	security unlock-keychain -p $(KEYCHAIN_PASSWORD) $(KEYCHAIN_PATH)

	# Import WWDR root certificate
	# See https://www.apple.com/certificateauthority/
	security import ./Assets/AppleWWDRCAG3.cer -A -t cert -k $(KEYCHAIN_PATH)

	# Import developer certificate
	security import ./Assets/developer-certificate.p12 -P $(P12_PASSWORD) -A -t cert -f pkcs12 -k $(KEYCHAIN_PATH)
	security list-keychain -d user -s $(KEYCHAIN_PATH)

	# Import provisioning profile
	mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
	cp ./Assets/synctrain-ios-ci.mobileprovision $(PROVISIONING_PROFILE_PATH_IOS)
	cp ./Assets/synctrain-macos-ci.provisionprofile $(PROVISIONING_PROFILE_PATH_MACOS)
	ls -la ~/Library/MobileDevice/Provisioning\ Profiles

mac: core provisioning
	# Build .app
	plutil -remove "com\.apple\.developer\.device-information\.user-assigned-device-name" Sushitrain/Sushitrain.entitlements
	xcodebuild -scheme "Synctrain release" \
		-archivePath "$(BUILD_DIR)/synctrain-macos.xcarchive" \
		-sdk macosx \
		-configuration Release \
		-destination generic/platform=macOS \
		CODE_SIGN_IDENTITY=$(CODESIGN_IDENTITY) \
		OTHER_CODE_SIGN_FLAGS="--keychain $(KEYCHAIN_PATH)" \
		PROVISIONING_PROFILE_SPECIFIER=$(PROVISIONING_PROFILE_UUID_MACOS) \
		DEVELOPMENT_TEAM=$(TEAM_ID) \
		CODE_SIGN_STYLE="Manual" \
		clean archive

ios: core provisioning
	# Build archive
	xcodebuild -scheme "Synctrain release" \
		-archivePath "$(BUILD_DIR)/synctrain-ios.xcarchive" \
		-sdk iphoneos \
		-configuration Release \
		-destination generic/platform=iOS \
		CODE_SIGN_IDENTITY=$(CODESIGN_IDENTITY) \
		OTHER_CODE_SIGN_FLAGS="--keychain $(KEYCHAIN_PATH)" \
		PROVISIONING_PROFILE_SPECIFIER=$(PROVISIONING_PROFILE_UUID_IOS) \
		DEVELOPMENT_TEAM=$(TEAM_ID) \
		CODE_SIGN_STYLE="Manual" \
		clean archive

cleanup:
	# Clean up
	-rm $(PROVISIONING_PROFILE_PATH_IOS)
	security delete-keychain $(KEYCHAIN_PATH)
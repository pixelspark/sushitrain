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

clean:
	rm -rf $(BUILD_DIR)
	cd SushitrainCore && make clean

core:
	cd SushitrainCore && make deps
	cd SushitrainCore && make

mac: core
	# Build .app
	plutil -remove "com\.apple\.developer\.device-information\.user-assigned-device-name" Sushitrain/Sushitrain.entitlements
	xcodebuild -scheme "Synctrain release" \
		-archivePath "$(BUILD_DIR)/synctrain-macos.xcarchive" \
		-sdk macosx \
		-configuration Release \
		-destination generic/platform=macOS \
		CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
		clean archive

ios: core
	# Build archive
	xcodebuild -scheme "Synctrain release" \
		-archivePath "$(BUILD_DIR)/synctrain-ios.xcarchive" \
		-sdk iphoneos \
		-configuration Release \
		-destination generic/platform=iOS \
		CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
		clean archive

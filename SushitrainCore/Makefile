# Copyright (C) 2024 Tommy van der Vorst
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at https://mozilla.org/MPL/2.0/.
PATH := /opt/homebrew/bin:$(HOME)/go/bin:$(PATH)
SHELL := env PATH=$(PATH) /bin/bash

.PHONY: clean install

build/SushitrainCore.xcframework: src/*.go Makefile go.mod
	@go version
	go get golang.org/x/mobile/cmd/gomobile

	@# The 'kqueue' and 'noassets' flags fix issues when building synchting/notify and syncthing's autogenerated assets respectively
	gomobile bind -target ios,iossimulator,macos -iosversion=15 -tags noassets,kqueue -o ./build/SushitrainCore.xcframework ./src

build: build/SushitrainCore.xcframework
	
install: build

clean:
	rm -rf build/*
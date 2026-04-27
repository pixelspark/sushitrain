# Copyright (C) 2024-2026 Tommy van der Vorst
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this file,
# You can obtain one at https://mozilla.org/MPL/2.0/.
PATH := $(shell pwd):/opt/homebrew/bin:$(HOME)/go/bin:$(PATH)
SHELL := env PATH="$(PATH)" /bin/bash
GO_VERSION := $(shell go version)

.PHONY: clean install deps

build: build/SushitrainCore.xcframework

deps:
ifndef GO_VERSION
	echo Go is not installed!
endif
	go get -tool golang.org/x/mobile/cmd/gomobile
	go get -tool golang.org/x/mobile/cmd/gobind
	go tool gomobile init

notices.html: notices.template.html go.mod go.sum
	go get -tool github.com/google/go-licenses@latest
	go tool go-licenses report ./... --template=./notices.template.html > notices.html

build/SushitrainCore.xcframework: src/*.go Makefile go.mod notices.html
	go tool gomobile bind -target ios,iossimulator,macos -iosversion=15 -tags noassets -o ./build/SushitrainCore.xcframework ./src

install: build

clean:
	rm -rf build/* notices.html

test:
	go test ./... -tags noassets
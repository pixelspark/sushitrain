# Sushitrain

Securely synchronize files on-demand using Syncthing on iOS.

[Download on the App Store](https://apps.apple.com/nl/app/synctrain/id6553985316) | [Test beta versions through TestFlight](https://testflight.apple.com/join/2f54I4CM)

In addition to the very powerful file synchronization features offered by Syncthing, this app has some extra tricks up it
sleeve:

- **Selective file synchronization**: only keep specific files or subdirectories from a larger folder on your device.
- **On-demand access to files**: download or stream files that are not available locally from another peer through the Syncthing protocol. This allows access to your files, from your own devices, without setting up a VPN.
- [**Remote thumbnails**](./Docs/thumbnails.md): the app can generate thumbnails for files on other devices (images or videos). You can even synchronize thumbnails between devices, so previews can be generated on a device that has all the files for use on other devices.

## Building

The app consists of a framework in Go and front-end code in Swift.

To build the app, you need a macOS computer with the following:

- XCode with the iOS 17.5 or higher SDK installed
- Developer certificates
- Go (see [go.mod](./SushitrainCore/go.mod) for the version used)

First, verify the Go framework builds correctly. Open a terminal and do the following:

```bash
cd SushitrainCore
make
```

This should not show any errors and lead to a built framework in the `build` directory.

Note that the Makefile assumes you installed Go through Homebrew in `/opt/homebrew`. Change accordingly if your environment
is different.

When the framework is succesfully built, open XCode and follow the following steps:

1. Remove the `com.apple.developer.device-information.user-assigned-device-name` entitlement from the project configuration
   for iOS. This entitlement allows the app to set the Syncthing device name to match the device's actual hostname. The
   entitlement can only be obtained from Apple and for distributed apps only. Without the entitlement, the app will receive
   `localhost` from iOS as host name and will set that as peer name upon first startup. You can of course change the device
   name from the settings screen or in the configuration.
2. Set up signing (change the 'team ID' in the project settings you a team or developer ID you have access to, then let
   XCode autoamtically provision certificates for you). You may have to change the bundle ID to something else.
3. Finally, pressing Cmd-B should be all that is needed to build the app.

Note that XCode will, by default, invoke the aforementioned Makefile for the Go framework as part of the build process. In
development it may be easier to build the framework by hand to be able to easily see any compiler output (a subsequent make
invocation from XCode should be rather quick if nothing changed since the manual invocation).

## Formatting

```bash
brew install swift-format
swift format lint -r .
swift format -r -i .
```

## Translations

To translate using ChatGPT, use the [localize.mjs](./localize.mjs) script as follows:

```bash
OPENAI_KEY=sk-xxxx node ./localize.mjs
```

The script will invoke ChatGPT for strings for which one or more translations are missing. Edit the script to set the supported
locales. After running the script, open the `Localizable.xcstrings` file in XCode and save once to maintain the XCode-specific
JSON formatting and not pollute the commit diff with whitespace changes.

## Updating Syncthing core

To select a specific version:

1. Update the version number in [go.mod](./go.mod)
2. Run `go get -u ./...` in the `SushitrainCore` directory
3. Run `go mod tidy`
4. Run `go get golang.org/x/mobile/cmd/gomobile`
5. Update version number in [sushitrain.go](./SushitrainCore/src/sushitrain.go)

To use the `main` branch, run `go get -u github.com/syncthing/syncthing@main` in the `SushitrainCore` directory.

### Using a local version of Syncthing

Edit `go.mod`:

````
replace github.com/syncthing/syncthing => /local/path/to/syncthing
````

Then, run `go mod tidy`.

## Architecture

The Sushitrain app is written in Swift and uses SwiftUI. It embeds a framework called SushitrainCore, which is written
in Go. This framework embeds the Syncthing code and provides an interface that is usable from the Swift side.

The Go and Swift sides are bridged by a tool/framework called 'gomobile'. This tool generated bindings for Go code to be
called from Objective-C (and hence from Swift). Gomobile does not support all Go types, however - in particular, slices
(arrays) and therefore almost all of the more complicated data types in Syncthing are not supported. The SushitrainCore
framework papers over this by only exposing the bits necessary for the app to work. To expose arrays, we use a very simple
'list of strings' type that the Swift side can use to iterate items (typically devices or folders).

The primary interface on the Go side is the 'Client' struct. The Swift side constructs one instance of this struct and sets
a Swift class as a delegate, so it can receive events. These events update state on the Swift side, which then leads to
the SwiftUI based UI to be updated automatically. Note that this state may only be changed from the main thread. Therefore
care must be taken to defer work to the main thread upon receiving callbacks from the Go side. Calling the Go side from
Swift typically also happens on the main thread (i.e. in response to a UI action), but this is not typically a requirement,
as most mutating operations are guarded by mutexes in Syncthing (e.g. the mechanism to change and save the configuration,
which is used for a lot of functionality in the app).

Technically the app runs a full-blown Syncthing node in-process. This means it supports all the synchronization features
of Syncthing, as well as features around e.g. discovery, ignore files, et cetera. Not all features are exposed, however, for
ease of use and/or because they do not make sense on iOS.

## Features

As Sushitrain is intended to be used on a mobile device, it provides several affordances that regular Syncthing clients
typically do not. The most important features are (1) on-demand download and (2) selective synchronisation.

### Selective synchronisation

Typically, mobile devices are constrained in the amount of storage they have. While modern devices are capable enough for
synchronising larger folders using Syncthing, it is often undesirable. Current clients do not offer any other way to access
files through Syncthing without synchronising first.

One solution is _selective synchronisation_. This feature allows the user to select a subset of files and directories in the folder
that should be synchronised. In Sushitrain, this is implemented using the existing 'ignore' capabilities in Syncthing. When
a folder is set into 'selective' mode, an `.stignore` file will be created with a single pattern: `*`. This causes all files
to be ignored for synchronisation. At this point, the folder global index will still be synchronized like normal, but the
client will not 'pull' files from other peers, nor will it 'push' any new files or changes to files. Because the global
index is available and the client does have the ability to pull files, it can still download files 'on demand' (see below).

When a user selects a file to sync to the device, an exception pattern is added to the `.stignore` file before the catch-
all `*` pattern, e.g.:

```
!/some/file/I/want.txt
*
```

This will cause the file to be synchronised (depending on the mode of the folder, changes made locally will also be pushed,
and deleting the file is propagated as well).

There are a few issues with this:

- When the file is renamed locally, Syncthing handles this as a removal and creation of a new file. The removal is pushed
  to other nodes (if the folder is 'send receive'), the new file will be ignored because of the `*` pattern. For this reason,
  the app checks for files that exist in the local directory, but are not 'selected', and offers the user a choice to either
  'select' the file and synchronize it, or delete it locally. Files that exist locally but aren't 'selected' are termed 'extraneous files'.
- When a new file is created locally that has the same name of a file that also exists in the global index, but is not selected,
  the file is not synced until it is 'selected', at which point it might overwrite the existing global file. This situation
  is also handled by providing the user a choice.
- When a file is renamed remotely, it is also a removal and creation. The removal is processed by the client (the selected
  file will disappear), the new file will not appear until 'selected'.

Sushitrain also supports 'selecting' directories. In this case, a pattern is added to `.stignore` that matches any (current
and future) file in the folder:

```
!/some/folder
*
```

Current and future files in the folder will be synced and considered 'implicitly selected'.

### On-demand downloads

In Sushitrain, files can be accessed on demand. The user can select a file to view, and it will be downloaded from one of
the peers that has the necessary blocks available. The file is selected from the 'global index' (i.e. the set of files that
all nodes participating in a folder synchronisation agree on). Sushitrain always syncs the global index, even when selective
synchronisation is enabled. File downloads use the same mechanism as regular 'pulling' during synchronisation.

To enable streaming playback of media files, Sushitrain runs an HTTP server on localhost on a random port. When a user selects
a video file for streaming, it will point the media player to a special URL (`/file?folder=X&path=Y&signature=Z`) that supports
HTTP range requests. Range requests will cause only the blocks necessary to fulfill the request to be fetched from the Syncthing
remote peer.

### Custom configurations

By default, the app will create a device identity and default configuration on first launch, and store it in the
'Library/Application Support'-directory. Synced folders will end up in the `Documents` directory, where they will be visible from
the iOS 'Files' app.

A custom configuration can be loaded by placing `config.xml` in the `Documents` folder and restarting the app. This will
show a warning on startup. By placing `cert.pem` and `key.pem` (both) in the `Documents` folder, a custom device identity
can be loaded as well. This feature is useful for testing the app.

### Thumbnails

See the [documentation on thumbnails](./Docs/thumbnails.md).

## The name

Sushitrain is the code name for this app. Due to the name being unavailable in the App Store, it is not the final name
of the app.

In Japan, several lower-end sushi restaurants have a system where you order sushi through a tablet, which then is delivered
to your table by a small train that runs between the kitchen and the tables. This is a very efficient system of ordering
small bites. Additionally, 'SushiTrain' shares the 'SyncThing' initials.

## Contributing

Pull requests to this repository are welcomed and will be considered. Contributors to this repository agree to license
their contributions under the license described below (MPLv2). Regardless of the license in effect, you retain the
copyright to your contribution.

If you have found an issue, please notify us through the TestFlight testing program. If this is not possible, you can use
the discussions section on this repository. The developers are not obliged to answer any questions or fix any issues -
remember this is free software. The planning of releases and the roadmap is solely up to the developers. If you have a
specific need, you may contact the developers to discuss a commercial development project.

## License

Sushitrain, Synctrain are (C) Tommy van der Vorst (tommy@t-shaped.nl), 2024.

Except when explicitly noted otherwise, the code in this repository is licensed under the Mozilla Public License 2.0.
Read the license [here](./LICENSE). Contributors to this repository agree to license their contributions under this license.

The following items are explicitly _not_ licensed under the abovementioned license. Instead all rights are reserved by the
author / the respective owners:

- The name 'Sushitrain' and the name 'Synctrain'
- The logo (everything in [this directory](./Sushitrain/Assets.xcassets/AppIcon.appiconset/)).

Syncthing is a trademark of the Syncthing Foundation. Read more over at [syncthing.net](https://syncthing.net). This project
is not endorsed by, nor affiliated with, neither Syncthing contributors nor the Syncthing Foundation.

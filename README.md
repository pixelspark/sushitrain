# Sushitrain

Sync files on-demand using Syncthing on iOS.

## Architecture

The Sushitrain app is written in Swift and uses SwiftUI. It embeds a framework called SushitrainCore, which is written
in Go. This framework embeds the Syncthing code and provides an interface that is usable from the Swift side. Technically
the app runs a full-blown Syncthing node in-process. This means it supports all the synchronization features of Syncthing,
as well as features around e.g. discovery, ignore files, et cetera.

Sushitrain currently uses a [fork](https://github.com/pixelspark/syncthing) of the syncthing code, which in turn is based
on the [MobiusSync/syncthing](https://github.com/MobiusSync/syncthing) fork. The latter contains patches to make Syncthing
work properly on iOS. The former only has minor changes to make certain functions accessible from our own Go code.

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

## The name

Sushitrain is the code name for this app. Due to the name being unavailable in the App Store, it is not the final name
of the app.

In Japan, several lower-end sushi restaurants have a system where you order sushi through a tablet, which then is delivered
to your table by a small train that runs between the kitchen and the tables. This is a very efficient system of ordering
small bites. Additionally, 'SushiTrain' shares the 'SyncThing' initials.

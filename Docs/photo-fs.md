# Photo folders

Synctrain provides two mechanisms for synchronizing photos from the iOS photo library through Syncthing:

- The **photo back-up** feature automatically and periodically exports photos, videos and live photos from the library to
  a specific location inside a (synchronized) folder. This feature is useful for backing up photos to other devices; using
  selective synchronization the exported photos can be deselected again once other devices have received the photos. The
  downside of this approach is that as long as other devices have not synchronized the photos yet, they take up disk space.
- The **photo folder** feature exposes one or more photo albums from the system photo library to Syncthing as if they
  existed in an actual (send-only) folder. Photos are never exported to disk, but instead read from the system photo library
  directly. This also means that whenever a photo is deleted from the system photo library, it will disappear from the
  synchronized folder as well.

The photo folder feature is implemented by tricking Syncthing into thinking that it is accessing a folder containing
the photos as files, which is not actually the case. Instead our code 'simulates' a file system, and the photo files are
provided to the Syncthing code on demand.

## Technical details

As interfacing with the system photo library is only really practical from the Swift side, the implementation is slightly
involved. The Swift side of the app provides the Go side with an interface to access an in-memory 'virtual tree of files'.
The Go side uses this to implement the Syncthing file system interface, which are all the methods needed by Syncthing to
list, read and modify files.

On start up, the Swift side of the app registers a function to instantiate the 'virtual file tree' for file system type
`sushitrain.photos.v1`. This in turn makes the Go side register a function with the Syncthing code that can be called
whenever a file system of that type needs to be instantiated.

When creating a photo folder, the app will set the `fsType` to `sushitrain.photos.v1`. When Syncthing then loads the
configuration for that folder and starts processing it, it will eventually need to access the files contained in it. To
do so it will obtain the Go function that was registered earlier to instantiate an object that implements the file system
interface. This function uses our Swift virtual file tree implementation behind the scenes.

The virtual tree of files is constructed on the Swift side upon instantiation. The Swift side also registers a callback
with the system photo library to get notified of any changes to the photo library. Whenever a change is detected, a flag
will be set that will invalidate the virtual tree. Whenever the virtual tree is consulted and this flag is set, _or_ a
certain time has passed since the last full reconstruction of the tree, the tree will be reconstructed.

The virtual tree of files is constructed by the Swift side of the app by enumerating photo assets in the system Photo
library. The virtual tree also contains a folder marker (`.stfolder` folder) as well as an `.stignore` file (to be used
in the future).

To do so it needs to know which albums need to be exposed in the tree and at what paths. The Swift side stores
these and other settings in a structure. This structure is serialized to and from JSON and stored in the `path` configured
for the folder (as this is a virtual file system, the path does not need to point to an actual folder on the disk, and
doesn't even need to be a path - Syncthing simply supplies the configured `path` as string to the file system implementation).
Whenever the user edits the photo-related settings for the folder, the Swift side of the app reads and writes the settings
object from and to JSON format in the folder's `path`.

## Limitations

- Photo folders currently cannot be used to synchronize live photos or videos. This is because the file system interface
  is based around blocking calls, whereas exporting videos is an asynchronous operation on the Swift side. If you need to
  export videos and/or live photos, use the _photo back-up_ feature instead.
- Photo folders can currently only be synchronized in 'send only' mode, as the underlying virtual file system implementation
  does not implement writing operations.
- The current implementation assumes that exporting photos from the library is not an expensive operation (it will ask for
  the current version of a photo asset, without any re-encoding or resizing). This may not always be the case (i.e. when
  photos are stored in iCloud). As photo export happens each time a virtual 'photo file' is accessed this may degrade
  performance significantly.
- The virtual photo files will have their creation and last modified date set to the creation date provided by iOS for that
  asset.
- When a photo is deleted from a photo album, the deletion will of course be propagated to other peers. Due to this the
  photo folder system is less suited for use as a backup mechanism than i.e. the photo _back-up_ feature.
- The current implementation does not support ignore patterns (other devices may of course ignore specific files or folders).

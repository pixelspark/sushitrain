# Thumbnails

Thumbnails are an essential aid when navigating folders of media files with (typically) nondescript names. Sushitrain can
obtain thumbnails from three different sources:

- For files that are present locally, the app will ask the system to generate thumbnails for files that are available locally
  using the QuickLook-framework. The system will cache these thumbnails or can generate them very quickly. In addition to
  media files, QuickLook can also generate thumbnails for many other types of files (such as PDFs). When it cannot produce
  an actual thumbnail, it can still generate an icon image representing the file.

- For files that are only available from another device on-demand, the app will generate thumbnails by fetching the file
  (or part of it). As QuickLook does not support rendering thumbnails for remote files (and we don't want to download the
  file in full when we don't have to) the app implements this by itself for images and video. For video, it uses the system-
  provided AVAssetImageGenerator functionality, which only needs a small part of a video file.

- Generated thumbnails are (optionally) saved to and read from a disk cache (by default, only thumbnails generated for
  remote files are cached, but the user can use the 'generate thumbnails' button in the app to also generate and store
  thumbnails for local files). A thumbnail is fetched from cache instead of re-generated when it is found (by its file
  hash) in the disk cache.

## Thumbnail disk cache

The thumbnail disk cache folder is by default located in a system-defined cache folder location. This has the consequence
that the system may purge the thumbnail cache at its discretion (i.e. when disk space runs out).

Alternatively, the user can choose a synced folder as thumbnail cache. This means that generated thumbnails can be shared
between devices.

Thumbnails can be generated from one device (possibly one that has quick access to the files, i.e. has them available
locally) and then used on another. This is very helpful in scenarios where a user wants to browse large media libraries
(i.e. video assets) that are present on e.g. a desktop computer. The app will generate thumbnail on demand (as the user
views thumbnails of the file) or when the user selects 'generate thumbnails' for a folder. It would also be possible to
generate thumbnails by means of an external tool.

Thumbnails in the cache are currently JPEG files where neither width nor height exceed 255 pixels (the other dimension
is caled accordingly).

### Directory and file structure

The disk cache identifies thumbnails by the hash of the original file. This means that when an identical file exists in
multiple places, the same thumbnail cache file can be re-used. When multiple files generate a thumbnail for the same file,
it should be (functionally) identical, and so it is not a problem if thumbnails are overwritten.

The thumbnail file name is generated from the file's _block hash_. This hash is encoded as base64 and then lowercasd,
after which all characters except for a-z0-9 are removed. The first two characters are then removed and used as names for
two subdirectories in which the file will be placed.

The file extension is `.jpg`.

For example, a file whose hash is `t1337h4x0r` will have its thumbnail stored at `t/1/337h4x0r.jpg` in the
cache directory. Because there are 36 possible characters, there will be at most 36\*36=1296 folders, each containing a
shard of the cache.

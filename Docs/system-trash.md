# System Trash

Native folders have an opt-in **Move deleted files to system Trash** setting in
advanced folder settings. Existing folders default to permanent deletion. The
setting applies to deselection, selection cleanup, explicit deletion, and ordinary
unversioned deletions received during synchronization. Removing the whole folder
moves its root to Trash after pausing synchronization.

Files in Trash still occupy disk space. This setting therefore changes how much
space deselection can immediately reclaim. Recovery is through the system's file
manager; Synctrain does not empty Trash or provide its own retention policy.

## Filesystem integration

The folder configuration persists `filesystemType="basic-trash"`. Its registered
factory wraps Syncthing's basic filesystem, overriding `Remove` and `RemoveAll`.
`Type()` deliberately continues to report `basic`: paths, watches and renames are
native, Syncthing's protected-file checks still apply, and version-history
filesystems constructed from `Type()` remain ordinary basic filesystems. Native
folder checks in the app accept both configuration types. Configuration changes
restart the folder through Syncthing's normal configuration lifecycle.

The wrapper preserves options and the outer case-checking and modification-time
layers applied by `fs.NewFilesystem`. It forwards ordinary operations to BasicFS.
`Remove` moves files and symlinks to Trash, but removes directories only when empty
using BasicFS. This preserves selective synchronization's per-child checks.
`RemoveAll` moves user subtrees as a single item, including the configured root
when passed an empty path. Syncthing internal files and recognized temporary files
retain permanent cleanup semantics.

The Swift `SystemTrash` bridge calls `FileManager.trashItem` synchronously on the
calling worker, using the folder access already held by `BookmarkManager`. It does
not dispatch to the main actor. Absolute incoming filesystem paths, upward
traversal, and symlinked parents are rejected before handing a native path to the
bridge. The leaf symlink itself is moved, not its target.

There is no permanent-deletion fallback. A missing bridge or native Trash error
leaves the item in place and is reported to the caller. Deselection can already
have updated the ignore file; use selection cleanup to retry removing retained
local files. Failure to trash an entire folder leaves it configured and paused so
removal can be retried.

## Versioning and scope

Syncthing versioning archives remote changes before filesystem deletion. Ordinary
same-volume archiving remains a rename into the version store, and expiring those
versions does not send them to system Trash. A cross-volume archive may fall back
to copy-and-remove; its source removal also passes through Trash, potentially
retaining an additional copy or reporting a Trash error after the copy succeeds.

Renames, in-place writes, and replacements are unchanged. The setting is not a
guarantee that every overwritten version is recoverable. Virtual photo folders
are excluded. Folder bookmarks and the availability of Trash on external volumes
and file-provider locations remain platform-dependent; unsupported operations
fail rather than permanently deleting content.

## Verification

`go test ./... -tags noassets -race` covers recoverable file and subtree removal,
root removal, empty-directory semantics, missing paths, hidden user files,
internal and temporary cleanup, native failure and missing-handler behavior,
symlinks and traversal, case-conflict checks, concurrent removals, last-copy
protection, configuration serialization and toggling, virtual-folder rejection,
version archiving and expiry, and retrying failed whole-folder removal.

Implementation verification also included unsigned macOS and iOS app builds and
a native macOS smoke test using `SystemTrash`: a newly created file, directory,
and symlink were each moved to system Trash, their contents or link target checked,
and restored. The smoke test removed its own test items afterward.

Remaining device and end-to-end acceptance checks:

- On macOS, deselect a file and restore it from Finder's Trash. Check app-managed
  folders and a security-scoped external folder, including an external volume.
- On iOS, repeat in app Documents and supported Files/provider locations. Verify
  where the native operation exposes recovery and that unsupported locations
  report an error with the original file intact.
- With two connected devices, delete a synchronized file remotely. Confirm it
  reaches Trash with versioning disabled and the version store with versioning
  enabled. Confirm temporary download cleanup does not populate Trash.
- Toggle the setting while a folder is active, restart the app, and verify native
  previews, sharing, watching, and local availability continue to work.
- Deselect a directory containing a retained last copy; confirm that child stays
  in place. Simulate a Trash error and verify the selection UI reports it.
- Remove an entire folder, including a failed attempt followed by a retry, and
  verify all content is recoverable after success.

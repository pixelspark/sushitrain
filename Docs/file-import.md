# Receiving files

Synctrain registers as an alternate viewer for files and directories. Opening a file
with Synctrain (including a macOS Dock drop or an iOS file-based Open In action)
queues the URL in the main window. The import sheet waits for startup to finish,
then lets the user choose a synchronized folder and an existing subdirectory.
Cancel releases access without copying anything to that destination.

On macOS, `SynctrainShare` provides the Share-menu entry. It copies each item
provider representation to the shared App Group cache before its callback
returns, then opens those URLs with the containing app. The main app performs
destination selection and importing. The extension is built and embedded only
on macOS. Temporary representations are retained for the main app to read and
are subject to the operating system's cache cleanup.

On iOS, this uses file-based Open In sharing, not a Share extension. Source apps
must offer a file handoff; sharing arbitrary Photos selections, text, or web links
through an extension is outside this flow.

`FileImport.copy` is also used by the existing browser import/drop handlers. It
materializes selective subdirectories, copies files without replacing existing
items, explicitly selects successfully copied paths in selective folders, and
rescans the destination. Reading the folder's selective status must succeed before
copying starts. Security-scoped access is retained while the picker is displayed,
and reads are coordinated with file providers during each copy.

If only part of a batch can be copied, the picker reports the errors and retains
only the unsuccessful source URLs for retry. If selection or scanning fails after
copying, the error is shown and already copied files remain at the destination.
Incoming URLs received during a save stay queued for the next save.

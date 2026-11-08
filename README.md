# Reading Capture — macOS prototype

A separate, Apple Silicon-only app for collecting native highlights from Skim
and calibre's ebook viewer. Requires macOS 13 or newer. No account, server or
telemetry. The app has its own Keychain item and encrypted local library; its
only connection to IM/Mosaic is explicit export/import.

## Install and use

Download the disk image from [Releases](https://github.com/joshuazang/ReadingCapture/releases).
Open it and drag **Reading Capture** into **Applications**. The app has a Dock
icon; clicking it reopens the library. Development builds are ad-hoc signed,
not Developer ID signed/notarized. macOS may require a per-app Open Anyway
approval. Do not disable Gatekeeper globally.

1. Open Skim or calibre's viewer. Under **Reading apps**, choose **Allow [app]**
   for the actual running viewer, or select its application file.
2. Select **Native highlights** and **Start capture**, then return to the reader.
3. In Skim, approve macOS's Automation request to read Skim. The permission is
   named control/Automation; this app's scripts only read document names,
   highlight IDs, selected text and modification dates. It never changes PDFs.
4. In calibre, the default settings folder is `~/Library/Preferences/calibre`.
   For a custom profile, use **calibre settings folder…** and choose the folder
   containing `viewer-webengine.json`. Its `viewer/annots` files are read-only.
5. Create highlights normally in the reader. They are collected without Copy.
   A small, nonactivating comment panel appears for new highlights. Click it to
   add an optional comment; the reader stays behind it. Comments save to the
   capture's encrypted file as you type. Cmd+Enter closes the panel after saving.
6. Book names are taken automatically from Skim's document metadata or calibre's
   path-to-title mapping. No manual book label is required in native mode.
7. The **Clipboard** mode remains available for other readers, with an optional
   manual book label. Stop capture before changing modes.

Capture starts paused after launch and pauses on session deactivation. Only an
explicitly allowed foreground reader is queried. Existing highlights import
quietly on connection; new highlights show the comment panel. Calibre reads
annotations for books present in its recent-book mapping (up to 25); each
highlight keeps the title associated with its own file, not a guessed window
name. This can import existing highlights from several recent books. Skim reads
the front document, fetching new text in batches of at most 20 notes per poll.
A large existing highlight collection can take several polls to finish importing.

The adapters poll approximately every 0.7 seconds while enabled and the reader
is active. Calibre caches unchanged files; partial JSON writes are retried.
Skim reads IDs in bulk and fetches text only for uncaptured IDs. Reader state is
actor-isolated; AppleScript executes on the main thread as required by Cocoa.
There is no global keyboard interception, synthetic Copy, clipboard replacement,
Accessibility permission or screen recording. Reader-provided annotation IDs
are hashed with book identity for deduplication and stored inside encrypted
captures. Changing a highlight's color or Reading Capture comment does not
re-import it. These are archived captures, not bidirectional annotation sync:
later edits/deletions in a reader do not overwrite or delete captured quotes.

If reader metadata is missing, denied or unsupported, the status explains it;
the app does not assign a guessed book title. Skim Automation denial pauses
capture and can be changed under System Settings → Privacy & Security →
Automation. Calibre uses an internal file format, so future reader updates may
require an adapter update. Skim integration is compiled against its installed
scripting dictionary in CI; actual on-device Automation approval and reader
interaction still require a real-Mac trial before relying on this prototype.

## Export and backup

**Export → IM / Mosaic** writes a readable message export. Open the file, copy
its complete contents, and use **Import from clipboard** in either editor. Each
capture becomes one bubble/card; comments follow the quote, and book/source
metadata is preserved. Repeat imports skip unchanged entries.

**Backup JSON** produces an archive this app can re-import. Both exports are
unencrypted: save them in a trusted encrypted backup location. Export does not
change the current clipboard. Imports validate the complete archive first,
preserve existing captures, skip exact duplicates and retain changed same-ID
entries as new captures. A later I/O failure can leave a reported partial import.

## Storage and recovery

Quotes, book titles, comments and source-highlight identities are encrypted with
CryptoKit AES-256-GCM and a fresh nonce on each save. Each capture is an atomic
ciphertext file under `~/Library/Application Support/ReadingCapture/`, named
with a random ID. Comment edits write only that capture, not the entire library.
Folder/file permissions are 0700/0600. Plaintext exists in working memory,
explicit exports, and the system clipboard when Clipboard mode is used. The
readers retain their own original storage; this app does not encrypt or rewrite
calibre's annotation files or your PDF/ebook files.

The random 256-bit key lives in the nonsynchronizing Keychain item
`ReadingCapture.Vault.v1`, never beside ciphertext. Missing/locked keys with
existing data fail closed without replacing the key or falling back to plaintext.
Development-signature changes may trigger a new Keychain access approval after
an update. Losing the key can make ciphertext unrecoverable. Keep an intentional
export in a trusted encrypted backup location. FileVault/Keychain depend on your
macOS account/device security; OS swap/crash handling is outside this app.

UserDefaults holds only allowed app names/IDs and an optional custom calibre
configuration-folder path. It does not hold quotes, book titles or comments.
Reader file paths are processed in memory and hashed for capture identities;
full book paths are not added to exports.

Failed comment writes keep per-capture drafts in memory. A failed capture pauses
recording and retains the pending quote for Retry. Normal Quit is blocked until
pending text is saved or explicitly discarded. Force Quit/crash can lose
unconfirmed in-memory text. Corrupt vault files are preserved and stop library
opening. No deletion or automatic pruning is implemented.

## Build and verification

With Xcode command-line tools: `bash scripts/build-app.sh`. Open
`dist/Reading Capture.app`. Only arm64 is built. Native CI checks encryption,
Keychain reopen/missing-key behavior, archive validation, comment/new-capture
recovery, rendered-window reopening, source-highlight deduplication and book
attribution. It installs Skim to compile the read-only scripts against its real
scripting dictionary. Calibre tests use its documented source schemas and
synthetic profile files, including malformed/partial metadata.

Packages are extracted/mounted and signature-checked on a Mac before release.
The compatibility check uses the editors' shared core at pinned commit
`aaeaddd97a82b9361fcc76e4472fe9b207b70bcb` in ignored `.compat/` test storage;
it is never bundled into or fetched by the app. Native macOS UI/reader flows
are not tested by this Linux workspace; CI's scripted checks do not replace
a real-Mac trial in your installed reader versions.

Interface references:
- [Skim scripting dictionary mirror](https://github.com/scris/skim-pdf/blob/master/Skim.sdef)
- [Calibre annotation storage](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/gui2/viewer/annotations.py)
- [Calibre book identity](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/gui2/viewer/ui.py)
- [Calibre book-title mapping](https://github.com/kovidgoyal/calibre/blob/master/src/pyj/read_book/open_book.pyj)

Original prototype history: [superseded draft](https://github.com/joshuazang/IM-style-editor/pull/1).

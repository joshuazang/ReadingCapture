# Reading Capture — macOS prototype

A separate native app for collecting copied passages from Skim, calibre's viewer,
or other explicitly chosen reading apps. Requires an Apple Silicon Mac running macOS 13 or newer. It has no
Standard Notes account connection, background network client or telemetry.
This is the standalone source repository. The app has its own process, Keychain
item, data directory and release workflow. Installing it does not change either
editor. Its only connection to IM/Mosaic is the export/import file format.

## Use

Download the disk image from [Releases](https://github.com/joshuazang/ReadingCapture/releases).
Open `ReadingCapture-macOS.dmg`, then drag **Reading Capture** into **Applications**.
Future disk images and direct ZIPs contain only the Apple Silicon executable;
the release assets avoid the nested ZIP produced by Actions artifact downloads.
Both packages are extracted/mounted and signature-checked on a Mac before release.

Build with Xcode command-line tools: `bash scripts/build-app.sh`. Open
`dist/Reading Capture.app`. This is an ad-hoc signed development build, not a
Developer ID signed/notarized distribution. Build locally from reviewed source;
do not disable Gatekeeper globally.

1. Open Skim or calibre's viewer. In **Reading apps**, choose **Allow [app]**
   from the running apps, or choose an application file. Selecting the actual
   running viewer avoids guessing calibre's nested viewer bundle identifier.
2. Optionally enter a book/PDF label, then click **Start capture**. Starting
   capture ignores the old clipboard. Copying nonempty text while a chosen
   reader is frontmost immediately saves one quote. No comment is required.
3. Open the library from the menu bar to add a comment. **Save comment** or
   Cmd+Enter saves it. Switching captures, closing the window and normal Quit
   also save comments; failed saves block those transitions. Force Quit/crash
   can lose a comment that has not yet been saved.
4. **Export → IM / Mosaic** writes a plain-text message export. Open that file,
   copy its complete contents, and use **Import from clipboard** in either
   editor. One capture becomes one bubble/card. Comments follow the quote;
   source/book metadata travels with the record. Repeat imports skip unchanged
   entries through the editors' existing deduplication.
5. **Backup JSON** exports an archive that this app can import. Both exports
   are unencrypted and should be stored somewhere trusted. Export does not
   clear or replace the current clipboard.

Capture always starts paused after launch and pauses on session deactivation.
There is no recording timer while paused. While enabled, a 250ms timer checks
the clipboard change counter; it reads text only after a change in an allowed
foreground app and skips concealed/transient/generated pasteboards. This is
clipboard capture, not the reader's native highlight database. Very rapid
copies can replace one another before a poll, and switching apps immediately
after copying can prevent capture. Clipboard permissions or reader copy
restrictions can also prevent capture. Check the count before leaving a session.
No automatic page/chapter extraction, OCR, global keyboard hook, Accessibility
permission, screen recording or reader scripting is used.

## Storage and boundaries

Quotes/comments/book labels are encrypted with CryptoKit AES-256-GCM, a fresh
nonce on each save, and authentication on read. Each capture is one atomic
ciphertext file under `~/Library/Application Support/ReadingCapture/`, with
random identifiers as filenames. Updating a comment writes only that capture.
Plaintext exists in working memory, the original system clipboard, and explicit
exports. Folder/file permissions are 0700/0600. UserDefaults holds only the
allowed app names/identifiers, not quotes or comments. The optional current book
label is kept only in memory until attached to a capture.

The random 256-bit key is held in a nonsynchronizing Keychain generic-password
item (`ReadingCapture.Vault.v1`), never beside ciphertext. Missing/locked keys
with existing data fail closed; the app does not silently replace them or fall
back to plaintext. Losing that key can make encrypted files unrecoverable.
Keep an intentional export in a trusted encrypted backup location. FileVault
and Keychain security still depend on your macOS account and device security;
an unlocked compromised Mac can access app data. OS swap/crash handling is
outside the app's control.

Malformed/corrupt files are preserved and stop library opening. A failed capture
pauses monitoring and retains that capture in memory for Retry; keep the app
open. Imports validate the entire archive before writing, preserve existing
entries, skip exact duplicates, and retain changed same-ID captures as new
entries. A later I/O failure can leave a partial import; its count is reported.
No deletion or automatic pruning is implemented in this initial prototype.

## Verification

`swift test` checks authenticated encryption, tamper/wrong-key refusal, atomic
per-entry replacement, exact text round trips and malformed archives. The macOS
workflow tests an actual Swift export against the existing shared IM/Mosaic
importer and builds a native `.app` artifact. Real Skim/calibre clipboard flows,
Keychain prompts across rebuilds/upgrades, sleep/lock behavior and interactive
window handling still require verification on a Mac before daily use. This
Linux workspace cannot perform those device checks.

The compatibility workflow checks out only the editors' shared core at pinned
commit `aaeaddd97a82b9361fcc76e4472fe9b207b70bcb` into ignored `.compat/` storage.
This is a test fixture, never compiled into or fetched by the app. Updating an
editor does not silently change Reading Capture. To test locally, run
`node scripts/check-interchange.cjs /path/to/capture-export.txt /path/to/IM-style-editor`.
The original prototype and native verification history are retained in
[the superseded draft](https://github.com/joshuazang/IM-style-editor/pull/1).

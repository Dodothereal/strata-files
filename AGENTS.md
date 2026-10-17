# Strata: notes for coding agents

Strata is a native macOS file manager (Swift, AppKit, SwiftPM; macOS 26, Apple silicon). People trust it with their
files: a bug that deletes, trashes, moves or overwrites the wrong thing is the worst bug it can have. Read the rules on
destructive actions below before changing anything that touches files.

## Layout

- `Sources/Strata/` — the app, one folder per area: `Browser` (the file list and its commands), `Views` (Icons,
  Columns, Gallery, Disk Usage), `Window` (windows, panes, sidebar wiring, Compare & Sync), `Transfers` (copy/move
  jobs, conflicts, archives), `Model` (FileOps, Trash, History in `OperationLog`, SecureStorage), `AI` (Ask Strata
  plans), `Remote` (SFTP and S3), `Containers`, `Dev` (git, project cleanup), `Index`, `Sidebar`, `Settings`, `App`.
- `Sources/StrataCLI/` — the `strata` command.
- `Tests/StrataTests/` — Swift Testing; shared helpers in `Support/` (`TestTree`).
- `Localization/*.json` — one file per language; `en.json` is generated from the code.
- `docs/release-notes/<version>.md` — release notes, shown on GitHub and in the update window.

## Build and test

```sh
scripts/build.sh debug                  # build/Strata.app (release: scripts/build.sh, --open to launch)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
python3 scripts/localize.py extract     # after editing Swift files: regenerates Localization/en.json
```

- `swift test` needs Xcode's toolchain: the Command Line Tools fail with "no such module 'Testing'".
- `en.json` records each string's `File.swift:line`, so even lines shifting above a `String(localized:)` make the
  Translations workflow fail. Run `extract` and commit `en.json` in the same commit as the code.
- CI on every push: **CI** (build + `swift test`), **Translations** (`en.json` matches the code); tags run **Release**.

## Destructive actions: full test coverage is required

Every code path that deletes, trashes, moves, renames, overwrites, evicts, or changes the permissions or metadata of
user files, on this Mac or on a server, must be covered by headless tests, added in the same commit. A change to such a
path without tests isn't done. The tests must show that:

- **Only the chosen items change**: never a sibling, a look-alike name (`a` next to `ab`, `a.txt`), the same name in
  another folder, a parent, or what a link points to. Selections that nest (`a` and `a/b`) are handled once.
- **Refusals happen up front**, before anything changes: disks, folders you can't change, archive copies (read-only),
  a server's top or a bucket, a folder into itself.
- **Nothing is replaced without an explicit decision**, and a replacement happens only once a complete copy exists.
  Two items of one operation never replace each other.
- **Undo (⌘Z and History) restores exactly those items**, and never touches something that took their place.
- **Every view hands commands exactly its selection** (List incl. open folders, Icons, Columns incl. deeper columns,
  Gallery, Disk Usage, results, both panes), and it stays the same items when the folder changes.

Make the decision a plain function separate from the alert or UI (`BrowserViewController.deletionPlan`,
`FileOps.canTrash`, `FileDrop.operation(_:into:mask:option:)`, `PlanValidator.validate`, `TransferEngine.mergePlan`,
`FolderCompare.defaultAction` and `syncPlan`) so tests call it directly. Prove a
new test guards its rule: break the rule once, watch the test fail, restore it.

## Writing tests

- `TestTree("a/", "a/b.txt", "link -> a")` makes a throwaway tree (`"x/"` folder, `"x -> y"` link; targets starting
  with `/` or `.` are written as is). `snapshot()` lists it without following links: assert the whole listing, so any
  unexpected change fails. `TestTree.listing(of:)` does the same for any folder.
- Keep a `TestTree` alive until the checks are done: never discard it (`let (_, …) =`), and assert on it last. Swift
  frees it after its last use and its folder goes with it, so a test that only expects refusals passes without
  checking anything.
- If a check you broke on purpose still passes, `touch` the file and run again: the build can miss quick edits.
- Test runs never touch your History, index or keychain: in a debug build that isn't Strata itself,
  `SecureStorage.isTestRun` puts the stores in a temporary folder with a throwaway key. Keep it that way.
- Tests that use the real Trash remove exactly what they put there (`tree.removeFromTrash()`). Never empty the real
  Trash: `Trash.empty(_:)` takes the folders, so pass a fake one. Never trash or delete a real Trash, even to show
  it's refused: test the decision (`FileOps.canTrash`, `deletionPlan`) instead. Don't use `NSPasteboard.general` or
  Strata's preferences in tests: clipboard tests set `Clipboard.pasteboard` to a named pasteboard of their own.
- Suites run in parallel and CI machines are slower: poll for a condition, never a fixed sleep; never compare listings
  of shared folders like `$TMPDIR`. Suites sharing global state (`RemoteRegistry`, `TransferEngine.hooks`) run as one
  `.serialized` suite.
- The temporary folder is `/private/var/...`. Spell URLs the way `DirectoryLoader` lists them (`TestTree.root` is
  already resolved); `standardizedFileURL` and `resolvingSymlinksInPath` drop the `/private`.
- The test SFTP server (`RemoteFilesTests`, macOS's `sftp-server` over a pipe) isn't confined to its folder: it can
  reach the whole Mac. Never exercise top-level or escaping deletes against it; use `RecordingBackend`.
- View controllers can be tested without a window: `BrowserViewController`, `ColumnBrowserViewController` and
  `BrowserWindowController` (two panes) all load, select and run commands headless.

## Checking the real app

Prefer headless tests. When a GUI check is needed: the debug build has the same bundle ID as an installed Strata, so
AppleScript `set frontmost` and keystrokes can land in the user's own copy. Activate the debug build by process ID
(`NSRunningApplication(processIdentifier:)` from JXA), confirm it's frontmost, then post CGEvents; read a confirmation
sheet's text before clicking a destructive button. Both builds share preferences: put back anything you change
(view mode, sidebar mode, last location).

## Code conventions

- Swift 6 with `defaultIsolation(MainActor)` and `NonisolatedNonsendingByDefault`. Disk and network work runs in
  `@concurrent` functions or `nonisolated` types. Keep the Swift 6.3 hop workaround in `Package.swift`.
- Comments explain what and why in plain sentences, in the app's own words (Trash, Put Back, Delete Immediately);
  inline comments only for decisions that aren't obvious. Match the density of the code around you.
- User-facing text goes through `String(localized:comment:)`; plurals carry `comment: "plural"`; quotes are curly.
- Safety idioms already in use: `lstat`, `O_NOFOLLOW`, `renamex_np(RENAME_EXCL)`, deleting relative to an open folder,
  device+inode identity checks before undo. Reuse them.

## Commits and releases

- Subject: `Area: what changed, in the user's terms` (e.g. "Transfers: two items with one name never replace each
  other"). Body: what was wrong, what changed, and what the tests cover.
- Release: write `docs/release-notes/X.Y.Z.md` ("Strata X.Y.Z fixes …", then `## New` / `## Fixed` items with a bold
  first sentence), commit "Release notes X.Y.Z", push `main`, then `git tag vX.Y.Z && git push origin vX.Y.Z`. Watch
  the Release, CI and Translations workflows.

## Hunting bugs

When a report gives steps, list every place they could run before saying it doesn't reproduce: each view (List, Icons,
Columns and its deeper columns, Gallery, Disk Usage), search results, Recents and Duplicates, both panes, both sidebar
modes, and the shape of the selection. Issue #9 only happened in Columns, deleting from a deeper column.

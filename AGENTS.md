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
python3 scripts/localize.py check --all --complete  # every supported language must be complete
python3 scripts/audit-theme-colors.py    # no unreviewed surface colors or unthemed Inspector gray text
```

- `swift test` needs Xcode's toolchain: the Command Line Tools fail with "no such module 'Testing'".
- `en.json` records each string's `File.swift:line`, so even lines shifting above a `String(localized:)` make the
  Translations workflow fail. Run `extract` and commit `en.json` in the same commit as the code.
- When adding or changing user-facing text, update every `Localization/<language>.json` in the same feature commit.
  Extraction updates only English; it does not translate the other languages. Reuse translations supplied by users.
  Run `check --all --complete`: missing keys, blank text (including whitespace) and missing required plural forms
  fail. Text shared with English is valid when intentional (Strata, Finder, Git, shortcuts).
- The regular `swift test` suite runs the same completeness check locally (`LocalizationTests`), before a commit is
  merged. Run `python3 -m unittest discover -s Tests -p 'test_*.py'` for the checker and generated-resource regressions.
- CI on every push: **CI** (build + `swift test`), **Translations** (complete catalogs and `en.json` matches the code).
  Tags run **Release**, which repeats extraction, completeness and localization regression tests before importing
  signing credentials, signing or publishing. The full Swift suite must also pass in Release before signing,
  including on tags and manual runs. Do not bypass these gates or release with incomplete translations.
- UI backgrounds and borders use `ThemeStyle`. The regular `swift test` suite and CI also run the color audit.
  `python3 scripts/audit-theme-colors.py --list` inventories direct colors. Only deliberate native defaults, semantic
  artwork and document colors belong in `Tests/theme-colors.json`, with an exact use count and a reviewed reason;
  missing or stale exceptions fail. Do not add an exception to silence an unthemed surface. This source check cannot
  see AppKit's implicit gray materials: keep headless rendered and layout coverage for complete windows and views.
- Keep AppKit in charge of toolbar controls, panel corners, material masks and focus. Color owned canvases beneath
  native chrome and use glass's public tint; do not insert paint overlays inside native visual-effect materials.
  Check the full native accessory padding, not just the smaller label container. Keep the native scroll-edge
  preference when clipping the file viewport already prevents content from entering the toolbar.
- Inspector text uses `InspectorColors`, including cached attributed strings in Git, Scripts and container cards.
  Keep at least 4.5:1 rendered text contrast against every light/dark panel palette, and preserve native colors for
  System and Increase Contrast. Recolor existing cards without rebuilding them or changing selections.
- `NativeHeaderFillTint` is a guarded compatibility adapter, not a public AppKit tint API. It supports only the
  active/inactive titlebar layer signatures observed on macOS 26. Match structure, not the OS version: later macOS
  versions can retain it. Unknown structures or non-neutral fills must retain native drawing. Never change blur,
  opacity, masks, filters or controls to force a match. Keep native-layer tests for changed signatures, and visually
  check new macOS releases. `ToolbarBackdropTint.prepare` recognizes known header sections at the titlebar edge. Preserve
  their original colors across the window/full-screen move; never extend this lookup into arbitrary content.
- An unshown window cannot verify AppKit's live full-screen compositor. Report headless layout/drawing checks
  separately from visual confirmation in a focused, unfocused or full-screen window; never treat an empty bitmap
  or a borderless fixture as proof of the real full-screen appearance.

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

`docs/destructive-actions.md` lists every destructive action with the code that does it and its tests, and, at the
end, every function `scripts/audit-destructive.py` finds holding a file-changing call. Add a row for a new one, and keep
the rows true when code moves: CI runs the script and fails when a function isn't named.

A new destructive-action test comes with an entry in `Tests/mutations.json`: a one-line change that breaks its rule
(skip the check, read it late, apply it to the wrong item) and the tests that must then fail. Run
`python3 scripts/mutate.py <a word from the rule>` and see it caught before committing; the Mutations workflow runs
them all weekly. When code moves and an entry's text no longer matches, update the entry. Every function the audit
finds must be reached by a mutation, or listed under "Not mutated, and why" in the map with its reason (it makes
Strata's own scratch files, hands work to a function that is mutated, or guards an instant no test can time); CI fails
otherwise.

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
- Saved-state storage defaults to a temporary context with a throwaway key in every build configuration. Only
  `main.swift` opts into application storage, before creating services. Tests inject `SecureStorage.Context` for
  independent stores; never opt into application storage or use the real keychain. Keep authenticated store names
  relative to the injected root and retain the owning History instance through Undo/Redo.
- App preferences also default to a private domain until `main.swift` explicitly selects the application domain.
  Inject `Prefs` with a named `UserDefaults` suite and its own notification center when testing settings. Keep the
  suite alive through persistence checks and remove only that suite afterward. App-owned settings use the selected
  defaults; macOS-wide spring loading and default-file-manager settings keep their explicit system scope. Native
  defaults registration is process-wide even across named suites: keep app fallback values in the typed getters,
  and use an additional private suite when testing inherited preferences.
- Transfer queues own their preferences and History. Keep that owner through archive work, retries and every
  Undo/Redo step, including queued moves across disks. Do not fall back to the global queue from an injected job.
  Active work retains its queue through completion; finished jobs must not form a queue/job retain cycle.
  Queue-held completion callbacks keep panes weak, and one-shot fetch actions release their captures on every
  terminal path. Test teardown while finished jobs remain in the queue.
- Tests that use the real Trash remove exactly what they put there (`tree.removeFromTrash()`). Never empty the real
  Trash: cleanup must match the saved file identity, because a restored item's old Trash path can be reused by
  another file. Cover that reuse explicitly; a historical path alone is not ownership. `Trash.empty(_:)` takes
  the folders, so pass a fake one. Never trash or delete a real Trash, even to show
  it's refused: test the decision (`FileOps.canTrash`, `deletionPlan`) instead. Don't use `NSPasteboard.general` or
  Strata's preferences in tests: clipboard tests set `Clipboard.pasteboard` to a named pasteboard of their own.
- Suites run in parallel and CI machines are slower: poll for a condition, never a fixed sleep; never compare listings
  of shared folders like `$TMPDIR`. `for _ in 0..<n where !done() { sleep }` skips rather than stops, so it only
  works for a condition that stays true once met: after ⌘Z or ⇧⌘Z, whose steps pass through states that can equal the
  one expected, `await FileOps.undoWork?.value` instead (undo and redo work runs there, in order).
- A test helper that blocks (a `Process`, a semaphore) runs on a Dispatch queue, never on the main thread or in a
  `@concurrent` function: other suites' file work waits on those (see `ScratchVolume`, a disk image for moves across
  disks). Suites sharing global state (`RemoteRegistry`, `TransferEngine.hooks`) run as one
  `.serialized` suite.
- A serialized suite does not exclude other suites. Shared fault-injection hooks must match only their own
  fixture's full URL (or its unique temporary parent), never just a basename. Prove an unrelated same-name file
  stays unchanged while the hook is installed. Synchronize shared hook storage and invoke callbacks after
  releasing its lock; resets can overlap workers from other suites.
- The temporary folder is `/private/var/...`. Spell URLs the way `DirectoryLoader` lists them (`TestTree.root` is
  already resolved); `standardizedFileURL` and `resolvingSymlinksInPath` drop the `/private`.
- The test SFTP server (`RemoteFilesTests`, macOS's `sftp-server` over a pipe) isn't confined to its folder: it can
  reach the whole Mac. Never exercise top-level or escaping deletes against it; use `RecordingBackend`.
- View controllers can be tested without a window: `BrowserViewController`, `ColumnBrowserViewController` and
  `BrowserWindowController` (two panes) all load, select and run commands headless.

## Preventing crashes and resource exhaustion

- A crash fix needs a headless regression that calls the real affected reader, decoder, layout or process helper.
  Prove it fails before the fix and passes afterward. Keep these tests in `Tests/StrataTests` so ordinary local
  `swift test`, pull-request CI and the Release workflow all run them. Do not substitute regex checks, source-text
  assertions, or tests of a duplicate implementation for runtime behavior.
- Run the complete debug suite under Address Sanitizer when changing unsafe memory, parsing, indexing or callback
  lifetimes. Use a separate build directory so ordinary and instrumented artifacts stay separate:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --sanitize address --scratch-path .build/sanitizers/address --disable-automatic-resolution --jobs 4`.
  CI runs this as a separate job on pull requests and main; Release repeats it before signing, including on tags.
  Investigate sanitizer diagnostics instead of suppressing them, retrying until green or skipping affected tests.
  Sanitizers do not instrument prebuilt system frameworks or prove unexecuted paths safe. Optimized persistence
  tests also use temporary storage; preferences and other dependencies still need explicit test isolation.
  Apple's Undefined Behavior Sanitizer supports C-based languages, not Swift; accepting the compiler flag is not
  evidence of Swift coverage. Strata currently has no C/C++/Objective-C source targets to instrument with it.
- Treat file contents, authenticated saved data, process output and macOS callback values as external input.
  Validate array shapes, offsets, counts, parent/child links and cycles before indexing or walking them. Verify
  CF type IDs before casts, and finite values and representable ranges before numeric conversion. Exercise empty,
  truncated, malformed, minimum/maximum and just-over-limit inputs alongside ordinary valid inputs.
- Authentication does not prove a saved structure is valid. Preserve valid neighboring records when records are
  independent; reject an invalid linked structure as a whole through its existing recovery path. Never salvage
  unauthenticated bytes or overwrite the saved file just because a read failed. Test older supported formats,
  valid-record preservation and byte-for-byte preservation of the input file. Include real writer → save → reopen
  tests, not only hand-built stored fixtures; validation must include context the writer adds, such as titles and
  filenames in content-search token counts.
- Apply byte, nesting, entry and output limits before allocation or expansion. A time budget cannot interrupt one
  expensive library instruction. Test limits with bounded fixtures, including values on either side of the boundary;
  never deliberately exhaust the machine's memory. For files that could be replaced while opening, inspect the
  opened descriptor and reject nonregular input before reading, as `TextFile.readPrefix` does.
- C callbacks such as `atexit` must be registered from a nonisolated function when the system may call them on
  another thread. A closure created in a MainActor context can assert at runtime even when its body only uses
  thread-safe APIs. Include process shutdown when validating lifecycle changes.
- Use throwing Foundation I/O APIs where available. Swift `do`/`catch` does not catch Objective-C exceptions from
  older APIs. Preserve streaming semantics when replacing an API: cover short pipe output while the writer stays
  open, as well as read failures and EOF. A failed read must not report partial output as success;
  a partial preview must expose its error while keeping rows already read.
- A closed `QLPreviewView` cannot accept another item. Use `QuickLookPreviewView` to own the native view for one
  window lifetime, reject late completions after closing, and create a new native view when moved to another window.
  Cover deferred selection work and rich-preview fallback after closing with a controlled scheduler.
- Assert observable results and unchanged fixture files. Avoid fixed sleeps, wall-clock performance thresholds,
  exact RSS expectations, nondeterministic random inputs and tests that depend on installed apps or live services.
  Synthetic CGEvents must set their own modifier flags before conversion to NSEvent; a nil event source can
  inherit the live keyboard's Shift state and change scrolling axes. Never post fixture events to the system queue.
  Use explicit completion signals, deterministic boundary fixtures and controlled failures. Measure performance
  separately under matched conditions; passing tests establish only the cases exercised.

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
- Shared commands belong in `StrataCommand`: preserve their action/tag identities and existing shortcut overrides.
  Menus keep native responder routing; the palette uses the same validator and revalidates before dispatch. Never
  use a translated title as identity. A captured file command must stay bound to its original pane, folder and
  selection. Test both menu/palette availability and stale actions across view, result and location changes.
- Safety idioms already in use: `lstat`, `O_NOFOLLOW`, `renamex_np(RENAME_EXCL)`, deleting relative to an open folder,
  identity checks before undo (`FileOps.Landed` for ⌘Z, `OperationLog.identity` for History). Reuse them: an undo
  that trashes or moves items must check each is still the one the operation left there.
- A decision that needs a window to ask in must not go ahead when there's none (it closed meanwhile): fall back to
  what changes nothing, as `uploadChoice` does.

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

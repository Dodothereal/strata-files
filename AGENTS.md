# Strata: notes for coding agents

Strata is a native macOS file manager (Swift, AppKit, SwiftPM; macOS 26, Apple silicon). People trust it with their
files: a bug that deletes, trashes, moves or overwrites the wrong thing is the worst bug it can have. Read the rules on
destructive actions below before changing anything that touches files.

## Layout

- `Sources/Strata/` — the app, one folder per area: `Browser` (the file list and its commands), `Views` (Icons,
  Columns, Gallery, Disk Usage), `Window` (windows, panes, sidebar wiring, Compare & Sync), `Transfers` (copy/move
  jobs, conflicts, archives), `Model` (FileOps, Trash, History in `OperationLog`, SecureStorage), `AI` (Ask Strata
  plans), `Remote` (SFTP and S3), `Containers`, `Dev` (git, project cleanup), `Index`, `Sidebar`, `Settings`, `App`,
  `Support`, `Previews`. `Package.swift` compiles the lower-level layers as internal library targets (`StrataSupport`,
  `StrataTheme`, `StrataModel`, `StrataPreviews`, `StrataIndex`) imported by `Strata` so module boundaries and
  `IndexStore`'s private storage are enforced by the compiler.
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
  another file. Cover that reuse explicitly; a historical path alone is not ownership. Keep parked originals alive
  through this cleanup too, so their file identities cannot be reused before the checks. `Trash.empty(_:)` takes
  the folders, so pass a fake one. Never trash or delete a real Trash, even to show
  it's refused: test the decision (`FileOps.canTrash`, `deletionPlan`) instead. Don't use `NSPasteboard.general` or
  Strata's preferences in tests: clipboard tests set `Clipboard.pasteboard` to a named pasteboard of their own.
- Suites run in parallel and CI machines are slower: poll for a condition, never a fixed sleep; never compare listings
  of shared folders like `$TMPDIR`. `for _ in 0..<n where !done() { sleep }` skips rather than stops, so it only
  works for a condition that stays true once met: after ⌘Z or ⇧⌘Z, whose steps pass through states that can equal the
  one expected, `await FileOps.undoWork?.value` instead (undo and redo work runs there, in order).
- Use continuation signals for asynchronous test work that is guaranteed to start. A background polling deadline
  can expire while main-actor request tasks are still queued behind other suites. When a negative-path mutation
  intentionally prevents a callback, keep its bounded condition polling on the request tasks' actor.
- Cache freshness tests inject a clock and advance it explicitly, including expiry boundaries and delayed reads.
  A test runner resuming within a real-time cache lifetime is not a reliable synchronization condition.
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
  evidence of Swift coverage. `CArchivePreview` and the standalone `StrataArchiveWorker` are C targets; exercise
  their real parser callbacks with Address Sanitizer and Undefined Behavior Sanitizer when changing them.
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
- Pipes written by the app must suppress `SIGPIPE` on their own descriptor before use (`F_SETNOSIGPIPE`). A child
  can close its input after a connection check; a throwing write alone does not prevent process termination.
  Test the actual transport with a closed-reader fixture and keep the signal policy local to its descriptor.
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
- Browser entries, filtered rows and path lookup belong to `BrowserListing`. Preserve node identity on refresh,
  create fresh roots on navigation, and validate a whole result update before changing any node. Keep native
  selection, expansion and editing in the AppKit controller; publish entries before applying pending actions.
- Sort choices and comparisons belong to `BrowserOrdering`, with cached metadata supplied by its owner. Results
  retain incoming order until a column is selected; late metadata must not impose the previous folder's order.
  Returning to a folder restores its choice, and programmatic choices must not write preferences through a native
  descriptor callback. Keep native headers and row animation in AppKit. Refresh changed child orders even when
  roots do not move, preserving expansion and selection. Defer metadata ordering during a native inline edit and
  apply it when editing ends. Batch directory totals per pass and never cache an
  unknown size across passes; test read counts and results with injected metadata, not elapsed-time thresholds.
- `BrowserPresentations` owns lazy view creation and attachment. Feed alternative views through
  `FileCollectionController.apply` with the same sorted/filtered content; each view keeps its native selection
  policy and requests only the metadata it needs. Metadata and view callbacks must keep the browser weak.
  Preserve cached views, safe-area placement, theme refresh on reattachment and native responder routing.
- Browser windows, panes, sidebars and View Options use the preferences and notification center in `BrowserServices`.
  Pass those settings into native file views, typography, rename fields and favorite operations; an injected pane
  must not read or change another environment's settings. Production windows share the application services.
  App-wide theme/material integration retains its application scope. Test independent settings with native headless
  views, including updates to cached views and deeper columns, rather than temporarily changing shared preferences.
- Asynchronous server/container navigation belongs to the originating pane's `FolderOpenSession`. Replacing its
  request, navigating (including deeper Columns), closing the pane or closing the window cancels that ownership.
  Focus changes alone keep the request with its pane. Native Cancel buttons target their captured request; old
  successes, failures and listing notices cannot replace a newer request or navigate another pane. Test held I/O
  in both completion orders and keep the window weak while waiting.
- Connect to Server's selected protocol and recent shares belong to `BrowserServices.connectionSettings`. Preserve
  the `connectKind` and `recentServers` formats, password removal and ten-address limit. Inject those settings into
  new and editing sheets; headless settings tests must not mount shares, connect servers or read the real keychain.
  Share requests belong to the sheet's `ServerMountSession`. Detach an old request before cancellation and accept
  results only from the current request; late results must not alter controls, navigate or save recent addresses.
  Keep the sheet weak across mounting and cancel when it is released. Inject `ServerMounter` for native headless
  button/lifetime tests, including failure, cancellation, replacement and both completion orders.
- Saved searches belong to `BrowserServices.savedSearches`, including saving from the active pane, sidebar removal
  and change notifications. Keep their existing preference format and distinguish searches by query and scope as
  well as name. Compare reads the owning window’s current hidden-files setting each time it scans.
- Expanded sidebar watchers belong to `FolderWatchers`. Release their shared allowance when a tree closes,
  collapses folders or becomes inactive. Count successfully opened physical directories, including both Applications
  roots; never evict another tree's watchers. Tests inject an independent budget and expand native headless outlines.
- Folder read scheduling belongs in `DirectoryReadSession`: each presentation owns its generation, rejects late
  success and error responses, and invalidates reads when removed or replaced by results. Inject `DirectoryReader`
  for controlled completion tests; keep callbacks weak so pending I/O cannot retain closed browsers.
  Explicit Reload invalidation and the following listing belong to that same cancellable request. Check cancellation
  after invalidation; an old Reload must not start a read after navigation or a newer Reload.
  Preserve ordinary refresh selections when entries are applied, so choices made during I/O are retained. Keep
  explicit pending selections (including an empty selection) distinct from that preservation fallback.
- `BrowserLoading` owns folder state, expanded-row reads and free-space work. Invalidate child reads before reusing
  rows; coalesce them by node identity, and keep that identity alive until the read ends. A late response cannot
  clear its replacement. Keep free-space results with their folder, including when applying entries navigates again.
  AppKit marks entries applied only when it displays them; completing a read during native editing is not enough.
  Inject the capacity reader through `BrowserServices` for deterministic footer tests.
- Common reads of server and container copies go through `CopyProvider` / `CopyProviders`. Keep each URL with its
  owning provider, propagate fetch/preparation errors, and retain the existing bounded selection-prefetch policy.
  Provider-specific write, permission and archive behavior stays in its implementation. Inject providers or server
  services for tests; never let a fixture fall back to a live connection.
  `BrowserServices.copies` and its default directory reader share the window's server environment. Inspector folder
  links prepare their path through that owner and navigate through the originating pane's `FolderOpenSession`.
  Provider cache paths must not become remembered local locations or draggable window-title URLs.
  Shared browser fetching lives in `BrowserViewController+Fetching` and queued preparation in `CopyFetchJob`.
  Both retain the supplied providers through completion, placeholder checks and error messages. Install a job's
  task before notifying observers, since a callback can request Stop. Cancelled work never delivers a completion
  action or a late failure message. Small reads keep browsers weak and do not present an error after closure.
  Selection prefetch keeps its 20-item/256 MB limits and ends on replacement, navigation or pane closure.
  Media-column readers use the same provider owner and `BrowserServices.mediaReader`. Recheck placeholder state
  when queued work starts and before publishing metadata; do not reuse cached dimensions for an invalidated copy,
  and cancel an in-flight read when its copy becomes a placeholder. Fetched placeholders start media reads for
  active media sorts. Preserve the four-reader bound, deduplication and empty-result caching. Cancel owned work
  when its loader, pane or listing closes, and test replacement reads and reentrant callbacks with held completions.
  `BrowserServices.thumbnails` and `BrowserServices.itemInfo` share that provider owner and media reader across List,
  Icons, Columns (including deeper columns and the preview pane), Gallery and Quick Look transition images. Browser
  folder-size checks (`folderSize`, `sizeText`, `canMeasure`) also consult the owning providers. Evict cached
  thumbnails and item info, cancel in-flight requests, and avoid recording Quick Look failures or fallback byte sizes
  when a copy becomes a placeholder; refresh visible cells, column previews and gallery previews when placeholders
  are fetched.
  `InspectorViewController` also receives `BrowserServices` and passes `services.preferences` to its cards. Use
  `services.copies` and `services.remote.copies` for read-only copy gating (project, Compose, tags, Get Info),
  server titles and `Where` rows, single-item and multi-selection folder sizing (`browser.canMeasure` even for the
  unselected current folder), image dimensions, document summaries, and Rich/Quick Look previews. Skip symlinks and
  placeholders, refresh metadata, summaries and previews when `.containerFilesFetched` arrives for a fetched item in
  the owning provider, and commit any active comment edit before hiding Get Info.
  `BrowserServices` owns its `Clipboard`, `CopyProviders` (`remoteCopies`, `containerCopies` and `clipboardRoot`),
  `ContainerFiles` and `ContainerStore`, and passes them to `TransferQueue`, `TransferJob`, `RemoteUploadJob`,
  `BrowserViewController` (server and container commands, deletion plans, clipboard staging, `Copy Path`, archive
  checks, drag/drop), `InspectorViewController`, `PathBar` and every presentation (`FileOutlineView`, Icons, Columns,
  Gallery, Disk Usage, Sidebar). Verify recursive placeholder absence after `prepareForCopying` and before clipboard
  staging; use a `.data` file-promise type when dragging symlinks from a copy. Scope `.containerCopyProblem`
  notifications to their owning copy root.
  Asynchronous browser and window actions (`browseArchive`, `openArchiveAsFolder`, `open(_:fileOpener:)`,
  `open(_:withApplicationAt:opener:)`, `openQuickLook`, Connect to Server sheet's `onConnected`/`onServer`) keep their
  originating pane and `BrowserViewController.navigationRevision`. Navigating away (including returning to the same
  folder), entering a deeper column, showing results/messages or closing the pane cancels `actionFetch` and suppresses
  stale completions; deferred Quick Look also verifies window visibility and selection membership. Closing a pane
  (`stopBackgroundWork()`) stops active and cached presentation work in `ColumnBrowserViewController` and
  `GalleryViewController` alongside directory watchers, git observation and deferred resort work.
- `RemoteFiles` and its `CopyProvider` adapter use the same `RemoteCopyStore` for server lookup, paths, placeholders,
  download staging and removal. An injected backend must not fall back to the application's copy root. Test identical
  server IDs in independent roots, including refused cross-environment writes and scoped cleanup. Prepare and remove
  cache children relative to an opened root without following a replacement symlink; invalid IDs change nothing.
  Validate every source in a remote delete/move batch before connecting or changing files. An unsupported later
  source must not turn an up-front refusal into a partial operation.
- Remote credentials use an injected `RemoteKeychain` / `KeychainAccess` boundary. Update existing secrets in place;
  do not delete a working secret before saving its replacement. Only a missing item permits creation, and a
  concurrent creator permits one scoped update retry. Keep the native service/account format and an existing
  item's access policy. Credential tests use independent in-memory Security implementations, never the real
  keychain, and assert unchanged neighboring items on errors and deletion.
- Remote session pools inject server lookup, backend creation and status delivery. Only an attempt's producer may
  publish or close its result; disconnect removes pending work before cancelling it, and late completion must not
  erase a replacement attempt. Recheck ownership after status callbacks. Tests use independent pools and controlled
  backends, including cancelled attempts, late failures and dropped connections; never fall back to live credentials.
- Window-level server access belongs to `BrowserServices.remote`: saved definitions, status, connection sheets,
  session pools and copies must come from the same environment. Scope saved-server, status and disconnect
  notifications by owner even when environments share a notification center. Keep workspace planning and tooltips
  with that owner; a missing local server copy is a waiting server folder, not a missing local folder. Test identical
  IDs with independent credentials and roots, both sidebar modes, native sheets and both panes without live services.
- Cancelling a server reader cancels only its waiting ticket. Keep a shared login alive for other panes; retire and
  cancel it when its last reader leaves. A retry must not join an abandoned attempt, and a late result must not
  publish over its replacement. Once published, the backend belongs to the pool, even if its original reader cancels.
  Browser and workspace Cancel actions cancel their own requests, never disconnect by server ID. Check cancellation
  after resolving a starting folder too, before applying navigation. Test native buttons with held fake I/O.
- Providers backed by a session pool receive that pool through `RemoteFiles(sessions:)`. A failed read may retire
  only the exact backend it acquired, through that owner. It cannot disconnect a replacement, cancel a newer login
  or revoke a publication reservation. Ordinary operation errors keep the connection; test late timeouts and
  identical server IDs in independent pools without a live server.
- Connect to Server authenticates proposed settings through `RemoteConnections` before saving credentials or
  changing the registry. Cancel by request identity; never roll back another attempt's settings by server ID.
  Serialize cache retirement and publication per server, with a revocable pool reservation. Readers must fail
  promptly during that handoff because cleanup can await their completion. Keep the pool and copy cache in the
  same environment, recheck ownership after every suspension, and test both orders of late completion with fake
  backends and credentials. Sheet teardown cancels its request; published backends belong exclusively to the pool.
- Explicit server disconnect and removal use the same per-server handoff queue as connection publication. Register
  retirement before notifying saved-setting observers, keep automatic readers blocked through cache cleanup, and
  refuse confirmations whose saved definition has changed. Cancelling a waiter must not abandon accepted cleanup.
- Saved server stores own preferences, credentials, registry and notifications. Publish the complete new state before
  notifying observers; removal must not delete credentials after an observer has saved a replacement. Invalid or
  unreadable saved definitions must not rewrite preferences merely by being read.
- Listing coalescing and freshness belong in `CopyListings`, owned by each provider actor. Invalidation during a
  read requires another read; an old waiter cannot clear its replacement or make it fresh. Drain listings before
  removing a copy. Inject container listing readers or server backends to test held responses without live services.
- Shared copy downloads use `CopyFetches`, owned by their provider actor. Cancellation belongs to one waiting
  caller; stop the download only after the last caller stops. Keep cancelled tasks until they finish, drain both
  explicit and background downloads before removing a copy, and coalesce overlapping removals. Late cleanup must
  not clear a reopened copy's requests. Inject container content readers for controlled lifecycle tests.
- Index columns belong to `IndexStore.Storage`: borrow them inside `read`, mutate them inside `write`, and keep
  related column changes in one write scope. Never reenter the same store's lock from a scope. Returning a column
  creates a copy-on-write snapshot; avoid those copies in hot paths. Raw column pointers must stay inside
  `withColumns`, with parallel searches joined before the scope ends. Keep compact storage and buffer-growth tests.
- Post-operation selection and rename wait for entries to be applied, not an elapsed delay. Keep the original pane
  and navigation revision; leaving and returning is still a different navigation. Cancel pending renames when their
  column is removed, explicit selection or mode changes, or its read fails. A reload dropping the old selection must
  still allow the newly created item's pending rename. Preserve each view's selection policy, including
  Gallery's preview item. A listing deferred during native inline editing must still match the current read generation.
- Workspaces belong to `BrowserServices`, including saved preferences, change notifications and open-window lookup.
  New tabs and restored workspace windows must keep that owner through `BrowserWindows`; production still uses
  AppKit's native tab/window presentation. Native menu choices and sheets retain their originating store and keep
  windows weak; a focus change or closed window must not redirect a pending save/update into another environment.
- Shared commands belong in `StrataCommand`: preserve their action/tag identities and existing shortcut overrides.
  Menus keep native responder routing; the palette uses the same validator and revalidates before dispatch. Never
  use a translated title as identity. A captured file command must stay bound to its original pane, folder and
  selection. Test both menu/palette availability and stale actions across view, result and location changes.
- Safety idioms already in use: `lstat`, `O_NOFOLLOW`, `renamex_np(RENAME_EXCL)`, deleting relative to an open folder,
  identity checks before undo (`LandedFiles` for ⌘Z, `OperationLog.identity` for History). Reuse them: an undo
  that trashes or moves items must check each is still the one the operation left there.
- A decision that needs a window to ask in must not go ahead when there's none (it closed meanwhile): fall back to
  what changes nothing, as `uploadChoice` does.
- Undo cleanup for folders an operation creates must verify their recorded identity and use nonrecursive empty-folder
  removal. A failed directory listing is not an empty folder. Cover replacement files, folders and symlinks, including
  anything at the link's target; never use recursive removal for this cleanup.
- `CreatedFolders` captures that ownership when folders are made, before alerts or asynchronous transfers, and is
  shared by live Undo, History and cancellation cleanup. Redo records the folders it recreates and updates their
  saved History identities. Old records without container identities may restore files but must not remove those
  folders. Read and remove Finder records relative to an owned, opened directory; never follow a cleanup symlink.
- Retrying a failed transfer must retain its destination and parent identities from the failed attempt. A replacement
  file, directory or redirected parent is not the incomplete copy. Cover both safe refusals and successful repair of
  retained fragments, missing destinations and nested failures. Directory metadata copying can change birth time:
  retain the original descriptor through cleanup instead of adopting the cleanup pass's reopened pathname.
- History panels receive their store and native Undo manager from the application owner. Observe only that store,
  and keep both dependencies through a requested Undo even if the panel closes. A delayed alert must not clear a
  different History. Headless panels disable native frame autosaving and never show error sheets.
- Browser file commands use `BrowserServices.files`, which retains the transfer queue's History, preferences and
  providers. New File, New Folder, Rename, Trash, project cleanup and Ask Strata must keep that owner through
  native Undo/Redo and sheets. Capture creation identities before History notifications can replace an item.
  `BrowserRename.decision` is separate from its native confirmation; commits recheck navigation and item identity.
- Construct application services through `BrowserServices.shared`, or build independent stores and providers with
  `BrowserServices.isolated`. Custom composition is explicit through `configured`: its queue supplies preferences,
  History and copy routing. Never mutate a supplied queue when constructing a window; copy routing is immutable.
- Transfer results are journaled by `TransferJournal` after each completed pass. Native Undo and History share the
  same receipt: a repaired copy updates its captured identity, and a finished move replaces its copy classification.
  Never extend a record whose Undo has started, whose action has been replayed, or which History has cleared.
  Resolve History buttons by the current saved entry ID before acting; a captured row can predate a retry.
- File identity reads belong in `FileIdentity`, and live operation ownership belongs in `LandedFiles`. Preserve
  no-follow reads and record identities when items land, before callbacks can replace them. Runtime identities include
  birth time; History retains its volume UUID/inode and legacy device:inode formats. Do not silently change those
  saved representations or replace a same-disk expectation with an identity read later.
- Pass captured `LandedFiles` into History registration after asynchronous work or callbacks. Converting to saved
  identities must still match that ownership; a failed match gets an explicit refusing key, never an absent key
  that would enable legacy existence-only Undo. Cover saving, reopening and a replacement arriving before logging.
- Keep `StrataSupport`, `StrataTheme`, `StrataModel`, `StrataPreviews` and `StrataIndex` free of upward dependencies on
  `Browser`, `Window`, `Transfers`, `Remote` or `Containers`. `FileThumbnails` and `ItemInfoLoader` resolve container
  and Compose stack icon marks and status text from their injected `CopyProviders` and `ContainerStore`; `FileDrop`
  and `ShelfWell` use their injected or active window's `CopyProviders` without falling back to global copy stores;
  and `PathSuggestions` reads `showHidden` from its injected `Prefs`.

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

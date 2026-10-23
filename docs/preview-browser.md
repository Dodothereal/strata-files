# Folder and archive previews

Space opens a native, temporary preview of the selection. Folders and archives expose their contents without
changing the originating browser's folder, selection, scroll position or view mode. Selecting a child previews it
alongside the tree. Text editing keeps its normal keys; Escape closes the preview and restores the source view.

The feature uses the originating BrowserServices environment. Preview navigation is read-only. Open, Show in Strata,
Copy and extraction are explicit actions on captured items. Closing, replacing the selection, navigating the source
pane and closing that pane cancel its work and reject late completions. No preview starts a recursive index scan.

Theme consistency is part of the foundation: use ThemeStyle for owned backgrounds, existing file cells and injected
typography, native AppKit window chrome and split views, and native control styling. Check light, dark, every palette,
high contrast and selected/unselected text before the first feature commit. Appearance changes must recolor the
existing preview without replacing its content or losing selection. A preview never changes browser view settings.

## Implementation stages

Each completed stage is a separate feature commit. Review its diff, ownership, security boundaries and applicable
coding rules, fix findings, run its regression tests and required mutations, extract localization, check every
catalog, and run the source audits before moving to the next stage.

1. Native Space preview: folders, lazy child loading, embedded file previews and non-extracting archive listings.
2. Filtering, sorting and explicit actions: Copy, Copy Path, Open and Show in Strata; stable source pane and item ownership.
3. Photo browsing: native icon collection, visible thumbnails, size control and an independent list/icons choice.
4. Selective archives: bounded single-entry previews and copy-out, password requests, owned temporary files and
   cancellation. Listing an archive must never invoke full-archive extraction.
5. Size reporting: distinguish logical size from allocated disk space, including sparse files; recursive measurement
   is explicit, cancellable and does not follow links.
6. Provider support: remote and container listings and individual content fetches use the owning environment,
   respect cancellation and never download an entire folder for a preview.

## Verification

Cover native keyboard dispatch in List, Icons, Columns (including deeper columns), Gallery, Disk Usage, results and
both panes. Tests keep preferences, clipboard, History, caches, credentials and providers isolated. Hold reads and
deliver their completions out of order to prove stale work cannot change a replacement preview or another pane.

Destructive operations and scratch cleanup belong in the destructive-action map with tests and mutation evidence.
Exercise malicious archive paths, links, duplicate members, replacement identities, passwords, oversized streams,
incomplete output and failed cleanup. Keep parsing, cancellation and callback-lifetime coverage under Address
Sanitizer, and verify the full suite in Debug and optimized Release at the end.

Native headless layout checks establish view structure and rendering. They do not establish the live compositor's
appearance. GUI checks must not manipulate the installed Strata or change the user's preferences.

## Progress

- Branch created from the current remote main at c7a2822.
- Foundation implemented and reviewed.
- Review fixes: bound local enumeration before allocating rows; reject malformed provider batches; preserve physical
  Applications paths; avoid duplicate archive listing in the detail pane; close and cancel on pane navigation,
  teardown and refused presentation. Preview work keeps its source pane weak. Partial archive listings retain their
  limit notice in the footer.
- Focused verification: 19 tests pass, including native Space dispatch across all five views, both panes and deeper
  Columns; cancellation/replacement, read limits, real archive listing, Quick Look lifetime and 36 palette/appearance
  combinations. Font and palette changes preserve the selected row and existing text renderer.
- All 22 translation catalogs are complete (1,422 strings); 44 localization/resource regression tests and both
  source audits pass. Native headless windows remain unshown throughout these checks.
- The complete Debug suite passes under Address Sanitizer: 914 tests in 111 suites, without sanitizer diagnostics.
  All four foundation/provider-preparation mutations are caught in a temporary checkout, removed afterward.
- Foundation commit: `bfabab1`.
- Filtering, sorting and actions implemented and reviewed.
  Filtering reuses the existing sort, preserves pending explicit reads and never discovers more folders. Native
  headers and the actions menu offer Name, Kind, Date Modified and Size without writing browser sort settings.
  Copy, Copy Path, Open and Show in Strata retain their preview item, session and originating pane. File and parent
  identity checks refuse replaced paths; an old menu cannot act on a newly opened preview of the same path.
- Review fixes: prevent file-editing commands and file Undo from falling through to the browser behind the panel;
  keep normal text editing; close Space previews from read-only content while allowing spaces in editable fields;
  avoid recursive native window closing; release closed outline rows; retain partial-listing notices during filtering.
  The new controls retain native search bezels and render on the existing content surface in all 36 appearance cases.
- Additional security review: automatic file renderers accept only current regular files, refusing named pipes and
  replacement links before any rich or native renderer starts. The real view regression passes for both cases.
- Focused action verification: nine action/sorting/window tests and the theme test pass; the broader 31-test preview,
  provider-clipboard and Quick Look regression selection also passes. All 22 catalogs contain 1,425 complete strings.
- Final action verification: the complete Debug ASan suite passes 924 tests in 112 suites; the final 30-test ASan
  selection also covers the added special-file and late-fallback cases, with no sanitizer diagnostics. All seven
  action/sorting/provider-path/renderer mutations are caught. The 44 Python regressions, catalogs and source audits
  pass, and temporary verification checkouts are removed.
- Actions commit: `8694811`.
- Native Icons implemented and reviewed. Use the existing
  GridLayout, GridItemView, typography, thumbnail owner and ThemeStyle canvas. Preview mode and icon size have their
  own preferences. Internal folder navigation, Back and Command-Up retain the source browser; switching modes
  preserves a selected descendant and expands its already-loaded ancestors. No folder measurements start here.
- Grid review fixes: clear hidden selections, use the active view for keyboard focus, cancel pending folder reads
  when going back, keep palette/font changes in place, and cancel offscreen/closed/reused cells. Eight concurrent
  thumbnail requests share the preview allowance; failures, cache hits and placeholder invalidation return it.
  Resizing within a size bucket keeps the existing request/image. Oversized callback images are rejected before
  cropping or display with checked byte-cost multiplication.
- Grid checks: 46 preview/thumbnail/provider tests pass, including native arrows, Return, Command-Up and Space,
  private preferences, cancellation, coalescing, cache and image-size boundaries. The 36-case theme fixture uses
  real native collection cells and verifies the drawn owning canvas plus AppKit's collection background binding;
  selection, cell and thumbnail identities survive. These remain headless checks, not a live compositor check.
- Final grid verification: 936 tests in 113 suites pass under Debug ASan; the final 31-test ASan selection and
  20-test native selection pass after adding the command-palette responder guard. All seven grid mutations are
  caught, all 44 Python regressions pass, 22 catalogs remain complete and both source audits pass. The preview
  cannot open the underlying browser's file-command palette while it has focus.

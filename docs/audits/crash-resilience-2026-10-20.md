# Crash resilience review, 20 October 2026

Baseline: `1a72127` on `main`. Changes are on `audit/crash-resilience`.

This was a repository-wide risk inventory followed by detailed inspection and headless
reproductions of the highest-risk paths. It is not a proof that every execution path is
crash-free. No installed app, live user window, preferences, History or index was used as
a test fixture. Tests use their existing isolated stores and temporary files.

## Scope

The inventory covered 190 app source files and the two CLI source files. Searches covered
fatal errors, forced casts and unwraps, integer conversions and arithmetic, raw buffers,
Core Foundation values, continuation completion, callback ownership, process pipes,
external-data parsing and allocation limits.

Detailed inspection covered:

- Preview format selection, text, JSON, archives, Markdown and SQLite.
- File index storage, persistence, search, events and content-search passages.
- Git subprocesses, SFTP packet parsing and shutdown, S3 downloads, container HTTP and tar parsing.
- Secure storage, operation History, transfer decisions, undo and existing destructive-action coverage.
- Collection layout, thumbnails, Dock accessibility, toolbar compatibility adapters and window lifetimes.
- Update bundle metadata, feed-address checks and generated build resources.

The 97 explicit `fatalError` sites found in the app are unavailable coder initializers
for programmatically created views/controllers. No reachable storyboard-loading path was
identified for them. They were not mechanically replaced. Constant regex construction,
known NSImage copies, and guarded native-layer access were also distinguished from
unchecked external input.

## Findings fixed

| Area | Failure and evidence | Change and regression coverage |
| --- | --- | --- |
| JSON previews | Indentation expands a small document disproportionately. Three bounded tests failed before the fix; no deliberate system OOM was attempted. | Keep original text beyond 64 nesting levels or the formatted-output budget of 1,048,576 UTF-16 units. Cover complete/truncated nesting, repeated values, Unicode and exact numeric text. |
| Archive previews | Folder aggregation crashed the test process with two `Int64.max` sizes. Date conversion, implicit folders and path depth were also unchecked. | Saturating totals, nonnegative sizes, checked dates, maximum depth 128 and maximum 100,000 nodes. Show the existing partial-preview note when limits exclude entries. |
| Deep path search | More than 255 matching ancestors overflowed a byte counter and crashed the test process. | Use wider counters for long queries only. Test 1, 254, 255, 256 and 300 levels, missing ancestors and named scopes. Ordinary queries retain their byte counters. |
| Icons layout | An infinite layout rectangle crashed during conversion to integer rows. | Clamp to actual rows before conversion; reject invalid hit-test coordinates and normalize nonfinite icon sizes. Preserve ordinary hit testing and row geometry. |
| Dock geometry | Wrong AXValue kinds were accepted as a zero rectangle. Other CF objects were blindly cast before passing them to AXValue APIs. | Check CF type IDs, conversion results, finite coordinates and positive dimensions. Tests use synthetic values, without reading or moving the live Dock. |
| File-index persistence | Ten structurally invalid but authenticated indexes were accepted. Invalid offsets and cyclic links could reach raw-buffer reads or tree walks. | Validate bounds, parent order, roots, child ownership, linked membership and nonnegative sizes. Reject invalid stores through the existing rebuild path. Preserve deleted entries and 200,000-entry growth/round trips. |
| Content-index persistence | Malformed keyword arrays or lengths crashed the test process during scoring. | Skip malformed documents before allocating rows. Validate array shapes, lengths, page marks and vector dimensions/finite values; use unaligned-safe packed reads. Valid neighboring documents remain searchable. |
| Text and bundle metadata | A FIFO named like text was consumed by a preview; an empty FIFO could instead block. The bundle reader separately checked a path and then read it without a byte bound. | Open nonblocking, inspect the opened descriptor, accept regular files only, then read a bounded prefix. Bundle metadata shares this reader. Tests preserve FIFO bytes, regular files, links and bundle behavior. |
| Process output | Reading a closed pipe through `availableData` raised an uncaught Objective-C exception and aborted the test process. | Use throwing reads. Git reports a failed run if output cannot be read, rather than accepting partial output as success. SSH diagnostic reads end safely on failure. Cover closed pipes, ordinary output/EOF and existing Git/remote integration. |
| SQLite previews | A view allocated a 16 MiB value despite the existing query timeout; the test expected refusal and failed. This was a bounded reproduction, not an OOM test. | Set an 8 MiB SQLite value/row limit. Oversized values use the existing preview error presentation while retaining earlier rows. Test the exact boundary, stored and computed values, and ordinary tables/views without changing the database or creating sidecars. |
| History decoding | Saved move/replacement arrays with 0, 1 or 3 elements were accepted, although undo indexes exactly two elements. | Reject malformed pairs while decoding; skip invalid independent records while preserving valid neighbors, their order and older formats. Never rewrite History while loading or salvage unauthenticated bytes. Test truncated JSON, malformed records and tampered ciphertext; removing the pair check is caught by the regression tests. |

The persisted-data cases use intentionally malformed, correctly encrypted fixtures.
They do not demonstrate bypasses of SecureStorage authentication or remote access to
those stores. The checks protect readers from invalid structures produced by a bad writer
or earlier build, in addition to the existing cryptographic integrity checks.

SQLite's limit is a deliberate preview trade-off: a legitimate individual value above
8 MiB is refused even when the overall database is otherwise valid. Rows read before the
failure remain visible alongside the error. The database itself may be much larger.
SQLite also applies this limit when encoding whole rows, but a stored row whose separate
values each fit can still be read without constructing that combined encoding. Tests
cover both cases: [SQLite implementation limits](https://www.sqlite.org/limits.html).

A native SQLite fixture confirmed that `length(blob)` and `octet_length(text)` can read
metadata for stored 16 MiB cells under the limit. That does not establish a safe generic
placeholder implementation: views and computed columns can allocate before a size check,
and rewriting their expressions can change evaluation behavior. This patch retains the
explicit error rather than changing arbitrary queries. A more permissive stored-table
preview would be separate work with its own type, schema and expression coverage.

## Prevention

The regressions are runtime tests in the ordinary Swift suite, so local development and
pull-request CI exercise the real readers and helpers. No source-pattern linter was added.
`AGENTS.md` now requires before/after reproductions, boundary fixtures, saved-data
validation and preservation, allocation limits before expansion, throwing I/O and
observable behavior assertions. It excludes fixed sleeps, memory/timing thresholds and
source-text assertions as substitutes for behavioral regression tests.

Release previously ran localization validation but not the Swift suite. It now runs all
Swift tests before importing signing credentials on both tags and manual runs. Address
Sanitizer also runs the full suite in a separate CI job and before signing a release.
CI runs when that release workflow changes. This blocks release on a failing regression;
it does not prove that untested inputs or platform behavior cannot fail.

## Validation

The baseline passed 437 Swift tests in 51 suites. The final run passed 471 tests in
62 suites, including 34 new regression tests and their parameterized edge cases.
Five before-fix reproductions terminated their test processes: archive totals, deep path
search, unbounded grid layout, malformed content-index scoring and closed-pipe reads.

Final checks:

- Full Swift suite: 471 tests passed in 42.417 seconds.
- Optimized app build: passed with all fixes, including independent History-record decoding.
- Python build/localization/resource tooling: 39 tests passed.
- Localization extraction: 1,417 strings, no new or removed keys; completeness passed.
- Destructive-action audit: all 117 discovered functions documented and covered by a mutation or a stated exemption.
- Theme-color audit: passed, with the existing 61 reviewed exceptions.
- History pair-validation mutation: caught again with the independent-record loader; the original source was restored.
- Workflow YAML: both modified workflows parsed successfully; hosted execution is pending a push.
- Whitespace/error checks: `git diff --check` passed.

Useful commands:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --product Strata
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -m unittest discover -s Tests -p 'test_*.py'
python3 scripts/localize.py check --all --complete
python3 scripts/audit-destructive.py --check
python3 scripts/audit-theme-colors.py
python3 scripts/mutate.py 'Malformed History'
```

The full weekly mutation matrix was not rerun. The new rule was exercised directly, and
the existing matrix was checked for coverage and matching source text.

## Address Sanitizer follow-up

At `9a73d46`, the complete debug suite passed under Address Sanitizer: 471 tests in
62 suites, in 84.387 seconds after a 58.01-second instrumented build. No Address Sanitizer
diagnostic or test failure was reported. The testable app's index-persistence object
contained ASan checks, and the built app linked the ASan runtime. A separate temporary
Swift control program with a deliberate use-after-free failed with the expected
`heap-use-after-free` report and exit status 1, confirming runtime detection on this Mac.
The control program was outside the repository and did not touch app data.

Reproduce locally with Xcode's toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --sanitize address --scratch-path .build/sanitizers/address --disable-automatic-resolution --jobs 4
```

The local toolchain was Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), using the macOS 27 SDK.
CI remains pinned to its existing Xcode 26.6 selection; the first hosted sanitizer run
is pending a push. The instrumented build directory is separate from ordinary builds.
No sanitizer suppressions, excluded tests or retry-until-pass behavior were added.
Debug configuration preserves the existing temporary History/index/key isolation.

The Swift compiler accepted a minimal `-sanitize=undefined` probe, but that is not
proof of UBSan coverage. Apple documents Undefined Behavior Sanitizer as supporting
C-based languages, not Swift. This package has no C/C++/Objective-C source targets;
its system libraries and Sparkle are prebuilt. No UBSan coverage is claimed or added
as a nominally passing CI job: [Apple sanitizer documentation](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early).

ASan covers memory-access bugs on instrumented paths exercised by these tests. It does
not prove freedom from crashes, cover every system-framework implementation, detect
all races or substitute for live-platform testing.

## Performance and remaining limits

File-index validation is linear in the number of entries and links, once per load. Its
temporary linked-entry bitmap uses roughly one byte per entry, plus a small set of roots.
Content-index validation also happens while loading; no checks were added to each
ordinary search result. Deep path queries alone use wider progress arrays.

The full-suite runtime is not a performance benchmark. Its existing fake-S3 download
test took 20 seconds in the baseline, 137 seconds in the first final run and 19 seconds
in the final verification. A sample of the slower run showed work in
`NSURLSession.AsyncBytes.Iterator` and `S3Client.download`, including executor hops.
That code was not changed here. The byte-at-a-time download loop is a follow-up
profiling target, but these variable debug-test timings establish neither a regression
nor real-network throughput. Reproduce under matched conditions in an optimized build
before changing transfer behavior.

These checks do not cover every live macOS compositor transition, accessibility service
response, filesystem driver, third-party parser or network-failure timing. Quick Look,
PDF/media decoding, SQLite and other system frameworks retain their own failure modes.
There was no extended GUI soak, real-server fault-injection campaign, whole-repository
fuzzing or Thread Sanitizer run. The full-suite Address Sanitizer result is recorded above. Existing SDK deprecation and nested-capture warnings remain; no
new compiler warning was introduced by these fixes.

The guarded private toolbar tint remains a compatibility risk requiring visual checks on
new macOS releases. Its existing structural fallback and headless tests were preserved.
No production app crash was attributed to it in this review.

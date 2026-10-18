# Incremental index persistence experiment

The in-memory index and filesystem-event batching keep their existing behavior. This experiment reduces the data
written when saving changes. It has not been installed in the running app.

## Storage

`index.sealed` is a full encrypted snapshot. Format 7 adds a UUID generation; format 6 (Strata 0.6.1) remains readable
and migrates on its next save. An older Strata rebuilds its cache when it encounters format 7.

`index.sealed.changes` is an encrypted, cumulative difference from that generation. Each column has a resulting byte
length and sorted replacement blocks of up to 16 KiB. The names column can grow alongside appended entries. The file
also records the filesystem-event watermark. It uses the same authenticated encryption and atomic replacement as
other Strata stores; it is never a plaintext log.

Saving hashes the in-memory columns to find changed blocks. This covers every column mutation without maintaining a
second set of dirty-entry bookkeeping in the scanner. It still reads the entire index in RAM; reducing disk writes
does not imply less CPU work. The last full snapshot's hashes and last save's hashes are retained in memory.

The changes file is replaced with the complete difference from the snapshot, rather than appended to. A short or
failed write cannot damage an earlier committed changes file. Saving writes a new snapshot when the difference
exceeds a quarter of the snapshot or 16 MiB, after 128 incremental saves, after compaction or a rebuild, or when roots
or privacy exclusions change. The old changes file is unlinked only after committing the new snapshot.

## Recovery and concurrency

- A reader authenticates the entire changes file before applying any blocks. Invalid lengths, repeated or
  out-of-order pages, missing growth blocks, invalid references and sibling cycles are rejected. A failed load
  causes the worker to rebuild the cache from the filesystem.
- A generation mismatch means a checkpoint committed before its old changes file was cleaned up. The old file is
  ignored. It cannot roll back the checkpoint's data or event watermark.
- A missing changes file leaves the full snapshot's older watermark intact. Startup's existing FSEvents replay
  catches up from that point. A cache is recoverable; it is never authoritative over the user's files.
- Instances using this format lock the containing directory while loading or publishing a pair. File stamps also
  detect replacement by an older app that does not take that lock.
- If another writer changed the pair, a stale instance checkpoints its own consistent store with its older recovery
  watermark. That watermark remains a floor until restart or a filesystem rebuild, so changes the stale instance
  may not have observed are replayed rather than skipped.
- Failed writes leave the worker dirty for retry. Events received during a save stay queued and are applied and
  persisted afterwards. A full rebuild always replaces the old cache, even if no ordinary change dirtied it first.
- Changes-file symlinks are never followed and directories are never removed. All writes use SecureStorage's own
  fresh temporary files. Atomic rename protects process-crash recovery; after power loss an unreadable cache can
  still require rebuilding, as with the existing storage implementation.

## Validation

`IndexPersistenceTests` covers small writes, repeated saves and restarts, additions/removals/subtrees, Unicode names
and block boundaries, every column's round trip, no-op/reverted changes, migration, privacy changes, compaction,
checkpoint bounds, interruption before commit and after checkpoint, corruption/truncation/trailing bytes,
malformed authenticated input, missing logs and conservative watermarks, concurrent instances, older-app
replacement, links, directories and temporary leftovers. `IndexWorkerTests` covers retries without another event,
events arriving during saving, forced rebuilds and rebuilding after a corrupt changes file. Tests use temporary
trees and SecureStorage's throwaway test key. Seven incremental-index mutations prove the critical regressions fail.

Run the usual Swift tests and safety/localization checks. The byte-budget regression uses 200,000 synthetic entries
and requires a small edit to write less than 1% of a snapshot; elapsed times are reported, never asserted.

For an optimized comparison at a larger scale:

```sh
bash scripts/benchmark-index.sh          # 6.9 million synthetic entries, about 434 MB
bash scripts/benchmark-index.sh 200000   # smaller run
```

The standalone benchmark retains `DEBUG` to isolate its storage/key, and checks that isolation before running. It
compiles only the index/storage files with optimization, makes its own temporary data and removes it afterwards.
The old comparison uses the format-6 codec without hashing or replay validation, matching the previous algorithm.

One 6.9-million-entry run wrote 433,602,369 bytes for a snapshot and 33,012 bytes for a small change. Save wall time
was about 260 ms with the old algorithm and 140 ms incrementally; process CPU time was about 95 ms and 139 ms.
Startup was about 131 ms with the old loader and 300 ms with snapshot plus changes. These are synthetic warm-cache
measurements, not installed-app CPU or startup guarantees; larger bursts and a growing changes file cost more.

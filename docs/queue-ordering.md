# Order waiting transfers

In Transfers, a waiting copy or move has Run Next (the up-arrow button) when another job for that disk is ahead of
it. Its context menu also offers Move Up and Move Down. Waiting Compress and Extract jobs have the same choices
within their archive queue. Running and paused work is never interrupted or reordered. Transfers to other disks
continue independently; provider fetches, uploads and opening an archive for browsing retain their existing policy.

The list shows running work first, waiting jobs in priority order, and finished jobs last. Clear still removes only
finished jobs. Ordering is for the current queue; it does not add persistence or change pause, retry or quit behavior.

`TransferOrdering` decides the insertion index from the eligible waiting positions. `TransferQueue` resolves those
positions from the actual disk waiters (or queued archive jobs) and revalidates ownership and state at dispatch.
Menus and buttons stay tied to their own row and queue. A job that was cancelled, started, finished or removed is
no longer reorderable. No paths, conflict decisions, copy options, History entries or Undo receipts change.

Disk release reads the current job priorities instead of retaining each waiter's original insertion order. An
already granted disk slot is not a wait, even before its continuation resumes. Archive scheduling uses the same
priority order while retaining its single active archive job and separate browsing bypass.

Headless tests reserve a disk slot without blocking a worker, enqueue real copies and cross-disk moves, then release
it to observe completion order. They cover same-name conflicts, private History, repeated Undo/Redo, replacement
identities, cancellation and independent disks. Native row buttons and context menus are exercised with actual
archive jobs, including stale and foreign actions. Every filesystem fixture remains alive through assertions.

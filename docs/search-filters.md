# Search filters

While searching, Filters… opens a native popover for kind, extension, size, modification date and download source.
Kind has the same categories as the existing search interpreter. Editable fields accept the existing syntax:
`pdf,png`, `>10mb`, `1mb..1gb`, `today`, `yesterday`, `thisweek`, or a date such as `2026-10-24`.
Clear a field to remove its filter. Apply updates the current search without adding a Back step; Cancel leaves it alone.

`SearchFilterDraft` preserves unrelated terms, exclusions, quoted names, patterns and folder filters. Only changed
fields are replaced. A plain-English interpretation is made explicit when edited so its sizes, dates and kinds
survive. Timestamp intervals retain both date boundaries rather than losing half a range. Invalid or reversed
bounds cannot silently broaden the edited search. `SearchTerms` is shared by the index, Spotlight and editor so
escaped quotes and backslashes round-trip.

`source:github.com` (also `from:github.com` or “downloaded from github”) searches macOS's saved download-source
metadata, `kMDItemWhereFroms`, using Spotlight. It does not contact that site. Files without source metadata, or
outside Spotlight's index, cannot appear. Names, kinds, extensions, sizes and dates can narrow this search.
The editor refuses combinations with the index's regex, exclusions, folder-path filters or exact-case mode, which
Spotlight does not implement. Values remain typed predicate arguments, never executable predicate syntax.

The editor's callback keeps its original pane, destination and navigation revision weakly. A closed window,
attached sheet, different active pane, changed query or navigation away and back prevents a delayed Apply.
Tests exercise native form actions, actual predicates and parser boundaries using private preferences and fixtures;
they never query a live Spotlight index or access a cloud account.

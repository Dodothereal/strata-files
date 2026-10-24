# Cloud folders

Strata discovers iCloud Drive and physical account folders exposed by installed sync apps in
`~/Library/CloudStorage`. Accounts appear under Locations unless already pinned in Favorites, and as roots in the
Folders sidebar. Discovery runs in the background at launch, when Strata becomes active, and when volumes change.
Different accounts stay separate. An app must be signed in and have created its local account folder; installing
the app alone creates no shortcut. Symlinks and hidden scratch folders are skipped.

File Provider placeholders show a cloud badge. Download Now uses a coordinated read to ask the installed provider
to materialize an individual file. Reading and coordination run on a worker, and the chosen item and parent are
verified before requesting and after coordination. Links, replaced items and redirected parents are refused.
Provider folders can be browsed normally; making an entire folder available offline remains a provider action.

Local File Provider content is not assumed to have finished uploading. Strata does not invent an upload-complete
badge or expose Remove Download for that unknown state. Use Show in Finder for the provider's offline/online-only,
pinning and sharing controls. Apple restricts NSFileProviderManager to the provider's own extension and related
processes; Strata does not use private APIs or shell out to undocumented tools to bypass that boundary.

iCloud retains Download Now and Remove Download. Removing a download requires fresh confirmation that the item
has uploaded and still matches the captured item and parent. It never deletes the cloud copy.

Headless tests cover discovery, both sidebar modes, multiple accounts, pinned-folder deduplication, delayed
discovery, local/cloud-only state, coordinated reads and refused changes. Tests inject discovery and eviction;
they never sign into accounts or materialize real cloud files. Live provider verification remains necessary for
Google Drive, OneDrive and Dropbox before claiming compatibility with every account configuration, legacy sync
client, external-drive setup or provider-specific menu command.

# Reopen browsing history

When Reopen Windows is enabled, Strata's automatic session keeps each pane's recent Back and Forward history as well
as its folder and view, the active side, and the selected tab. Local searches, Recents and Duplicates remain places
in that history. A saved local results view can reopen without adding an extra Back step. Named workspaces keep
saving just their layout and views; opening one starts fresh.

`Workspace` carries optional session fields, so sessions from older releases still open and older app versions can
ignore the new fields. `WorkspacePlan` carries each pane's metadata through skipped folders; missing panes and tabs
cannot transfer their history or active state to a neighbor. Removing saved folders prunes the matching metadata.

`SavedDestination` stores server IDs and remote paths, never their physical cache paths. Restoration resolves them
through the owning `RemoteServices`. Reopening does not start a remote search or a server login. Waiting panes keep
their history; server locations are read only after an explicit navigation or connection. Container, archive and
clipboard staging locations are omitted from remembered history and replaced with Home for a session's base folder.

`SessionStorage` bounds the input to 4 MiB and restoration to 20 windows, 80 tabs overall and two panes per tab. It
keeps up to 100 recent steps per stack and budgets encoded history before allocation, including JSON escaping.
If metadata is unusually large the layout can still be saved without it. A failed encoding preserves the previous
session. Invalid independent window records are skipped; malformed optional metadata cannot broaden a scoped search.
Decoding never rewrites the source data.

Headless tests run the real snapshot → encode → preferences → decode → reopen path, navigate both panes and retain
the entire file fixture. They also cover older sessions, missing panes, pruning, limits, malformed fields and two
server environments with the same ID. Connection tests inject a connector that cannot access the network.

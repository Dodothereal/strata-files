# SFTP names and starting folders

In **Go → Connect to Server…**, select **SFTP**. The address accepts an SSH config alias, `user@host`, or an
address such as `sftp://deploy@example.com:2222/srv/app`.

- **Name** is the label in the sidebar. For a new login, leave it empty to use the host name.
- **Start Folder** is an absolute path on the server, such as `/srv/app`. An entered path takes precedence over a
  folder included in the address. Spaces, Unicode and percent signs are literal here; do not URL-encode them.
- Leave Start Folder empty to keep a folder included in the address, or to start in the login’s folder when the
  address has no folder. Enter `/` explicitly to start at the server’s root.
- Relative paths such as `projects` or `~/projects` are not supported in Start Folder. Enter the complete remote
  path instead. Control characters and paths longer than 4,096 characters are refused before connecting.

Strata still uses your Mac’s SSH configuration, keys and agent. Name and Start Folder do not change the SSH login,
forwarding policy or credentials.

## Editing and reconnecting

Edit a saved server to change its name or starting folder. Its current folder appears separately from its address,
so clearing Start Folder really returns to the login’s starting folder unless you also type a folder in the address.
Clearing Name uses the host name. An unchanged automatic name follows a changed host; a custom name stays as entered.

Connecting to the same host, user and port reuses its saved entry rather than creating a duplicate. When reconnecting
this way, an empty Name keeps the saved label; entering a name replaces it. Changes are saved only after the
connection succeeds. A failed attempt leaves the saved definition unchanged. Cancelling an attempt does not undo a
connection that has already been saved.

If an older saved definition contains a relative path, editing shows it with a leading `/`, preserving the location
that its former address field represented.

Cancel during a connection stops that attempt and leaves the fields available for another try. Cancel again while
idle closes the sheet. Name and Start Folder apply only to SFTP, not to network shares or S3 buckets.

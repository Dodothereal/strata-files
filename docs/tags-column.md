# Tags in List view

Show Tags from the list header’s column menu or View Options. It starts hidden, including when upgrading an existing
column layout. The column displays the file’s own Finder tag names, including custom names, in their saved order.

Click its header to sort; click again to reverse it. View → Sort By → Tags offers the same order in the other views.
Sorting compares all tag names alphabetically, independent of the order they were added. Untagged items come first
in ascending order. Equal tag lists keep the ordinary name/path tie break and Keep Folders on Top still applies.

Sorting reads the tag cache, never extended attributes from inside a comparison. Folder reads already load tags in
the background; choosing Tags for search results reads their metadata in one background batch. Later completions
update the order while retaining selection and expanded rows. Native inline renaming defers row movement until the
editor finishes. Deeper Columns retain their selection when their cached tag order changes.

Invalidation keeps the last known tag names while a background read is pending. Browsing an ancestor in another
window therefore cannot temporarily clear a ready tag sort. A foreground read still refreshes an invalidated item.

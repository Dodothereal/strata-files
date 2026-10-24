# Pointer navigation

Strata uses mouse side buttons 3 and 4 for Back and Forward. They act on the pane under the pointer and give that
pane keyboard focus. Primary, secondary and middle clicks keep their normal behavior. Events stay within the
browser window; the app installs no global event monitor and needs no Accessibility permission for this feature.

Page-swipe gestures use macOS's own swipe tracking and the setting in System Settings. Horizontal scrolling in
Columns and Gallery keeps its existing meaning. Discrete page-swipe events and mouse buttons can still navigate
those views. Swipe directions mirror the window's layout direction.

A fluid swipe captures its pane and navigation revisions. Starting another folder open, changing the location or
view, removing that pane, closing the window, losing key status or cancelling the gesture prevents a late commit.
The gesture commits only once, after AppKit settles the swipe. Editable text keeps its scrolling and editing.

Headless tests send private synthetic mouse events directly to unshown browser windows, never to the system event
queue. They exercise both panes in all five views and control swipe completions to cover stale and cancelled work,
right-to-left layout and teardown. Hardware gesture feel and native animation still need a manual check on a
trackpad or Magic Mouse; these tests do not simulate physical touches.

import AppKit
@_exported import StrataIndex
@_exported import StrataModel
@_exported import StrataPreviews
@_exported import StrataSupport
@_exported import StrataTheme

SecureStorage.useApplicationStorage()
Prefs.useApplicationPreferences()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

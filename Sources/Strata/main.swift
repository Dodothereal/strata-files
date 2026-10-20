import AppKit

SecureStorage.useApplicationStorage()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

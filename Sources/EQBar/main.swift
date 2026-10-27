import AppKit

LaunchTimer.mark()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon, no main menu
app.run()

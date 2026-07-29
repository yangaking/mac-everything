import Cocoa
import SwiftUI
import MacEverythingCore

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Ensures it acts as a background/menubar app

let delegate = AppDelegate()
app.delegate = delegate
app.run()

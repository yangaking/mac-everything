import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if #available(macOS 11.0, *), let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) {
                img.isTemplate = true
                button.image = img
                print("Set image to magnifyingglass")
            } else {
                button.title = "🔍 Test"
                print("Set title")
            }
        }
        
        // Quit after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

import Cocoa

let appPath = "build/MacEverything.app"
let iconPath = "Resources/AppIcon.icns"

guard let image = NSImage(contentsOfFile: iconPath) else {
    print("Failed to load icon from \(iconPath)")
    exit(1)
}

let success = NSWorkspace.shared.setIcon(image, forFile: appPath, options: [])
if success {
    print("Successfully set icon for \(appPath)")
} else {
    print("Failed to set icon for \(appPath)")
    exit(1)
}

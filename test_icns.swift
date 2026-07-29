import Cocoa

let iconPath = "Resources/AppIcon.icns"
guard let image = NSImage(contentsOfFile: iconPath) else {
    print("Failed to load \(iconPath)")
    exit(1)
}
print("Loaded icon. Size: \(image.size)")
if let tiffData = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiffData) {
    print("Bitmap size: \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
} else {
    print("No bitmap representation")
}

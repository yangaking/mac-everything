import Foundation

let path = "/Library/Application Support/com.apple.TCC/TCC.db"
let fd = open(path, O_RDONLY)
if fd != -1 {
    print("TCC.db opened successfully.")
    close(fd)
} else {
    print("TCC.db open failed with errno: \(errno)")
}

let safariPath = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
let safariFd = open(safariPath, O_RDONLY)
if safariFd != -1 {
    print("Safari Bookmarks opened successfully.")
    close(safariFd)
} else {
    print("Safari Bookmarks open failed with errno: \(errno)")
}

let messagesPath = NSHomeDirectory() + "/Library/Messages"
var isDir: ObjCBool = false
let canReadMessages = FileManager.default.isReadableFile(atPath: messagesPath)
print("Can read ~/Library/Messages: \(canReadMessages)")

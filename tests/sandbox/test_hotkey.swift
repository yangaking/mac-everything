import Cocoa
import Carbon

class HotKeyManager {
    func testRegister() {
        var hotKeyRef: EventHotKeyRef? = nil
        let hotKeyID = EventHotKeyID(signature: OSType("MACE".utf8.reduce(0) { $0 << 8 | OSType($1) }), id: 1)
        
        let status = RegisterEventHotKey(
            49,
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        print("Register status: \(status)")
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        let callback: EventHandlerUPP = { (nextHandler, theEvent, userData) -> OSStatus in
            print("HOTKEY PRESSED!")
            NSSound.beep()
            return noErr
        }
        
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(), // Try EventDispatcherTarget
            callback,
            1,
            &eventType,
            nil,
            nil
        )
        print("Install status: \(installStatus)")
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyManager().testRegister()
    }
}

let app = NSApplication.shared
app.delegate = AppDelegate()
app.run()

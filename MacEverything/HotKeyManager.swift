import Foundation
import Carbon

class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    var onHotKeyPressed: (() -> Void)?
    
    private init() {
        // Register carbon event handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        InstallEventHandler(GetEventDispatcherTarget(), { (nextHandler, theEvent, userData) -> OSStatus in
            let mySelf = Unmanaged<HotKeyManager>.fromOpaque(userData!).takeUnretainedValue()
            mySelf.onHotKeyPressed?()
            return noErr
        }, 1, &eventType, ptr, nil)
    }
    
    func registerGlobalHotKey(keyCode: UInt32 = 49, modifierFlags: UInt32 = UInt32(optionKey)) -> Bool {
        // Unregister existing hotkey if any
        if let currentRef = hotKeyRef {
            UnregisterEventHotKey(currentRef)
            hotKeyRef = nil
        }
        
        let hotKeyID = EventHotKeyID(signature: OSType(0x4d455654), id: 1) // "MEVT"
        var newHotKeyRef: EventHotKeyRef? = nil
        
        let status = RegisterEventHotKey(
            keyCode,
            modifierFlags,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &newHotKeyRef
        )
        
        if status == noErr {
            self.hotKeyRef = newHotKeyRef
            return true
        } else {
            return false
        }
    }
}

import Foundation
import Carbon

class HotKeyManager {
    static let shared = HotKeyManager()
    
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    var onHotKeyPressed: [UInt32: () -> Void] = [:]
    
    private init() {
        // Register carbon event handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        InstallEventHandler(GetEventDispatcherTarget(), { (nextHandler, theEvent, userData) -> OSStatus in
            guard let event = theEvent else { return noErr }
            
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            
            if status == noErr {
                let mySelf = Unmanaged<HotKeyManager>.fromOpaque(userData!).takeUnretainedValue()
                mySelf.onHotKeyPressed[hotKeyID.id]?()
            }
            return noErr
        }, 1, &eventType, ptr, nil)
    }
    
    func registerGlobalHotKey(id: UInt32, keyCode: UInt32, modifierFlags: UInt32) -> Bool {
        // Unregister existing hotkey for this ID if any
        if let currentRef = hotKeyRefs[id] {
            UnregisterEventHotKey(currentRef)
            hotKeyRefs.removeValue(forKey: id)
        }
        
        // If keyCode and modifiers are 0, it means disabled
        if keyCode == 0 && modifierFlags == 0 {
            return true
        }
        
        let hotKeyID = EventHotKeyID(signature: OSType(0x4d455654), id: id) // "MEVT"
        var newHotKeyRef: EventHotKeyRef? = nil
        
        let status = RegisterEventHotKey(
            keyCode,
            modifierFlags,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &newHotKeyRef
        )
        
        if status == noErr, let ref = newHotKeyRef {
            self.hotKeyRefs[id] = ref
            return true
        } else {
            return false
        }
    }
}

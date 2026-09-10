import Foundation
import Carbon

class HotKeyManager {
    static let shared = HotKeyManager()
    
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var hotKeySpecs: [UInt32: (keyCode: UInt32, modifiers: UInt32)] = [:]
    private var eventHandlerRef: EventHandlerRef? = nil
    var onHotKeyPressed: [UInt32: () -> Void] = [:]
    
    private init() {
        installEventHandler()
    }
    
    /// Installs (or re-installs) the Carbon event handler that dispatches global
    /// hotkey presses. Any previously installed handler is removed first, so
    /// repeated wake recoveries never stack duplicate handlers (which would fire
    /// the callback more than once per press).
    func installEventHandler() {
        if let existing = eventHandlerRef {
            RemoveEventHandler(existing)
            eventHandlerRef = nil
        }
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, theEvent, userData) -> OSStatus in
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
            },
            1,
            &eventType,
            ptr,
            &eventHandlerRef
        )
    }
    
    func registerGlobalHotKey(id: UInt32, keyCode: UInt32, modifierFlags: UInt32) -> Bool {
        // Unregister existing hotkey for this ID if any.
        if let currentRef = hotKeyRefs[id] {
            UnregisterEventHotKey(currentRef)
            hotKeyRefs.removeValue(forKey: id)
        }
        
        // If keyCode and modifiers are 0, it means disabled.
        if keyCode == 0 && modifierFlags == 0 {
            hotKeySpecs.removeValue(forKey: id)
            return true
        }
        
        // Remember the spec so the hotkey can be re-registered after a wake.
        hotKeySpecs[id] = (keyCode, modifierFlags)
        
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
    
    /// Wake recovery: re-installs the Carbon event handler and re-registers every
    /// registered hotkey. Both the dispatcher handler and the hotkey registrations
    /// can go stale after the system or a display wakes from sleep.
    func reinstallAll() {
        installEventHandler()
        for (id, spec) in hotKeySpecs {
            _ = registerGlobalHotKey(id: id, keyCode: spec.keyCode, modifierFlags: spec.modifiers)
        }
    }
}

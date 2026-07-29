import SwiftUI
import Carbon
import AppKit

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    @Published var enableRegexDefault: Bool {
        didSet { UserDefaults.standard.set(enableRegexDefault, forKey: "enableRegexDefault") }
    }
    
    @Published var enablePathSearch: Bool {
        didSet { UserDefaults.standard.set(enablePathSearch, forKey: "enablePathSearch") }
    }
    
    @Published var hotkeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkeyCode") }
    }
    
    @Published var hotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers") }
    }
    
    @Published var hotkeyString: String {
        didSet { UserDefaults.standard.set(hotkeyString, forKey: "hotkeyString") }
    }
    
    init() {
        self.enableRegexDefault = UserDefaults.standard.bool(forKey: "enableRegexDefault")
        self.enablePathSearch = UserDefaults.standard.bool(forKey: "enablePathSearch")
        
        let savedCode = UserDefaults.standard.integer(forKey: "hotkeyCode")
        let savedMods = UserDefaults.standard.integer(forKey: "hotkeyModifiers")
        
        if savedCode == 0 && savedMods == 0 {
            // Default to Option + Space
            self.hotkeyCode = 49
            self.hotkeyModifiers = UInt32(optionKey)
            self.hotkeyString = "⌥ Space"
        } else {
            self.hotkeyCode = UInt32(savedCode)
            self.hotkeyModifiers = UInt32(savedMods)
            self.hotkeyString = UserDefaults.standard.string(forKey: "hotkeyString") ?? "Custom"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var isRecording = false
    @State private var eventMonitor: Any?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.largeTitle)
                .bold()
            
            Toggle("Enable Regex Search by default", isOn: $settings.enableRegexDefault)
            Toggle("Enable Path Search by default", isOn: $settings.enablePathSearch)
            
            Divider()
            
            HStack {
                Text("Global Hotkey:")
                
                Button(action: {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }) {
                    Text(isRecording ? "Press any key combination..." : settings.hotkeyString)
                        .frame(width: 200)
                }
                .buttonStyle(BorderedButtonStyle())
            }
            
            Spacer()
        }
        .padding()
        .frame(width: 400, height: 300)
        .onDisappear {
            stopRecording()
        }
    }
    
    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Filter out events with no modifiers or just shift
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.isEmpty || flags == .shift {
                return event
            }
            
            var carbonMods: UInt32 = 0
            var str = ""
            if flags.contains(.control) { carbonMods |= UInt32(controlKey); str += "⌃" }
            if flags.contains(.option) { carbonMods |= UInt32(optionKey); str += "⌥" }
            if flags.contains(.shift) { carbonMods |= UInt32(shiftKey); str += "⇧" }
            if flags.contains(.command) { carbonMods |= UInt32(cmdKey); str += "⌘" }
            
            let specialKeys: [UInt16: String] = [
                49: "Space",
                53: "Esc",
                36: "Return",
                48: "Tab"
            ]
            
            if let special = specialKeys[event.keyCode] {
                str += " \(special)"
            } else if let chars = event.charactersIgnoringModifiers?.uppercased() {
                str += " \(chars)"
            } else {
                str += " Key"
            }
            
            settings.hotkeyCode = UInt32(event.keyCode)
            settings.hotkeyModifiers = carbonMods
            settings.hotkeyString = str
            
            // Re-register hotkey globally
            _ = HotKeyManager.shared.registerGlobalHotKey(keyCode: settings.hotkeyCode, modifierFlags: settings.hotkeyModifiers)
            
            stopRecording()
            return nil // Consume event
        }
    }
    
    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

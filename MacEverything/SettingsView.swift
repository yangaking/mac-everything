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
    
    @Published var searchCacheTimeoutMinutes: Int {
        didSet { UserDefaults.standard.set(searchCacheTimeoutMinutes, forKey: "searchCacheTimeoutMinutes") }
    }
    
    @Published var maxResults: Int {
        didSet { UserDefaults.standard.set(maxResults, forKey: "maxResults") }
    }
    
    // Global Toggle Hotkey
    @Published var hotkeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkeyCode") }
    }
    
    @Published var hotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers") }
    }
    
    @Published var hotkeyString: String {
        didSet { UserDefaults.standard.set(hotkeyString, forKey: "hotkeyString") }
    }
    
    // Regex Hotkey
    @Published var regexHotkeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(regexHotkeyCode), forKey: "regexHotkeyCode") }
    }
    
    @Published var regexHotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(regexHotkeyModifiers), forKey: "regexHotkeyModifiers") }
    }
    
    @Published var regexHotkeyString: String {
        didSet { UserDefaults.standard.set(regexHotkeyString, forKey: "regexHotkeyString") }
    }
    
    // Path Search Hotkey
    @Published var pathHotkeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(pathHotkeyCode), forKey: "pathHotkeyCode") }
    }
    
    @Published var pathHotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(pathHotkeyModifiers), forKey: "pathHotkeyModifiers") }
    }
    
    @Published var pathHotkeyString: String {
        didSet { UserDefaults.standard.set(pathHotkeyString, forKey: "pathHotkeyString") }
    }
    
    init() {
        self.enableRegexDefault = UserDefaults.standard.bool(forKey: "enableRegexDefault")
        self.enablePathSearch = UserDefaults.standard.bool(forKey: "enablePathSearch")
        
        let savedTimeout = UserDefaults.standard.object(forKey: "searchCacheTimeoutMinutes")
        if savedTimeout == nil {
            self.searchCacheTimeoutMinutes = 5
        } else {
            self.searchCacheTimeoutMinutes = UserDefaults.standard.integer(forKey: "searchCacheTimeoutMinutes")
        }
        
        let savedMaxResults = UserDefaults.standard.object(forKey: "maxResults")
        if savedMaxResults == nil {
            self.maxResults = 100
        } else {
            self.maxResults = UserDefaults.standard.integer(forKey: "maxResults")
        }
        
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
            self.hotkeyString = UserDefaults.standard.string(forKey: "hotkeyString") ?? "自定义"
        }
        
        // Regex defaults (Cmd+R)
        let savedRegexCode = UserDefaults.standard.integer(forKey: "regexHotkeyCode")
        let savedRegexMods = UserDefaults.standard.integer(forKey: "regexHotkeyModifiers")
        let savedRegexString = UserDefaults.standard.string(forKey: "regexHotkeyString")
        if savedRegexCode == 0 && savedRegexMods == 0 && savedRegexString == nil {
            self.regexHotkeyCode = 15 // R
            self.regexHotkeyModifiers = UInt32(cmdKey)
            self.regexHotkeyString = "⌘ R"
        } else {
            self.regexHotkeyCode = UInt32(savedRegexCode)
            self.regexHotkeyModifiers = UInt32(savedRegexMods)
            self.regexHotkeyString = savedRegexString ?? "未设置"
        }
        
        // Path defaults (Cmd+P)
        let savedPathCode = UserDefaults.standard.integer(forKey: "pathHotkeyCode")
        let savedPathMods = UserDefaults.standard.integer(forKey: "pathHotkeyModifiers")
        let savedPathString = UserDefaults.standard.string(forKey: "pathHotkeyString")
        if savedPathCode == 0 && savedPathMods == 0 && savedPathString == nil {
            self.pathHotkeyCode = 35 // P
            self.pathHotkeyModifiers = UInt32(cmdKey)
            self.pathHotkeyString = "⌘ P"
        } else {
            self.pathHotkeyCode = UInt32(savedPathCode)
            self.pathHotkeyModifiers = UInt32(savedPathMods)
            self.pathHotkeyString = savedPathString ?? "未设置"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var recordingId: UInt32 = 0 // 0 means not recording, 1=main, 2=regex, 3=path
    @State private var eventMonitor: Any?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("设置")
                .font(.largeTitle)
                .bold()
            
            Toggle("默认启用正则搜索", isOn: $settings.enableRegexDefault)
            Toggle("默认启用路径搜索", isOn: $settings.enablePathSearch)
            
            HStack {
                Text("保持上次搜索结果时长 (分钟):")
                Stepper(value: $settings.searchCacheTimeoutMinutes, in: 0...1440) {
                    if settings.searchCacheTimeoutMinutes == 0 {
                        Text("不保持 (每次清除)")
                    } else {
                        Text("\(settings.searchCacheTimeoutMinutes) 分钟")
                    }
                }
            }
            
            HStack {
                Text("最大结果数:")
                Stepper(value: $settings.maxResults, in: 50...1000, step: 50) {
                    Text("\(settings.maxResults)")
                }
            }
            
            Divider()
            
            Text("快捷键")
                .font(.headline)
            
            hotkeyRow(title: "全局显示/隐藏窗口:", id: 1, keyString: settings.hotkeyString)
            hotkeyRow(title: "切换正则模式:", id: 2, keyString: settings.regexHotkeyString)
            hotkeyRow(title: "切换路径搜索:", id: 3, keyString: settings.pathHotkeyString)
            
            Spacer()
        }
        .padding()
        .frame(width: 450, height: 350)
        .onDisappear {
            stopRecording()
        }
    }
    
    private func hotkeyRow(title: String, id: UInt32, keyString: String) -> some View {
        HStack {
            Text(title)
                .frame(width: 180, alignment: .leading)
            
            Button(action: {
                if recordingId == id {
                    stopRecording()
                } else {
                    startRecording(id: id)
                }
            }) {
                Text(recordingId == id ? "按下任意组合键..." : keyString)
                    .frame(width: 200)
            }
            .buttonStyle(BorderedButtonStyle())
            
            if recordingId != id && keyString != "未设置" {
                Button("清除") {
                    clearHotkey(id: id)
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.red)
            }
        }
    }
    
    private func clearHotkey(id: UInt32) {
        if id == 1 {
            settings.hotkeyCode = 0; settings.hotkeyModifiers = 0; settings.hotkeyString = "未设置"
        } else if id == 2 {
            settings.regexHotkeyCode = 0; settings.regexHotkeyModifiers = 0; settings.regexHotkeyString = "未设置"
        } else if id == 3 {
            settings.pathHotkeyCode = 0; settings.pathHotkeyModifiers = 0; settings.pathHotkeyString = "未设置"
        }
        _ = HotKeyManager.shared.registerGlobalHotKey(id: id, keyCode: 0, modifierFlags: 0)
    }
    
    private func startRecording(id: UInt32) {
        stopRecording() // Stop any existing
        recordingId = id
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
            
            let code = UInt32(event.keyCode)
            
            if self.recordingId == 1 {
                self.settings.hotkeyCode = code
                self.settings.hotkeyModifiers = carbonMods
                self.settings.hotkeyString = str
                _ = HotKeyManager.shared.registerGlobalHotKey(id: 1, keyCode: code, modifierFlags: carbonMods)
            } else if self.recordingId == 2 {
                self.settings.regexHotkeyCode = code
                self.settings.regexHotkeyModifiers = carbonMods
                self.settings.regexHotkeyString = str
            } else if self.recordingId == 3 {
                self.settings.pathHotkeyCode = code
                self.settings.pathHotkeyModifiers = carbonMods
                self.settings.pathHotkeyString = str
            }
            
            self.stopRecording()
            return nil // Consume event
        }
    }
    
    private func stopRecording() {
        recordingId = 0
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

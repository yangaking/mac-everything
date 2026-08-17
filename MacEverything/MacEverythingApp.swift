import SwiftUI
import AppKit
import Carbon
import MacEverythingCore



class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var searchWindow: NSWindow!
    var settingsWindow: NSWindow!
    var aboutWindow: NSWindow!
    var statusItem: NSStatusItem!
    
    private var lastHideTime: Date?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupSearchWindow()
        setupSettingsWindow()
        setupAboutWindow()
        setupStatusBar()
        registerGlobalHotkey()
        
        // Check for updates automatically on launch (after a brief delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            UpdateManager.shared.checkForUpdates(manual: false)
        }
        
        // Setup local event monitor for local hotkeys (Regex, Path)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            
            // Convert NSEvent modifier flags to Carbon modifiers for comparison
            var carbonMods: UInt32 = 0
            if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
            if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
            if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }
            if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
            
            let code = UInt32(event.keyCode)
            let settings = AppSettings.shared
            
            if code == settings.regexHotkeyCode && carbonMods == settings.regexHotkeyModifiers {
                settings.enableRegexDefault.toggle()
                NotificationCenter.default.post(name: NSNotification.Name("TriggerSearch"), object: nil)
                return nil // Consume the event
            } else if code == settings.pathHotkeyCode && carbonMods == settings.pathHotkeyModifiers {
                settings.enablePathSearch.toggle()
                NotificationCenter.default.post(name: NSNotification.Name("TriggerSearch"), object: nil)
                return nil // Consume the event
            }
            
            return event
        }
        
        if PermissionManager.hasFullDiskAccess() {
            startEngine()
        } else {
            // Listen for permission granted notification
            NotificationCenter.default.addObserver(forName: NSNotification.Name("PermissionGranted"), object: nil, queue: .main) { [weak self] _ in
                self?.startEngine()
            }
        }
    }
    
    func startEngine() {
        NotificationCenter.default.post(name: NSNotification.Name("IndexingStarted"), object: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = [NSHomeDirectory(), "/Applications", "/System/Applications"]
            var cStringsArr: [UnsafePointer<CChar>?] = []
            let allocators = paths.map { strdup($0) }
            for ptr in allocators {
                cStringsArr.append(UnsafePointer(ptr))
            }
            
            init_engine(&cStringsArr, cStringsArr.count)
            
            for ptr in allocators {
                free(ptr)
            }
            
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("IndexingFinished"), object: nil)
            }
        }
    }
    
    func setupMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        NSApp.mainMenu = mainMenu
    }
    
    func setupSearchWindow() {
        let contentView = ContentView()
        
        searchWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        
        searchWindow.setFrameAutosaveName("MainSearchWindow")
        
        searchWindow.center()
        searchWindow.titlebarAppearsTransparent = true
        searchWindow.titleVisibility = .hidden
        searchWindow.isMovableByWindowBackground = true
        searchWindow.backgroundColor = .clear // Transparent background for glassmorphism
        searchWindow.hasShadow = true
        searchWindow.isOpaque = false
        searchWindow.appearance = NSAppearance(named: .darkAqua) // Force dark mode
        searchWindow.contentView = NSHostingView(rootView: contentView)
        searchWindow.isReleasedWhenClosed = false
        searchWindow.delegate = self
    }
    
    func setupSettingsWindow() {
        let settingsView = SettingsView()
        
        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        
        settingsWindow.center()
        settingsWindow.title = "Settings"
        settingsWindow.contentView = NSHostingView(rootView: settingsView)
        settingsWindow.isReleasedWhenClosed = false
    }
    
    func setupAboutWindow() {
        let aboutView = AboutView()
        
        aboutWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        
        aboutWindow.center()
        aboutWindow.title = "About MacEverything"
        aboutWindow.contentView = NSHostingView(rootView: aboutView)
        aboutWindow.isReleasedWhenClosed = false
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            if #available(macOS 11.0, *), let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Search") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "⚡"
            }
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }
    
    @objc func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseUp {
            // Right click: show menu
            let menu = NSMenu()
            
            // Regex toggle item
            let regexItem = NSMenuItem(title: "Enable Regex Search", action: #selector(toggleRegex), keyEquivalent: "r")
            regexItem.state = AppSettings.shared.enableRegexDefault ? .on : .off
            menu.addItem(regexItem)
            
            // Path search toggle item
            let pathItem = NSMenuItem(title: "开启/关闭路径搜索", action: #selector(togglePathSearch), keyEquivalent: "p")
            pathItem.state = AppSettings.shared.enablePathSearch ? .on : .off
            menu.addItem(pathItem)
            
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "查询语法帮助...", action: #selector(showHelpDoc), keyEquivalent: "h"))
            menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkUpdates), keyEquivalent: "u"))
            menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
            menu.addItem(NSMenuItem(title: "About MacEverything", action: #selector(showAbout), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            
            statusItem.menu = menu
            statusItem.button?.performClick(nil) // trigger menu
            statusItem.menu = nil // remove menu so left click still works next time
        } else {
            // Left click: toggle search
            toggleSearchWindow()
        }
    }
    
    @objc func showHelpDoc() {
        if !searchWindow.isVisible {
            searchWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        NotificationCenter.default.post(name: NSNotification.Name("ShowHelp"), object: nil)
    }
    
    @objc func toggleRegex() {
        AppSettings.shared.enableRegexDefault.toggle()
    }
    
    @objc func togglePathSearch() {
        AppSettings.shared.enablePathSearch.toggle()
    }
    
    @objc func showSettings() {
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func showAbout() {
        aboutWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func checkUpdates() {
        UpdateManager.shared.checkForUpdates(manual: true)
    }
    
    func registerGlobalHotkey() {
        // Main window toggle (ID 1)
        HotKeyManager.shared.onHotKeyPressed[1] = { [weak self] in
            DispatchQueue.main.async {
                self?.toggleSearchWindow()
            }
        }
        
        let success = HotKeyManager.shared.registerGlobalHotKey(
            id: 1,
            keyCode: AppSettings.shared.hotkeyCode,
            modifierFlags: AppSettings.shared.hotkeyModifiers
        )
        
        if !success && AppSettings.shared.hotkeyCode != 0 {
            let alert = NSAlert()
            alert.messageText = "Hotkey Conflict"
            alert.informativeText = "The global hotkey is already used by another application or macOS Spotlight. Please go to Settings to change it."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Ignore")
            
            if alert.runModal() == .alertFirstButtonReturn {
                showSettings()
            }
        }
    }
    
    func toggleSearchWindow() {
        if searchWindow.isVisible {
            searchWindow.orderOut(nil)
        } else {
            searchWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == searchWindow {
            lastHideTime = Date()
        }
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == searchWindow {
            checkAndClearSearchCache()
        }
    }
    
    private func checkAndClearSearchCache() {
        let timeoutMinutes = AppSettings.shared.searchCacheTimeoutMinutes
        if timeoutMinutes == 0 {
            NotificationCenter.default.post(name: NSNotification.Name("ClearSearchQuery"), object: nil)
            return
        }
        
        if let lastHide = lastHideTime {
            let elapsed = Date().timeIntervalSince(lastHide)
            if elapsed > Double(timeoutMinutes * 60) {
                NotificationCenter.default.post(name: NSNotification.Name("ClearSearchQuery"), object: nil)
            }
        }
        lastHideTime = nil
    }
}

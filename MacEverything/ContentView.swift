import SwiftUI
import AppKit
import MacEverythingCore

struct FileItem: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let name: String
    let dirPath: String
    let sizeStr: String
    let dateStr: String
    let typeStr: String
}

struct ContentView: View {
    @State private var query: String = ""
    @State private var results: [FileItem] = []
    @State private var isIndexing = true
    @State private var selectedIndex: Int = 0
    @State private var hoverIndex: Int? = nil
    @FocusState private var isSearchFocused: Bool
    @State private var isNavigatingList: Bool = false
    
    @AppStorage("hasSeenHelp") private var hasSeenHelp = false
    @State private var showHelp = false
    
    // Advanced Filters State
    @State private var showAdvancedFilters = false
    @State private var filterKinds: Set<String> = []
    @State private var filterDate: String? = nil
    @State private var filterSize: String? = nil
    @State private var filterExts: Set<String> = []
    
    @ObservedObject var settings = AppSettings.shared
    
    var body: some View {
        ZStack {
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // Header (Title bar area)
                HStack {
                    Spacer()
                    Text("MacEverything")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.bottom, 12)
                
                // Search Bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 18))
                    
                    ZStack(alignment: .leading) {
                        if query.isEmpty {
                            Text(settings.enableRegexDefault ? "🔍 [正则模式] /输入正则.../" : "🔍 搜索文件或拼音...")
                                .foregroundColor(.white.opacity(0.3))
                                .font(.system(size: 18, weight: .regular))
                                .padding(.leading, 4)
                        }
                        TextField("", text: $query)
                            .focused($isSearchFocused)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 18, weight: .regular))
                            .onChange(of: query) { newValue in
                                isNavigatingList = false // Reset navigation state when typing
                                performSearch(query: newValue)
                            }
                    }
                    
                    if !query.isEmpty {
                        Button(action: { query = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    // Settings & Help Link & Path Search
                    HStack(spacing: 12) {
                        Button(action: {
                            settings.enablePathSearch.toggle()
                            performSearch(query: query)
                        }) {
                            Text("Path")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(settings.enablePathSearch ? Color.blue.opacity(0.8) : Color.white.opacity(0.1))
                                .cornerRadius(4)
                                .foregroundColor(settings.enablePathSearch ? .white : .secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("开启/关闭路径匹配搜索")
                        
                        Button(action: { showHelp.toggle() }) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("查看查询语法帮助")
                        
                        Button(action: {
                            withAnimation {
                                showAdvancedFilters.toggle()
                            }
                        }) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 14))
                                .foregroundColor(showAdvancedFilters ? .accentColor : .secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("高级过滤选项")
                        
                        Text(AppSettings.shared.hotkeyString)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(6)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.3))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSearchFocused ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1.5)
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 8) // Reduced from 16 to 8 to accommodate filters
                
                // Advanced Filters Panel
                if showAdvancedFilters {
                    AdvancedFilterView(
                        filterKinds: $filterKinds,
                        filterDate: $filterDate,
                        filterSize: $filterSize,
                        filterExts: $filterExts,
                        onFilterChanged: { performSearch(query: query) }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                
                // Active Tags Bar
                if !filterKinds.isEmpty || filterDate != nil || filterSize != nil || !filterExts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(filterKinds).sorted(), id: \.self) { kind in
                                ActiveTagView(label: "类别: \(kind)") { filterKinds.remove(kind); performSearch(query: query) }
                            }
                            ForEach(Array(filterExts).sorted(), id: \.self) { ext in
                                ActiveTagView(label: "扩展名: \(ext)") { filterExts.remove(ext); performSearch(query: query) }
                            }
                            if let size = filterSize {
                                ActiveTagView(label: "大小: \(size)") { filterSize = nil; performSearch(query: query) }
                            }
                            if let date = filterDate {
                                ActiveTagView(label: "时间: \(date)") { filterDate = nil; performSearch(query: query) }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                    }
                }
                
                // Table Header
                HStack(spacing: 16) {
                    Text("名称").frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
                    Text("路径").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                    Text("大小").frame(width: 70, alignment: .trailing)
                    Text("修改时间").frame(width: 100, alignment: .center)
                    Text("种类").frame(width: 60, alignment: .leading)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // Results List
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.offset) { index, item in
                                ResultRowView(
                                    index: index,
                                    item: item,
                                    query: query,
                                    isSelected: selectedIndex == index,
                                    isHovered: hoverIndex == index
                                )
                                .id(index)
                                .onHover { hovering in
                                    hoverIndex = hovering ? index : nil
                                }
                                .onTapGesture {
                                    selectedIndex = index
                                    openFile(at: item.path)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                    }
                    .onChange(of: selectedIndex, perform: { idx in
                        withAnimation {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    })
                }
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // Status Bar
                HStack(spacing: 6) {
                    Circle()
                        .fill(isIndexing ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                        .opacity(isIndexing ? 0.8 : 1.0)
                        .animation(isIndexing ? Animation.easeInOut(duration: 0.8).repeatForever() : .default, value: isIndexing)
                    
                    Text(isIndexing ? "更新中..." : "索引已就绪")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(results.count) \(results.count >= 100 ? "+" : "") items")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.2))
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            isSearchFocused = true
            setupKeyboardMonitor()
            if !hasSeenHelp {
                hasSeenHelp = true
                showHelp = true
            }
        }
        .sheet(isPresented: $showHelp) {
            HelpView(isPresented: $showHelp)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowHelp"))) { _ in
            showHelp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("IndexingStarted"))) { _ in
            isIndexing = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("IndexingFinished"))) { _ in
            isIndexing = false
            if !query.isEmpty {
                performSearch(query: query)
            }
        }
    }
    
    func performSearch(query: String) {
        if query.isEmpty {
            self.results = []
            self.selectedIndex = 0
            return
        }
        
        var finalQuery = query
        if settings.enableRegexDefault && !query.starts(with: "regex:") {
            finalQuery = "regex:\(query)"
        }
        
        if !filterKinds.isEmpty { finalQuery += " kind:\(filterKinds.joined(separator: "|"))" }
        if let date = filterDate { finalQuery += " date:\(date)" }
        if let size = filterSize { finalQuery += " size:\(size)" }
        if !filterExts.isEmpty { finalQuery += " ext:\(filterExts.joined(separator: "|"))" }
        
        finalQuery.withCString { ptr in
            if let resPtr = search(ptr, 100, settings.enablePathSearch) {
                let count = resPtr.pointee.count
                var paths = [String]()
                
                let buffer = UnsafeBufferPointer(start: resPtr.pointee.paths, count: count)
                for i in 0..<count {
                    if let cString = buffer[i] {
                        paths.append(String(cString: cString))
                    }
                }
                free_search_results(resPtr)
                
                // Fetch metadata asynchronously
                DispatchQueue.global(qos: .userInitiated).async {
                    let items = fetchMetadata(for: paths)
                    DispatchQueue.main.async {
                        self.results = items
                        self.selectedIndex = 0
                    }
                }
            }
        }
    }
    
    func fetchMetadata(for paths: [String]) -> [FileItem] {
        let fm = FileManager.default
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let homeDir = NSHomeDirectory()
        
        return paths.map { path in
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            var dirPath = url.deletingLastPathComponent().path
            if dirPath.hasPrefix(homeDir) {
                dirPath = "~" + dirPath.dropFirst(homeDir.count)
            }
            
            var sizeStr = "--"
            var dateStr = "--"
            var typeStr = "FILE"
            
            if let attrs = try? fm.attributesOfItem(atPath: path) {
                if let size = attrs[.size] as? Int64 {
                    if size < 1024 { sizeStr = "\(size) B" }
                    else if size < 1024 * 1024 { sizeStr = String(format: "%.1f KB", Double(size) / 1024.0) }
                    else if size < 1024 * 1024 * 1024 { sizeStr = String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0)) }
                    else { sizeStr = String(format: "%.2f GB", Double(size) / (1024.0 * 1024.0 * 1024.0)) }
                }
                if let date = attrs[.modificationDate] as? Date {
                    dateStr = dateFormatter.string(from: date)
                }
                if let type = attrs[.type] as? FileAttributeType, type == .typeDirectory {
                    typeStr = "DIR"
                    sizeStr = "--"
                } else {
                    let ext = url.pathExtension.uppercased()
                    typeStr = ext.isEmpty ? "FILE" : ext
                }
            }
            
            return FileItem(path: path, name: name, dirPath: dirPath, sizeStr: sizeStr, dateStr: dateStr, typeStr: typeStr)
        }
    }
    
    // MARK: - Keyboard Actions
    
    private func setupKeyboardMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            
            // ESC
            if keyCode == 53 {
                NSApp.hide(nil)
                return nil
            }
            
            // Cmd + Number (1-9)
            if event.modifierFlags.contains(.command),
               let char = event.charactersIgnoringModifiers?.first,
               let num = Int(String(char)),
               num >= 1 && num <= 9 {
                let index = num - 1
                if index < results.count {
                    openFile(at: results[index].path)
                }
                return nil
            }
            
            // Down Arrow
            if keyCode == 125 {
                if selectedIndex < results.count - 1 {
                    selectedIndex += 1
                    isNavigatingList = true
                }
                return nil
            }
            // Up Arrow
            else if keyCode == 126 {
                if selectedIndex > 0 {
                    selectedIndex -= 1
                    isNavigatingList = true
                }
                return nil
            }
            // Enter
            else if keyCode == 36 {
                if selectedIndex < results.count {
                    let path = results[selectedIndex].path
                    if event.modifierFlags.contains(.command) {
                        revealInFinder(at: path)
                    } else {
                        openFile(at: path)
                    }
                }
                return nil
            }
            // Space (for QuickLook)
            else if keyCode == 49 {
                if isNavigatingList || event.modifierFlags.contains(.command) {
                    if selectedIndex < results.count {
                        quickLook(at: results[selectedIndex].path)
                    }
                    return nil
                }
            }
            
            return event
        }
    }
    
    private func openFile(at path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    
    private func revealInFinder(at path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    
    private func quickLook(at path: String) {
        let task = Process()
        task.launchPath = "/usr/bin/qlmanage"
        task.arguments = ["-p", path]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        task.terminationHandler = { _ in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        
        try? task.run()
    }
}


// MARK: - Subviews

struct ResultRowView: View {
    let index: Int
    let item: FileItem
    let query: String
    let isSelected: Bool
    let isHovered: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            // Name Column (Icon + Highlighted Text)
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                
                highlightedText(for: item.name, query: query)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                
                Spacer(minLength: 0)
                
                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary.opacity(0.3))
                        .padding(.trailing, 4)
                }
            }
            .frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
            .help(item.name)
            
            // Path Column
            Text(item.dirPath)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                .help(item.dirPath)
            
            // Size Column
            Text(item.sizeStr)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: 70, alignment: .trailing)
            
            // Date Column
            Text(item.dateStr)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: 100, alignment: .center)
            
            // Type Column
            Text(item.typeStr)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: 60, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue.opacity(0.6) : (isHovered ? Color.white.opacity(0.05) : Color.clear))
        )
        .contentShape(Rectangle())
    }
    
    // Highlight logic
    func highlightedText(for text: String, query: String) -> Text {
        let cleanQuery = query.starts(with: "regex:") ? String(query.dropFirst(6)) : query
        
        if #available(macOS 12.0, *) {
            var attrStr = AttributedString(text)
            
            let pattern = query.starts(with: "regex:") ? cleanQuery : NSRegularExpression.escapedPattern(for: cleanQuery)
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
                
                // Process matches in reverse to safely mutate AttributedString
                for match in matches.reversed() {
                    let nsRange = match.range
                    if let stringRange = Range(nsRange, in: text), let attrRange = attrStr.range(of: text[stringRange]) {
                        attrStr[attrRange].backgroundColor = .yellow.opacity(0.8)
                        attrStr[attrRange].foregroundColor = .black
                    }
                }
            }
            return Text(attrStr)
        } else {
            // Fallback for macOS 11
            return Text(text)
        }
    }
}

// MARK: - Help View

struct HelpView: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("查询语法完整说明")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 16)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("先输入名字，需要时再变精确")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                        
                        Text("普通关键词永远是主路径。操作符只是让复杂文件库更快收敛。您可以组合使用任意操作符。")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    
                    // 核心语法
                    VStack(alignment: .leading, spacing: 12) {
                        Text("核心操作符")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                            HelpCard(title: "ext:扩展名", subtitle: "如 ext:pdf report (只看 PDF，名称含 report)。直接输入 pdf 也享有高亮权重。")
                            HelpCard(title: "path:路径或 in:路径", subtitle: "如 in:downloads (匹配在 downloads 目录下的文件)。等同于开启 Path 开关。")
                            HelpCard(title: "!排除词", subtitle: "如 design !draft (包含 design 但排除 draft)。")
                            HelpCard(title: "拼音与首字母", subtitle: "如 weixin 或 wx (匹配“微信”等字眼)。无缝支持中文拼音。")
                            HelpCard(title: "正则表达式 (Regex)", subtitle: "如 /^IMG_\\d{4}\\.jpg$/ (以 / 包裹，或者开启正则开关)。")
                        }
                    }
                    
                    // 高级过滤
                    VStack(alignment: .leading, spacing: 12) {
                        Text("类别与筛选 (高级过滤)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                            HelpCard(title: "kind:类别", subtitle: "支持: image, video, audio, doc(document), archive\n例如 kind:image (匹配所有图片格式)")
                            HelpCard(title: "size:大小", subtitle: "支持: >, < 配合 kb, mb, gb\n例如 size:>10mb (大于 10MB 的文件)")
                            HelpCard(title: "date:时间", subtitle: "支持: today, yesterday\n例如 date:today (今天修改过的文件)")
                            HelpCard(title: "多操作符组合", subtitle: "如 kind:image size:>2mb date:today")
                        }
                    }
                    
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .frame(width: 660, height: 420)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct HelpCard: View {
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(Color(red: 0.4, green: 0.7, blue: 1.0))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Advanced Filters UI

struct AdvancedFilterView: View {
    @Binding var filterKinds: Set<String>
    @Binding var filterDate: String?
    @Binding var filterSize: String?
    @Binding var filterExts: Set<String>
    var onFilterChanged: () -> Void
    
    @State private var customSizeOp: String = ">"
    @State private var customSizeVal: String = ""
    @State private var customExt: String = ""
    
    let kinds = [
        ("图片", "image"), ("视频", "video"), ("音频", "audio"), ("文档", "doc"), ("压缩包", "archive")
    ]
    let dates = [
        ("今天", "today"), ("昨天", "yesterday"), ("本周", "thisweek"), ("本月", "thismonth")
    ]
    let sizes = [
        ("> 10MB", ">10mb"), ("> 100MB", ">100mb"), ("> 1GB", ">1gb")
    ]
    let exts = [
        "pdf", "docx", "xlsx", "mp4", "mp3", "zip", "jpg", "png", "txt"
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FilterRowMulti(title: "类别", options: kinds, selectedValues: $filterKinds, onChanged: onFilterChanged)
            FilterRow(title: "时间", options: dates, selectedValue: $filterDate, onChanged: onFilterChanged)
            
            SizeFilterRow(filterSize: $filterSize, customSizeOp: $customSizeOp, customSizeVal: $customSizeVal, sizes: sizes, onFilterChanged: onFilterChanged)
            
            ExtFilterRow(filterExts: $filterExts, customExt: $customExt, exts: exts, onFilterChanged: onFilterChanged)
        }
        .padding(16)
        .background(Color.black.opacity(0.4))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
    
    private func applyCustomSize() {
        let val = customSizeVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !val.isEmpty {
            // Ensure there's a unit, if not append mb
            let finalVal = (val.hasSuffix("kb") || val.hasSuffix("mb") || val.hasSuffix("gb")) ? val : "\(val)mb"
            filterSize = "\(customSizeOp)\(finalVal)"
            onFilterChanged()
        }
    }
    
    private func applyCustomExt() {
        let val = customExt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !val.isEmpty {
            filterExts.insert(val)
            customExt = ""
            onFilterChanged()
        }
    }
}

struct FilterRowMulti: View {
    let title: String
    let options: [(label: String, value: String)]
    @Binding var selectedValues: Set<String>
    var onChanged: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
            
            ForEach(options, id: \.value) { option in
                Button(action: {
                    if selectedValues.contains(option.value) {
                        selectedValues.remove(option.value)
                    } else {
                        selectedValues.insert(option.value)
                    }
                    onChanged()
                }) {
                    Text(option.label)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(selectedValues.contains(option.value) ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .foregroundColor(selectedValues.contains(option.value) ? .white : .primary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

struct FilterRow: View {
    let title: String
    let options: [(label: String, value: String)]
    @Binding var selectedValue: String?
    var onChanged: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
            
            ForEach(options, id: \.value) { option in
                Button(action: {
                    if selectedValue == option.value {
                        selectedValue = nil
                    } else {
                        selectedValue = option.value
                    }
                    onChanged()
                }) {
                    Text(option.label)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(selectedValue == option.value ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .foregroundColor(selectedValue == option.value ? .white : .primary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

struct ActiveTagView: View {
    let label: String
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.6))
        .cornerRadius(16)
        .foregroundColor(.white)
    }
}

struct SizeFilterRow: View {
    @Binding var filterSize: String?
    @Binding var customSizeOp: String
    @Binding var customSizeVal: String
    let sizes: [(label: String, value: String)]
    var onFilterChanged: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Text("大小")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
            
            ForEach(sizes, id: \.value) { option in
                Button(action: {
                    if filterSize == option.value {
                        filterSize = nil
                    } else {
                        filterSize = option.value
                        customSizeVal = ""
                    }
                    onFilterChanged()
                }) {
                    Text(option.label)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(filterSize == option.value ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .foregroundColor(filterSize == option.value ? .white : .primary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            // Custom Size Input
            Picker("", selection: $customSizeOp) {
                Text(">").tag(">")
                Text("<").tag("<")
            }
            .pickerStyle(MenuPickerStyle())
            .frame(width: 45)
            .labelsHidden()
            
            TextField("如 500kb", text: $customSizeVal)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(width: 70)
                .font(.system(size: 12))
                .onSubmit { applyCustomSize() }
            
            if !customSizeVal.isEmpty {
                Button(action: applyCustomSize) {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Color.accentColor)
                        .cornerRadius(4)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private func applyCustomSize() {
        let val = customSizeVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !val.isEmpty {
            let finalVal = (val.hasSuffix("kb") || val.hasSuffix("mb") || val.hasSuffix("gb")) ? val : "\(val)mb"
            filterSize = "\(customSizeOp)\(finalVal)"
            onFilterChanged()
        }
    }
}

struct ExtFilterRow: View {
    @Binding var filterExts: Set<String>
    @Binding var customExt: String
    let exts: [String]
    var onFilterChanged: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Text("后缀")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
            
            ForEach(exts, id: \.self) { ext in
                Button(action: {
                    if filterExts.contains(ext) {
                        filterExts.remove(ext)
                    } else {
                        filterExts.insert(ext)
                    }
                    onFilterChanged()
                }) {
                    Text(ext)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(filterExts.contains(ext) ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .foregroundColor(filterExts.contains(ext) ? .white : .primary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            // Custom Ext Input
            TextField("如 apk", text: $customExt)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(width: 60)
                .font(.system(size: 12))
                .onSubmit { applyCustomExt() }
            
            if !customExt.isEmpty {
                Button(action: applyCustomExt) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Color.accentColor)
                        .cornerRadius(4)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private func applyCustomExt() {
        let val = customExt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !val.isEmpty {
            filterExts.insert(val)
            customExt = ""
            onFilterChanged()
        }
    }
}

import SwiftUI
import AppKit

/// A thread-safe, high-performance icon cache that wraps NSCache
actor IconCache {
    static let shared = IconCache()
    
    // NSCache is thread-safe, so it can be read from the nonisolated accessor below.
    nonisolated(unsafe) private let cache: NSCache<NSString, NSImage>
    
    private init() {
        self.cache = NSCache<NSString, NSImage>()
        // Optional: set limits if necessary to prevent unbounded memory growth
        self.cache.countLimit = 1000
    }
    
    /// Retrieves the icon synchronously if cached, otherwise returns nil.
    nonisolated func getCachedIcon(for path: String) -> NSImage? {
        return cache.object(forKey: path as NSString)
    }
    
    /// Fetches the icon from disk asynchronously, caching the result.
    func fetchIcon(for path: String) -> NSImage {
        // If it was already cached by a concurrent request, return it
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        
        // Fetch from disk
        let image = NSWorkspace.shared.icon(forFile: path)
        
        // Cache and return
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// A View that loads its icon asynchronously without blocking the main thread.
struct AsyncIconView: View {
    let path: String
    @State private var icon: NSImage?
    
    var body: some View {
        Group {
            if let img = icon {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                // Placeholder
                Image(nsImage: NSImage(named: NSImage.networkName) ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .opacity(0.1)
            }
        }
        .task(id: path) {
            // Check cache first synchronously to avoid flicker
            if let cached = IconCache.shared.getCachedIcon(for: path) {
                self.icon = cached
                return
            }
            
            // Clear current icon while loading if the path changed
            self.icon = nil
            
            // Fetch asynchronously on background task
            let fetched = await IconCache.shared.fetchIcon(for: path)
            
            // Switch back to main thread to update state
            await MainActor.run {
                self.icon = fetched
            }
        }
    }
}

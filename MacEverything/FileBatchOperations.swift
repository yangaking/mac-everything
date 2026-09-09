import AppKit
import PDFKit

/// Batch file operations applied to the multi-selected search results.
/// The pure helpers (URL mapping, range math, printable detection) are kept
/// separate so they can be exercised by a standalone test script.
enum FileBatchOperations {

    // MARK: - Pure helpers (unit-tested via tests/sandbox)

    /// Converts paths to file URLs.
    static func fileURLs(for paths: [String]) -> [URL] {
        paths.map { URL(fileURLWithPath: $0) }
    }

    /// Inclusive index range between two indices, independent of their order.
    static func rangeIndices(from a: Int, to b: Int) -> Range<Int> {
        let lo = min(a, b), hi = max(a, b)
        return lo..<(hi + 1)
    }

    /// Image extensions that NSImage can load and print.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "heif"
    ]

    /// Whether this file type can be printed by the batch printer (image or PDF).
    static func isPrintable(path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ext == "pdf" || imageExtensions.contains(ext)
    }

    // MARK: - Operations

    /// Copies the files themselves to the pasteboard (paste into Finder, etc.).
    static func copyFiles(_ paths: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(fileURLs(for: paths) as [NSURL])
    }

    /// Copies the plain paths (one per line) to the pasteboard.
    static func copyPaths(_ paths: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// Opens every file with its default application.
    static func openFiles(_ paths: [String]) {
        for url in fileURLs(for: paths) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reveals every file in Finder (selects them all together).
    static func revealFiles(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(fileURLs(for: paths))
    }

    /// Moves every file to the Trash.
    static func moveToTrash(_ paths: [String]) {
        let fm = FileManager.default
        for url in fileURLs(for: paths) {
            var resultingURL: NSURL? = nil
            try? fm.trashItem(at: url, resultingItemURL: &resultingURL)
        }
    }

    /// Prints the printable files (images + PDFs) straight to the default
    /// printer without showing a per-file dialog. Returns printed/skipped counts.
    static func printFiles(_ paths: [String]) -> (printed: Int, skipped: Int) {
        var printed = 0
        var skipped = 0
        for path in paths {
            if printOne(path) {
                printed += 1
            } else {
                skipped += 1
            }
        }
        return (printed, skipped)
    }

    private static func printOne(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        var operation: NSPrintOperation? = nil

        if imageExtensions.contains(ext), let image = NSImage(contentsOf: url) {
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
            view.image = image
            operation = NSPrintOperation(view: view)
        } else if ext == "pdf", let doc = PDFDocument(url: url) {
            operation = doc.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true)
        }

        guard let operation = operation else { return false }
        operation.showsPrintPanel = false
        operation.showsProgressPanel = true
        return operation.run()
    }
}

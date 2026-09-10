import SwiftUI
import Quartz

/// Manages a `QLPreviewPanel` using the modern dataSource/delegate API.
///
/// The deprecated responder-chain control methods (`acceptsPreviewPanelControl`,
/// `beginPreviewPanelControl`, `endPreviewPanelControl`) are no longer used; the
/// panel's data source and delegate are assigned directly instead.
final class QuickLookHelper: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// Invoked when the user closes the Quick Look panel manually.
    var onPanelClosed: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    var previewURL: URL? {
        didSet {
            guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
            panel.reloadData()
        }
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }

    // MARK: - Panel control

    /// Shows the Quick Look panel for `url`, or hides it when `url` is nil.
    func present(_ url: URL?) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }

        if url != nil {
            panel.dataSource = self
            panel.delegate = self
            if !panel.isVisible {
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.reloadData()
            }
            observeClose(of: panel)
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func observeClose(of panel: QLPreviewPanel) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let observer = self.closeObserver {
                NotificationCenter.default.removeObserver(observer)
                self.closeObserver = nil
            }
            self.onPanelClosed?()
        }
    }
}

struct QuickLookViewRepresentable: NSViewRepresentable {
    @Binding var previewURL: URL?

    func makeNSView(context: Context) -> QuickLookHelper {
        let view = QuickLookHelper()
        view.onPanelClosed = {
            DispatchQueue.main.async {
                self.previewURL = nil
            }
        }
        return view
    }

    func updateNSView(_ nsView: QuickLookHelper, context: Context) {
        nsView.present(previewURL)
    }
}

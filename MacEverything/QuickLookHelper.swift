import SwiftUI
import Quartz


class QuickLookHelper: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    
    // Using a callback to notify SwiftUI when the panel is closed by the user
    var onPanelClosed: (() -> Void)?
    
    private var reloadWorkItem: DispatchWorkItem?
    
    var previewURL: URL? {
        didSet {
            if let panel = QLPreviewPanel.shared(), panel.isVisible {
                reloadWorkItem?.cancel()
                let item = DispatchWorkItem {
                    if panel.isVisible {
                        panel.reloadData()
                    }
                }
                reloadWorkItem = item
                // 50ms debounce for smoother scrolling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
            }
        }
    }
    
    // We must accept first responder so that QLPreviewPanel can find us in the responder chain
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    // MARK: - QLPreviewPanel Responder Chain Methods
    
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }
    
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = self
        panel.dataSource = self
    }
    
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = nil
        panel.dataSource = nil
    }
    
    // MARK: - QLPreviewPanelDataSource
    
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return previewURL == nil ? 0 : 1
    }
    
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return previewURL as NSURL?
    }
    
    // MARK: - QLPreviewPanelDelegate
    
    func windowWillClose(_ notification: Notification) {
        // When the QuickLook window is closed manually (e.g. by clicking the close button or pressing space while focused on QL)
        if let panel = notification.object as? QLPreviewPanel, panel == QLPreviewPanel.shared() {
            onPanelClosed?()
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
        // Synchronize state
        nsView.previewURL = previewURL
        
        DispatchQueue.main.async {
            guard let panel = QLPreviewPanel.shared() else { return }
            
            if previewURL != nil {
                // If it's not visible, show it
                if !panel.isVisible {
                    // Make this view first responder so QLPreviewPanel uses it
                    nsView.window?.makeFirstResponder(nsView)
                    panel.makeKeyAndOrderFront(nil)
                }
            } else {
                // If it's visible but we have no URL, close it
                if panel.isVisible {
                    panel.orderOut(nil)
                }
            }
        }
    }
}

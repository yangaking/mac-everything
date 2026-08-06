import SwiftUI
import AppKit

struct PermissionView: View {
    let checkPermissionAction: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
                .padding(.bottom, 8)
            
            Text("需要完全磁盘访问权限")
                .font(.title)
                .fontWeight(.bold)
            
            Text("MacEverything 需要拥有完全磁盘访问权限 (Full Disk Access) 才能进行全局极速搜索。\n如果没有此权限，搜索过程将不断触发系统的权限警告弹窗。")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("如何授权：")
                    .fontWeight(.semibold)
                
                Text("1. 点击下方按钮打开「系统设置」")
                Text("2. 点击左下角的🔒解锁")
                Text("3. 在列表中找到 **MacEverything** 并勾选")
                Text("4. 授权后，点击下方的「我已授权」按钮重试")
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            
            HStack(spacing: 16) {
                Button(action: {
                    openPrivacySettings()
                }) {
                    Text("打开系统设置")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(BorderedProminentButtonStyle())
                
                Button(action: {
                    checkPermissionAction()
                }) {
                    Text("我已授权")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
            .padding(.top, 16)
        }
        .padding(40)
        .frame(width: 500)
    }
    
    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

class PermissionManager {
    /// Checks if the app has Full Disk Access by attempting to open the TCC.db directory.
    static func hasFullDiskAccess() -> Bool {
        // TCC.db is restricted to FDA. Checking accessibility is a safe, prompt-free way to test for FDA.
        let path = "/Library/Application Support/com.apple.TCC/TCC.db"
        let fileDescriptor = open(path, O_RDONLY)
        if fileDescriptor != -1 {
            close(fileDescriptor)
            return true
        }
        
        // As a fallback (some macOS versions restrict opening TCC.db even with FDA)
        // Check if we can read the user's Safari Bookmarks which is also FDA restricted
        let safariPath = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
        let safariFd = open(safariPath, O_RDONLY)
        if safariFd != -1 {
            close(safariFd)
            return true
        }
        
        return false
    }
}

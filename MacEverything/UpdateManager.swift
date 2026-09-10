import Foundation
import AppKit

class UpdateManager {
    static let shared = UpdateManager()
    let repoUrl = "https://api.github.com/repos/yangaking/mac-everything/releases/latest"
    let releasesUrl = "https://github.com/yangaking/mac-everything/releases/latest"
    
    func checkForUpdates(manual: Bool) {
        guard let url = URL(string: repoUrl) else { return }
        
        // Add User-Agent header which is required by GitHub API
        var request = URLRequest(url: url)
        request.setValue("MacEverything-App", forHTTPHeaderField: "User-Agent")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                if manual {
                    self.showAlert(title: "检查更新失败", message: error.localizedDescription)
                }
                return
            }
            
            guard let data = data else {
                if manual {
                    self.showAlert(title: "检查更新失败", message: "未从 GitHub 收到数据。")
                }
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let tagName = json["tag_name"] as? String {
                    
                    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
                    
                    // Basic string comparison for version
                    let latest = tagName.replacingOccurrences(of: "v", with: "")
                    let current = currentVersion.replacingOccurrences(of: "v", with: "")
                    
                    if latest != current && latest.compare(current, options: .numeric) == .orderedDescending {
                        self.showUpdateAlert(latestVersion: tagName)
                    } else {
                        if manual {
                            self.showAlert(title: "已是最新版本", message: "你正在使用最新版本（\(currentVersion)）。")
                        }
                    }
                } else if manual {
                    self.showAlert(title: "检查更新失败", message: "GitHub API 返回无效响应。")
                }
            } catch {
                if manual {
                    self.showAlert(title: "检查更新失败", message: "无法解析更新数据。")
                }
            }
        }
        task.resume()
    }
    
    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好")
            // Ensure app is active so alert is visible
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    
    private func showUpdateAlert(latestVersion: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "发现新版本"
            alert.informativeText = "MacEverything 有新版本（\(latestVersion)）！是否前往下载？"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "下载")
            alert.addButton(withTitle: "稍后")
            
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: self.releasesUrl) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

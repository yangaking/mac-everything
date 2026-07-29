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
                    self.showAlert(title: "Update Check Failed", message: error.localizedDescription)
                }
                return
            }
            
            guard let data = data else {
                if manual {
                    self.showAlert(title: "Update Check Failed", message: "No data received from GitHub.")
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
                            self.showAlert(title: "Up to Date", message: "You are running the latest version (\(currentVersion)).")
                        }
                    }
                } else if manual {
                    self.showAlert(title: "Update Check Failed", message: "Invalid response from GitHub API.")
                }
            } catch {
                if manual {
                    self.showAlert(title: "Update Check Failed", message: "Could not parse update data.")
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
            alert.addButton(withTitle: "OK")
            // Ensure app is active so alert is visible
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    
    private func showUpdateAlert(latestVersion: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Update Available"
            alert.informativeText = "A new version (\(latestVersion)) of MacEverything is available! Would you like to download it?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: self.releasesUrl) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

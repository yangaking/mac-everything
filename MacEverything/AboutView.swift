import SwiftUI
import AppKit

struct AboutView: View {
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                .resizable()
                .frame(width: 80, height: 80)
            
            Text("MacEverything")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Version \(appVersion)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("Author: yang aking")
                .font(.body)
                .padding(.top, 4)
            
            HStack(spacing: 20) {
                Button("Check for Updates") {
                    UpdateManager.shared.checkForUpdates(manual: true)
                }
                
                Button("GitHub") {
                    if let url = URL(string: "https://github.com/yangaking/mac-everything") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(.top, 8)
        }
        .padding(30)
        .frame(width: 350, height: 250)
    }
}

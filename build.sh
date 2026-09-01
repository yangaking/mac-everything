#!/bin/bash
set -e

echo "Stopping existing app..."
killall MacEverything 2>/dev/null || true

echo "Removing old build files..."
rm -rf build/MacEverything.app
mkdir -p build/MacEverything.app/Contents/{MacOS,Resources}

# Set deployment target for macOS 12.0 (Monterey)
export MACOSX_DEPLOYMENT_TARGET=12.0

# Compile the Rust core
cd mac-everything-core
cargo build --release
cd ..

# Ensure build output directory exists
mkdir -p build/MacEverything.app/Contents/MacOS
mkdir -p build/MacEverything.app/Contents/Resources

# Create minimal Info.plist
cat << 'EOF' > build/MacEverything.app/Contents/Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>CFBundleExecutable</key>
	<string>MacEverything</string>
	<key>CFBundleIdentifier</key>
	<string>com.example.MacEverything.v2</string>
	<key>CFBundleName</key>
	<string>MacEverything</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.5</string>
	<key>CFBundleVersion</key>
	<string>3</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSUIElement</key>
	<true/> <!-- Hide from Dock -->
	<key>NSAppSleepDisabled</key>
	<true/> <!-- Prevent App Nap entirely at the plist level -->
	<key>NSDesktopFolderUsageDescription</key>
	<string>MacEverything 需要访问您的桌面文件夹以提供极速全局搜索服务。</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>MacEverything 需要访问您的文档文件夹以提供极速全局搜索服务。</string>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>MacEverything 需要访问您的下载文件夹以提供极速全局搜索服务。</string>
	<key>NSNetworkVolumesUsageDescription</key>
	<string>MacEverything 需要访问网络卷以提供全盘极速搜索服务。</string>
	<key>NSRemovableVolumesUsageDescription</key>
	<string>MacEverything 需要访问外部磁盘以提供全盘极速搜索服务。</string>
</dict>
</plist>
EOF

# Copy AppIcon
cp Resources/AppIcon.icns build/MacEverything.app/Contents/Resources/

# Compile Swift code
swiftc \
    MacEverything/main.swift \
    MacEverything/MacEverythingApp.swift \
    MacEverything/VisualEffectView.swift \
    MacEverything/ContentView.swift \
    MacEverything/SettingsView.swift \
    MacEverything/HotKeyManager.swift \
    MacEverything/UpdateManager.swift \
    MacEverything/AboutView.swift \
    MacEverything/QuickLookHelper.swift \
    MacEverything/IconCache.swift \
    MacEverything/PermissionView.swift \
    mac-everything-core/target/release/libmac_everything_core.a \
    -target $(uname -m)-apple-macosx12.0 \
    -I MacEverything \
    -framework SwiftUI \
    -framework AppKit \
    -framework Quartz \
    -o build/MacEverything.app/Contents/MacOS/MacEverything

echo "Signing app with MacEverythingCert (if available)..."
find build/MacEverything.app -exec xattr -c {} \; 2>/dev/null || true
find build/MacEverything.app -name ".DS_Store" -delete
codesign --force --deep --sign "MacEverythingCert" build/MacEverything.app || echo "Warning: MacEverythingCert not found. App signed with ad-hoc signature."

# Force Finder to refresh the icon cache (Bulletproof method via NSWorkspace)
cat << 'EOF' > set_icon_build.swift
import Cocoa
let appPath = "build/MacEverything.app"
let iconPath = "build/MacEverything.app/Contents/Resources/AppIcon.icns"
if let image = NSImage(contentsOfFile: iconPath) {
    _ = NSWorkspace.shared.setIcon(image, forFile: appPath, options: [])
}
EOF
swift set_icon_build.swift
rm set_icon_build.swift

echo "Build complete! App is located at build/MacEverything.app"

#!/bin/bash
set -e

# Ensure the Rust toolchain is on PATH (rustup installs to ~/.cargo/bin, which is
# not always present in non-interactive shells / GUI-launched scripts).
if [ -d "$HOME/.cargo/bin" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi

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
	<string>0.1.6</string>
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

# Signing. Default is ad-hoc (`-`), which is sufficient for personal/open-source
# distribution (users right-click -> Open on first launch). To sign for smooth
# distribution, set DEVELOPER_ID to your "Developer ID Application" identity:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh
SIGN_IDENTITY="${DEVELOPER_ID:--}"
echo "Signing app (identity: $SIGN_IDENTITY)..."
find build/MacEverything.app -exec xattr -c {} \; 2>/dev/null || true
find build/MacEverything.app -name ".DS_Store" -delete
codesign --force --deep --sign "$SIGN_IDENTITY" build/MacEverything.app

# Optional notarization (requires an Apple Developer account). Enable with:
#   NOTARIZE=1 NOTARY_PROFILE=<stored-notarytool-profile> ./build.sh
if [ "${NOTARIZE:-0}" = "1" ]; then
    echo "Submitting for notarization..."
    ditto -c -k --keepParent build/MacEverything.app build/MacEverything.zip
    xcrun notarytool submit build/MacEverything.zip --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple build/MacEverything.app
    rm -f build/MacEverything.zip
fi

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

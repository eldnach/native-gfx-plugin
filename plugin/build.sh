# Example usage:
#   ./build.sh "/Applications/Unity/Hub/Editor/<ver>/Unity.app/Contents/PluginAPI"
#   UNITY_PLUGIN_API="/path/to/PluginAPI" ./build.sh

set -euo pipefail

UNITY_PLUGIN_API="${1:-${UNITY_PLUGIN_API:-}}"

if [ -z "$UNITY_PLUGIN_API" ]; then
    echo "ERROR: Unity PluginAPI header path not provided." >&2
    echo "       Pass it as an argument or via the UNITY_PLUGIN_API env var:" >&2
    echo "         ./build.sh \"/Applications/Unity/Hub/Editor/<ver>/Unity.app/Contents/PluginAPI\"" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/NativeGfxPlugin_Metal.mm"
OUT_DIR="$SCRIPT_DIR/build"
BUNDLE="$OUT_DIR/NativeGfxPlugin.bundle"
MACOS_DIR="$BUNDLE/Contents/MacOS"
BIN="$MACOS_DIR/NativeGfxPlugin"

if [ ! -f "$UNITY_PLUGIN_API/IUnityGraphicsMetal.h" ]; then
    echo "ERROR: Unity PluginAPI headers not found at: $UNITY_PLUGIN_API" >&2
    echo "       Set UNITY_PLUGIN_API to your Unity.app/Contents/PluginAPI folder." >&2
    exit 1
fi

rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR"

clang++ -bundle \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min=11.0 \
    -fobjc-arc \
    -ObjC++ -std=c++17 \
    -fvisibility=hidden \
    -I"$UNITY_PLUGIN_API" \
    -framework Metal -framework Foundation \
    -o "$BIN" \
    "$SRC"

cat > "$BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>NativeGfxPlugin</string>
    <key>CFBundleIdentifier</key>          <string>com.eldnach.nativegfxplugin</string>
    <key>CFBundleName</key>                <string>NativeGfxPlugin</string>
    <key>CFBundlePackageType</key>         <string>BNDL</string>
    <key>CFBundleVersion</key>             <string>1.0</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
</dict>
</plist>
EOF

echo "Built: $BUNDLE"
echo "Copy it to <YourUnityProject>/Assets/Plugins/  (Editor will import it as a macOS plugin)."

#!/bin/bash
# Builds "MKT Launcher.app" (universal: Apple Silicon + Intel) using swiftc directly.
# Usage: ./build.sh            -> build/MKT Launcher.app
#        ./build.sh --arm-only -> build only for Apple Silicon (faster)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MKT Launcher"
BUNDLE_ID="gr.kotsovolos.mktlauncher"
VERSION="1.0"
MIN_MACOS="13.0"
SWIFTTERM_TAG="v1.20.0"

# Pick an SDK that matches the installed compiler (the newest SDK may be ahead of swiftc).
if [[ -z "${SDK:-}" ]]; then
  SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
  probe="$(mktemp -d)"
  echo 'print(1)' > "$probe/p.swift"
  if ! swiftc -sdk "$SDK" -typecheck "$probe/p.swift" >/dev/null 2>&1; then
    SDK=""
    for cand in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.*.sdk 2>/dev/null | sort -rV); do
      if swiftc -sdk "$cand" -typecheck "$probe/p.swift" >/dev/null 2>&1; then SDK="$cand"; break; fi
    done
  fi
  rm -rf "$probe"
  [[ -n "$SDK" ]] || { echo "No macOS SDK compatible with swiftc found." >&2; exit 1; }
fi
echo "SDK: $SDK"

ARCHS=(arm64 x86_64)
[[ "${1:-}" == "--arm-only" ]] && ARCHS=(arm64)

# Fetch SwiftTerm (terminal emulator library) if missing.
if [[ ! -d Vendor/SwiftTerm/Sources/SwiftTerm ]]; then
  git clone -q --depth 1 --branch "$SWIFTTERM_TAG" https://github.com/migueldeicaza/SwiftTerm.git Vendor/SwiftTerm
fi

BUILD=build
mkdir -p "$BUILD"
cat > "$BUILD/SwiftTermBuildInfo.swift" <<EOF
public enum SwiftTermBuildInfo {
    public static let branch: String? = nil
    public static let tag: String? = "$SWIFTTERM_TAG"
    public static let commit: String? = nil
    public static let hasUncommittedChanges: Bool? = false
    public static let version: String = "$SWIFTTERM_TAG"
}
EOF

ST_SOURCES=()
while IFS= read -r f; do ST_SOURCES+=("$f"); done < <(find Vendor/SwiftTerm/Sources/SwiftTerm -name '*.swift' -not -path '*/iOS/*' | sort)
APP_SOURCES=()
while IFS= read -r f; do APP_SOURCES+=("$f"); done < <(find Sources/MKTLauncher -name '*.swift' | sort)

BINARIES=()
for ARCH in "${ARCHS[@]}"; do
  OUT="$BUILD/$ARCH"
  mkdir -p "$OUT"
  TARGET="$ARCH-apple-macos$MIN_MACOS"
  if [[ ! -f "$OUT/libSwiftTerm.a" ]]; then
    echo "Compiling SwiftTerm ($ARCH)... (one-time, takes a few minutes)"
    swiftc -sdk "$SDK" -target "$TARGET" -swift-version 5 -O -wmo -parse-as-library \
      -module-name SwiftTerm -emit-library -static \
      -emit-module -emit-module-path "$OUT/SwiftTerm.swiftmodule" \
      -o "$OUT/libSwiftTerm.a" "${ST_SOURCES[@]}" "$BUILD/SwiftTermBuildInfo.swift" 2>&1 \
      | grep -E "error:" || true
    [[ -f "$OUT/libSwiftTerm.a" ]] || { echo "SwiftTerm build failed" >&2; exit 1; }
  fi
  echo "Compiling app ($ARCH)..."
  swiftc -sdk "$SDK" -target "$TARGET" -swift-version 5 -O -parse-as-library \
    -module-name MKTLauncher -I "$OUT" -L "$OUT" -lSwiftTerm \
    -o "$OUT/MKTLauncher" "${APP_SOURCES[@]}"
  BINARIES+=("$OUT/MKTLauncher")
done

APP="$BUILD/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/MKTLauncher"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Default connection list shown on first launch (Config/connections.json is local-only).
if [[ -f Config/connections.json ]]; then
  cp Config/connections.json "$APP/Contents/Resources/default-connections.json"
else
  echo "note: Config/connections.json not found, bundling the example connection list"
  cp Config/connections.example.json "$APP/Contents/Resources/default-connections.json"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>MKTLauncher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Connects to telnet hosts on the company network.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>KoalaTerm Setup File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleTypeExtensions</key><array><string>mkt</string><string>MKT</string></array>
      <key>LSHandlerRank</key><string>Owner</string>
    </dict>
  </array>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"
echo "Built: $APP ($(lipo -archs "$APP/Contents/MacOS/MKTLauncher"))"

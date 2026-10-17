#!/bin/sh
set -eu

usage() {
    printf '用法: sh scripts/build-app.sh [--adhoc-sign]\n'
}
SIGN=0
case "${1:-}" in
    '') ;;
    --adhoc-sign) SIGN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
if [ "$(uname -s)" != Darwin ]; then
    printf '错误：仅支持在 macOS 上构建。\n' >&2
    exit 1
fi

swift build -j 1 -c release --product MTunl
swift build -j 1 -c release --product mtunlctl
swift build -j 1 -c release --product mtunl-helper

BIN=$(swift build -c release --show-bin-path)
for NAME in MTunl mtunlctl mtunl-helper; do
    if [ ! -x "$BIN/$NAME" ]; then
        printf '错误：未找到可执行文件 %s\n' "$BIN/$NAME" >&2
        exit 1
    fi
done

mkdir -p dist
STAGE=$(mktemp -d "$ROOT/dist/.MTunl.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 1' HUP INT TERM
APP="$STAGE/MTunl.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/MTunl" "$APP/Contents/MacOS/MTunl"
cp "$BIN/mtunlctl" "$APP/Contents/MacOS/mtunlctl"
cp "$BIN/mtunl-helper" "$APP/Contents/MacOS/mtunl-helper"

chmod 755 "$APP/Contents/MacOS/MTunl" "$APP/Contents/MacOS/mtunlctl" "$APP/Contents/MacOS/mtunl-helper"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>MTunl</string>
    <key>CFBundleIdentifier</key><string>local.mtunl.MTunl</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>MTunl</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
if [ "$SIGN" -eq 1 ]; then
    codesign --force --sign - "$APP/Contents/MacOS/mtunlctl"
        codesign --force --sign - "$APP/Contents/MacOS/mtunl-helper"
    
    codesign --force --sign - "$APP"
    codesign --verify --deep --strict "$APP"
fi
# Replace the old bundle only after build, staging and optional signing succeed.
if [ -e "$ROOT/dist/MTunl.app" ]; then
    rm -rf "$ROOT/dist/MTunl.app"
fi
mv "$APP" "$ROOT/dist/MTunl.app"
printf '已生成 %s/dist/MTunl.app\n' "$ROOT"

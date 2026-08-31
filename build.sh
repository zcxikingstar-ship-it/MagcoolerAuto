#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h}"
build_dir="$root_dir/build"
app_dir="$build_dir/Magcooler 控制器.app"
contents="$app_dir/Contents"
resources="$contents/Resources"
macos_dir="$contents/MacOS"
icon_source="$root_dir/Assets/AppIcon.png"

mkdir -p "$build_dir/objects" "$resources" "$macos_dir"

for arch in arm64 x86_64; do
  xcrun clang -arch "$arch" -mmacosx-version-min=12.0 \
    -c "$root_dir/Sources/TemperatureReader.c" \
    -o "$build_dir/objects/TemperatureReader-$arch.o"

  xcrun swiftc -parse-as-library -swift-version 5 -target "$arch-apple-macos12.0" \
    -import-objc-header "$root_dir/Sources/TemperatureReader.h" \
    "$root_dir/Sources/AutoPolicy.swift" \
    "$root_dir/Sources/main.swift" \
    "$build_dir/objects/TemperatureReader-$arch.o" \
    -framework AppKit -framework CoreBluetooth -framework CoreFoundation -framework IOKit \
    -o "$build_dir/objects/MagcoolerController-$arch"
done

lipo -create \
  "$build_dir/objects/MagcoolerController-arm64" \
  "$build_dir/objects/MagcoolerController-x86_64" \
  -output "$macos_dir/MagcoolerController"

if [[ -f "$icon_source" ]]; then
  iconset="$build_dir/AppIcon.iconset"
  mkdir -p "$iconset"
  sips -z 16 16 "$icon_source" --out "$iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$icon_source" --out "$iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$icon_source" --out "$iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$icon_source" --out "$iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$icon_source" --out "$iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$icon_source" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$icon_source" --out "$iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$icon_source" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$icon_source" --out "$iconset/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$icon_source" --out "$iconset/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
fi

plutil -create xml1 "$contents/Info.plist"
plutil -insert CFBundleDisplayName -string 'Magcooler 控制器' "$contents/Info.plist"
plutil -insert CFBundleExecutable -string MagcoolerController "$contents/Info.plist"
plutil -insert CFBundleIdentifier -string local.codex.magcooler-controller "$contents/Info.plist"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$contents/Info.plist"
plutil -insert CFBundleName -string 'Magcooler 控制器' "$contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 1.3 "$contents/Info.plist"
plutil -insert CFBundleVersion -string 4 "$contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 12.0 "$contents/Info.plist"
plutil -insert NSBluetoothAlwaysUsageDescription -string '用于连接并控制你的 Redmagic Magcooler 散热器。' "$contents/Info.plist"
plutil -insert NSBluetoothPeripheralUsageDescription -string '用于连接并控制你的 Redmagic Magcooler 散热器。' "$contents/Info.plist"
plutil -insert NSHighResolutionCapable -bool true "$contents/Info.plist"
if [[ -f "$resources/AppIcon.icns" ]]; then
  plutil -insert CFBundleIconFile -string AppIcon "$contents/Info.plist"
fi

codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
echo "$app_dir"

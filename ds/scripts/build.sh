#!/usr/bin/env bash
# Build Cofi for iphoneos and package the resulting .app into a
# versioned IPA under build/, e.g. build/Cofi-1.0.ipa, with a
# build/Cofi.ipa symlink pointing at the latest build.
# With SDK=iphonesimulator, build the simulator .app and skip IPA
# packaging.
#
# Run as: ./scripts/build.sh
# Override defaults with env vars:
#   SCHEME, CONFIG (Debug|Release|VPhone Debug), SDK (iphoneos|iphonesimulator)
#
# Version comes from CFBundleShortVersionString in the built Info.plist
# (= the MARKETING_VERSION build setting in the xcodeproj). Bump
# MARKETING_VERSION to ship a new version.
#
# Code signing is disabled — the IPA ships unsigned for sideload via
# AltStore / TrollStore / Sideloadly, which do their own signing.

set -euo pipefail

cd "$(dirname "$0")/.."

# NOTE: SCHEME / PROJECT / APP_NAME still reference "Cofi" — that's
# the internal Xcode scheme + binary name kept for build tooling.  The
# shipping product is identified by CFBundleDisplayName=Cofi and
# bundle id Ds.Freefire.Esp (see Info.plist and project.pbxproj).
SCHEME="${SCHEME:-Cofi}"
if [ "$SCHEME" = "CofiVPhone" ]; then
    CONFIG="${CONFIG:-VPhone Debug}"
    if [ "$CONFIG" != "VPhone Debug" ]; then
        echo "error: CofiVPhone must use CONFIG='VPhone Debug'" >&2
        exit 1
    fi
else
    CONFIG="${CONFIG:-Debug}"
    if [ "$CONFIG" = "VPhone Debug" ]; then
        echo "error: CONFIG='VPhone Debug' is only for SCHEME=CofiVPhone" >&2
        exit 1
    fi
fi
SDK="${SDK:-iphoneos}"
PROJECT="ds.xcodeproj"
DERIVED="$PWD/build/DerivedData"
PRODUCT_DIR="$DERIVED/Build/Products/${CONFIG}-${SDK}"
APP_NAME="Cofi.app"
if [ "$SCHEME" = "CofiVPhone" ]; then
    IPA_PREFIX="CofiVPhone"
else
    IPA_PREFIX="Cofi"
fi
IPA_LATEST="$PWD/build/${IPA_PREFIX}.ipa"
XCODEBUILD_EXTRA=()

if [ "$SDK" = "iphonesimulator" ]; then
    XCODEBUILD_EXTRA=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
fi

mkdir -p build

echo "==> xcodebuild ($SCHEME / $CONFIG / $SDK)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -sdk "$SDK" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    ${XCODEBUILD_EXTRA[@]+"${XCODEBUILD_EXTRA[@]}"} \
    build \
    | xcbeautify --quiet 2>/dev/null \
    || xcodebuild \
         -project "$PROJECT" \
         -scheme "$SCHEME" \
         -sdk "$SDK" \
         -configuration "$CONFIG" \
         -derivedDataPath "$DERIVED" \
         CODE_SIGNING_ALLOWED=NO \
         ${XCODEBUILD_EXTRA[@]+"${XCODEBUILD_EXTRA[@]}"} \
         build

APP_PATH="$PRODUCT_DIR/$APP_NAME"
if [ ! -d "$APP_PATH" ]; then
    echo "error: $APP_PATH not found after build" >&2
    exit 1
fi

if [ "$SDK" = "iphonesimulator" ]; then
    echo "==> simulator app $APP_PATH"
    exit 0
fi

if [ "$SCHEME" = "CofiVPhone" ]; then
    VPHONE_BRIDGE_SRC="$PWD/vphone-assets/vphone_springboard_bridge.dylib"
    VPHONE_BRIDGE_SOURCE="$PWD/vphone-assets/vphone_springboard_bridge.m"
    VPHONE_BRIDGE_DST="$APP_PATH/vphone_springboard_bridge.dylib"
    if [ -f "$VPHONE_BRIDGE_SOURCE" ]; then
        echo "==> building vphone SpringBoard bridge"
        VPHONE_BRIDGE_BUILD="$PWD/build/vphone-bridge"
        VPHONE_BRIDGE_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
        mkdir -p "$VPHONE_BRIDGE_BUILD"
        xcrun --sdk iphoneos clang -arch arm64 \
            -isysroot "$VPHONE_BRIDGE_SDK" \
            -miphoneos-version-min=15.0 \
            -dynamiclib \
            "$VPHONE_BRIDGE_SOURCE" \
            -framework Foundation -framework CoreFoundation -lobjc \
            -install_name @rpath/vphone_springboard_bridge.dylib \
            -o "$VPHONE_BRIDGE_BUILD/vphone_springboard_bridge.arm64.dylib"
        xcrun --sdk iphoneos clang -arch arm64e \
            -isysroot "$VPHONE_BRIDGE_SDK" \
            -miphoneos-version-min=15.0 \
            -dynamiclib \
            "$VPHONE_BRIDGE_SOURCE" \
            -framework Foundation -framework CoreFoundation -lobjc \
            -install_name @rpath/vphone_springboard_bridge.dylib \
            -o "$VPHONE_BRIDGE_BUILD/vphone_springboard_bridge.arm64e.dylib"
        lipo -create \
            "$VPHONE_BRIDGE_BUILD/vphone_springboard_bridge.arm64.dylib" \
            "$VPHONE_BRIDGE_BUILD/vphone_springboard_bridge.arm64e.dylib" \
            -output "$VPHONE_BRIDGE_SRC"
    fi
    if [ ! -f "$VPHONE_BRIDGE_SRC" ]; then
        echo "error: missing vphone bridge dylib: $VPHONE_BRIDGE_SRC" >&2
        exit 1
    fi
    echo "==> bundling vphone SpringBoard bridge"
    ditto "$VPHONE_BRIDGE_SRC" "$VPHONE_BRIDGE_DST"
    chmod 0755 "$VPHONE_BRIDGE_DST"
    ldid -S "$VPHONE_BRIDGE_DST"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Info.plist" 2>/dev/null || true)
if [ -z "$VERSION" ]; then
    echo "error: could not read CFBundleShortVersionString from $APP_PATH/Info.plist" >&2
    exit 1
fi

IPA_OUT="$PWD/build/${IPA_PREFIX}-${VERSION}.ipa"
IPA_BASENAME="$(basename "$IPA_OUT")"
LATEST_BASENAME="$(basename "$IPA_LATEST")"

echo "==> packaging $IPA_OUT (version $VERSION)"
STAGE="$(mktemp -d -t external-ff-ipa)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP_PATH" "$STAGE/Payload/"
rm -f "$IPA_OUT"
( cd "$STAGE" && zip -qry "$IPA_OUT" Payload )

# Unversioned symlink so tooling / README references still resolve to
# the latest build.
rm -f "$IPA_LATEST"
( cd "$PWD/build" && ln -s "$IPA_BASENAME" "$LATEST_BASENAME" )

SIZE=$(du -h "$IPA_OUT" | cut -f1)
echo "==> wrote $IPA_OUT ($SIZE)"
echo "==> symlink $IPA_LATEST -> $IPA_BASENAME"

if [ "$SCHEME" = "CofiVPhone" ]; then
    ARM64_IPA_OUT="$PWD/build/${IPA_PREFIX}-arm64.ipa"
    ARM64_STAGE="$(mktemp -d -t external-ff-vphone-arm64)"
    trap 'rm -rf "$STAGE" "${ARM64_STAGE:-}"' EXIT
    mkdir -p "$ARM64_STAGE/Payload"
    ditto "$APP_PATH" "$ARM64_STAGE/Payload/Cofi.app"
    lipo "$ARM64_STAGE/Payload/Cofi.app/Cofi" -thin arm64 \
        -output "$ARM64_STAGE/Payload/Cofi.app/Cofi.arm64"
    mv "$ARM64_STAGE/Payload/Cofi.app/Cofi.arm64" \
        "$ARM64_STAGE/Payload/Cofi.app/Cofi"
    chmod +x "$ARM64_STAGE/Payload/Cofi.app/Cofi"
    ldid -S"$PWD/scripts/vphone_app.entitlements" \
        "$ARM64_STAGE/Payload/Cofi.app/Cofi"
    rm -f "$ARM64_IPA_OUT"
    ( cd "$ARM64_STAGE" && zip -qry "$ARM64_IPA_OUT" Payload )
    ARM64_SIZE=$(du -h "$ARM64_IPA_OUT" | cut -f1)
    echo "==> wrote $ARM64_IPA_OUT ($ARM64_SIZE)"
fi

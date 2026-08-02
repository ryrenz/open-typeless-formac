#!/usr/bin/env bash

set -euo pipefail

PROJECT_NAME="OpenTypeless"
SCHEME="OpenTypeless"
CONFIGURATION="Release"
DERIVED_DATA_PATH=""
OUTPUT_DIR=""
ARCH="native"
FORCE=false
ALLOW_UNSIGNED=false

usage() {
    cat <<'EOF'
Usage: scripts/build-dmg.sh [options]

Build a local test DMG in an isolated temporary staging directory. This
script does not notarize or upload anything. Use scripts/release-dmg.sh for
the public universal notarized release workflow.

Options:
  --configuration <Debug|Release>  Build configuration (default: Release)
  --derived-data <path>            DerivedData path (default: .build/DerivedData)
  --output-dir <path>              Artifact directory (default: dist/local)
  --arch <native|arm64|x86_64>     Local architecture (default: native)
  --force                          Replace an existing DMG/checksum pair
  --allow-unsigned                 Skip code signing (local testing only)
  -h, --help                       Show this help
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration)
            [[ $# -ge 2 ]] || fail "--configuration requires a value"
            CONFIGURATION="$2"
            shift 2
            ;;
        --derived-data)
            [[ $# -ge 2 ]] || fail "--derived-data requires a path"
            DERIVED_DATA_PATH="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || fail "--output-dir requires a path"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --arch)
            [[ $# -ge 2 ]] || fail "--arch requires native, arm64, or x86_64"
            ARCH="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --allow-unsigned)
            ALLOW_UNSIGNED=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

case "$CONFIGURATION" in
    Debug|Release) ;;
    *) fail "--configuration must be Debug or Release" ;;
esac

case "$ARCH" in
    native)
        case "$(uname -m)" in
            arm64|x86_64) ARCH="$(uname -m)" ;;
            *) fail "unsupported native architecture: $(uname -m)" ;;
        esac
        ;;
    arm64|x86_64) ;;
    *) fail "--arch must be native, arm64, or x86_64" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -d "$DEVELOPER_DIR" ]] || fail "Xcode developer directory not found: $DEVELOPER_DIR"
export DEVELOPER_DIR

for command_name in xcodegen xcodebuild hdiutil ditto codesign plutil shasum mktemp mv rm ln; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command not found: $command_name"
done

if [[ -z "$DERIVED_DATA_PATH" ]]; then
    DERIVED_DATA_PATH="$REPO_ROOT/.build/DerivedData"
elif [[ "$DERIVED_DATA_PATH" != /* ]]; then
    DERIVED_DATA_PATH="$REPO_ROOT/$DERIVED_DATA_PATH"
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$REPO_ROOT/dist/local"
elif [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$REPO_ROOT/$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

echo "Generating Xcode project..."
xcodegen generate

SETTINGS_OUTPUT="$(xcodebuild \
    -project "$PROJECT_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackageUpdates \
    -showBuildSettings)"
MARKETING_VERSION="$(printf '%s\n' "$SETTINGS_OUTPUT" \
    | awk -F' = ' '/^[[:space:]]*MARKETING_VERSION = / { print $2; exit }')"
BUILD_NUMBER="$(printf '%s\n' "$SETTINGS_OUTPUT" \
    | awk -F' = ' '/^[[:space:]]*CURRENT_PROJECT_VERSION = / { print $2; exit }')"
[[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
    || fail "invalid MARKETING_VERSION: $MARKETING_VERSION"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid CURRENT_PROJECT_VERSION: $BUILD_NUMBER"

DMG_NAME="$PROJECT_NAME-$MARKETING_VERSION.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
for artifact_path in "$DMG_PATH" "$CHECKSUM_PATH"; do
    if [[ -e "$artifact_path" || -L "$artifact_path" ]]; then
        [[ -f "$artifact_path" && ! -L "$artifact_path" ]] \
            || fail "artifact path must be a regular file: $artifact_path"
    fi
done
if [[ "$FORCE" == false && ( -e "$DMG_PATH" || -e "$CHECKSUM_PATH" ) ]]; then
    fail "artifact already exists; pass --force to replace: $DMG_PATH"
fi

LOCK_DIR="$OUTPUT_DIR/.OpenTypeless-$MARKETING_VERSION.lock"
mkdir "$LOCK_DIR" 2>/dev/null \
    || fail "another local DMG build is already publishing version $MARKETING_VERSION"
LOCK_ACQUIRED=true
TEMP_ROOT=""
PUBLISHED=false
CHECKSUM_MOVE_STARTED=false
DMG_MOVE_STARTED=false
PREVIOUS_DMG_MOVED=false
PREVIOUS_CHECKSUM_MOVED=false
PREVIOUS_DMG_PATH=""
PREVIOUS_CHECKSUM_PATH=""
cleanup() {
    if [[ "$PUBLISHED" == false ]]; then
        if [[ "$CHECKSUM_MOVE_STARTED" == true ]]; then
            rm -f -- "$CHECKSUM_PATH"
        fi
        if [[ "$PREVIOUS_DMG_MOVED" == true ]]; then
            rm -f -- "$DMG_PATH"
            mv -- "$PREVIOUS_DMG_PATH" "$DMG_PATH"
        fi
        if [[ "$PREVIOUS_CHECKSUM_MOVED" == true ]]; then
            rm -f -- "$CHECKSUM_PATH"
            mv -- "$PREVIOUS_CHECKSUM_PATH" "$CHECKSUM_PATH"
        fi
        if [[ "$DMG_MOVE_STARTED" == true && "$PREVIOUS_DMG_MOVED" == false ]]; then
            rm -f -- "$DMG_PATH"
        fi
    fi
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" \
        && "$(basename "$TEMP_ROOT")" == .OpenTypelessDMG.* ]]; then
        rm -rf -- "$TEMP_ROOT"
    fi
    if [[ "${LOCK_ACQUIRED:-false}" == true ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

BUILD_ARGUMENTS=(
    -project "$PROJECT_NAME.xcodeproj"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "platform=macOS"
    -derivedDataPath "$DERIVED_DATA_PATH"
    -disableAutomaticPackageResolution
    -onlyUsePackageVersionsFromResolvedFile
    -skipPackageUpdates
    build
    ARCHS="$ARCH"
    ONLY_ACTIVE_ARCH=NO
)
if [[ "$ALLOW_UNSIGNED" == true ]]; then
    BUILD_ARGUMENTS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
else
    BUILD_ARGUMENTS+=(CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development")
fi

echo "Building $PROJECT_NAME $MARKETING_VERSION ($BUILD_NUMBER, $ARCH)..."
xcodebuild "${BUILD_ARGUMENTS[@]}"

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$PROJECT_NAME.app"
[[ -d "$BUILT_APP" ]] || fail "built app not found: $BUILT_APP"
EXPECTED_BUNDLE_ID="com.scinttt.open-typeless"
ACTUAL_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$BUILT_APP/Contents/Info.plist")"
[[ "$ACTUAL_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] \
    || fail "unexpected bundle identifier: $ACTUAL_BUNDLE_ID"

if [[ "$ALLOW_UNSIGNED" == false ]]; then
    codesign --verify --deep --strict "$BUILT_APP" \
        || fail "built app signature validation failed"
fi

TEMP_ROOT="$(mktemp -d "$OUTPUT_DIR/.OpenTypelessDMG.XXXXXX")"
STAGE_PATH="$TEMP_ROOT/stage"
TEMP_DMG_PATH="$TEMP_ROOT/$DMG_NAME"
TEMP_CHECKSUM_PATH="$TEMP_ROOT/$DMG_NAME.sha256"
mkdir -p "$STAGE_PATH"

ditto --noqtn "$BUILT_APP" "$STAGE_PATH/$PROJECT_NAME.app"
ln -s /Applications "$STAGE_PATH/Applications"

echo "Creating isolated DMG staging area..."
hdiutil create \
    -volname "$PROJECT_NAME" \
    -srcfolder "$STAGE_PATH" \
    -ov \
    -format UDZO \
    "$TEMP_DMG_PATH"
hdiutil verify "$TEMP_DMG_PATH"

(
    cd "$TEMP_ROOT"
    shasum -a 256 "$DMG_NAME" > "$TEMP_CHECKSUM_PATH"
)

if [[ "$FORCE" == true ]]; then
    PREVIOUS_DMG_PATH="$TEMP_ROOT/.previous-$DMG_NAME"
    PREVIOUS_CHECKSUM_PATH="$TEMP_ROOT/.previous-$DMG_NAME.sha256"
    if [[ -e "$DMG_PATH" ]]; then
        mv -- "$DMG_PATH" "$PREVIOUS_DMG_PATH"
        PREVIOUS_DMG_MOVED=true
    fi
    if [[ -e "$CHECKSUM_PATH" ]]; then
        mv -- "$CHECKSUM_PATH" "$PREVIOUS_CHECKSUM_PATH"
        PREVIOUS_CHECKSUM_MOVED=true
    fi
fi

if [[ "$FORCE" == true ]]; then
    CHECKSUM_MOVE_STARTED=true
    mv -f -- "$TEMP_CHECKSUM_PATH" "$CHECKSUM_PATH"
else
    CHECKSUM_MOVE_STARTED=true
    mv -- "$TEMP_CHECKSUM_PATH" "$CHECKSUM_PATH"
fi
if [[ "$FORCE" == true ]]; then
    DMG_MOVE_STARTED=true
    mv -f -- "$TEMP_DMG_PATH" "$DMG_PATH"
else
    DMG_MOVE_STARTED=true
    mv -- "$TEMP_DMG_PATH" "$DMG_PATH"
fi
PUBLISHED=true

echo "Local DMG created:"
echo "  $DMG_PATH"
echo "  $CHECKSUM_PATH"
echo "This local DMG is not notarized. Use scripts/release-dmg.sh for public distribution."

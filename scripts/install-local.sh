#!/usr/bin/env bash

set -euo pipefail

PROJECT_NAME="OpenTypeless"
SCHEME="OpenTypeless"
INSTALL_PATH="/Applications/$PROJECT_NAME.app"
CONFIGURATION="Debug"
DERIVED_DATA_PATH=""
LAUNCH_AFTER_INSTALL=true
ALLOW_UNSIGNED=false
LOCK_DIR="/Applications/.OpenTypeless-install.lock"
LOCK_ACQUIRED=false
BACKUP_ROOT=""
BACKUP_APP=""
STAGED_APP=""
HAD_EXISTING_APP=false
REPLACEMENT_STARTED=false
INSTALL_SUCCEEDED=false

usage() {
    cat <<'EOF'
Usage: scripts/install-local.sh [options]

Build the app and replace the single canonical local installation at
/Applications/OpenTypeless.app. The old app is restored automatically if the
replacement or validation fails.

Options:
  --configuration <Debug|Release>  Build configuration (default: Debug)
  --derived-data <path>            DerivedData path (default: .build/DerivedData)
  --no-launch                      Install without launching the app
  --allow-unsigned                 Skip code signing (permissions may not persist)
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
        --no-launch)
            LAUNCH_AFTER_INSTALL=false
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -d "$DEVELOPER_DIR" ]] || fail "Xcode developer directory not found: $DEVELOPER_DIR"
export DEVELOPER_DIR

for command_name in xcodegen xcodebuild ditto codesign plutil open ps sed kill sleep mktemp mkdir mv rm; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command not found: $command_name"
done

[[ -d /Applications && -w /Applications ]] \
    || fail "the /Applications directory is not writable"

restore_previous_install() {
    if [[ "$REPLACEMENT_STARTED" == true ]]; then
        rm -rf -- "$INSTALL_PATH"
    fi
    if [[ "$HAD_EXISTING_APP" == true && -d "$BACKUP_APP" ]]; then
        mv -- "$BACKUP_APP" "$INSTALL_PATH"
    fi
}

release_lock() {
    if [[ "$LOCK_ACQUIRED" == true ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
        LOCK_ACQUIRED=false
    fi
}

cleanup() {
    local status=$?
    if [[ "$INSTALL_SUCCEEDED" == false ]]; then
        restore_previous_install
        if [[ "$HAD_EXISTING_APP" == true ]]; then
            echo "The previous installation was restored." >&2
        fi
    fi
    if [[ -n "$BACKUP_ROOT" ]]; then
        rm -rf -- "$BACKUP_ROOT"
    fi
    release_lock
    exit "$status"
}
trap cleanup EXIT

mkdir "$LOCK_DIR" 2>/dev/null \
    || fail "another OpenTypeless local install is already running"
LOCK_ACQUIRED=true

if [[ -z "$DERIVED_DATA_PATH" ]]; then
    DERIVED_DATA_PATH="$REPO_ROOT/.build/DerivedData"
elif [[ "$DERIVED_DATA_PATH" != /* ]]; then
    DERIVED_DATA_PATH="$REPO_ROOT/$DERIVED_DATA_PATH"
fi

echo "Generating Xcode project..."
xcodegen generate

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
)
if [[ "$ALLOW_UNSIGNED" == true ]]; then
    BUILD_ARGUMENTS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
else
    BUILD_ARGUMENTS+=(CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development")
fi

echo "Building $PROJECT_NAME ($CONFIGURATION)..."
xcodebuild "${BUILD_ARGUMENTS[@]}"

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$PROJECT_NAME.app"
[[ -d "$BUILT_APP" ]] || fail "built app not found: $BUILT_APP"
[[ -x "$BUILT_APP/Contents/MacOS/$PROJECT_NAME" ]] \
    || fail "built executable not found: $BUILT_APP/Contents/MacOS/$PROJECT_NAME"

EXPECTED_BUNDLE_ID="com.scinttt.open-typeless"
ACTUAL_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$BUILT_APP/Contents/Info.plist")"
[[ "$ACTUAL_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] \
    || fail "unexpected bundle identifier: $ACTUAL_BUNDLE_ID"

if [[ "$ALLOW_UNSIGNED" == false ]]; then
    codesign --verify --deep --strict "$BUILT_APP" \
        || fail "built app signature validation failed"
fi

EXECUTABLE_PATH="$INSTALL_PATH/Contents/MacOS/$PROJECT_NAME"
target_pids() {
    ps -axo pid=,comm= | awk -v expected="$EXECUTABLE_PATH" '
        {
            line = $0
            sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line)
            if (line == expected) print $1
        }
    '
}

process_path_for_pid() {
    ps -p "$1" -o comm= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

RUNNING_PIDS="$(target_pids || true)"
if [[ -n "$RUNNING_PIDS" ]]; then
    echo "Stopping the current /Applications installation..."
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        if [[ "$(process_path_for_pid "$pid")" == "$EXECUTABLE_PATH" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    done <<< "$RUNNING_PIDS"

    for _ in 1 2 3 4 5; do
        STILL_RUNNING=false
        while read -r pid; do
            [[ -n "$pid" ]] || continue
            if [[ "$(process_path_for_pid "$pid")" == "$EXECUTABLE_PATH" ]] \
                && kill -0 "$pid" 2>/dev/null; then
                STILL_RUNNING=true
            fi
        done <<< "$RUNNING_PIDS"
        [[ "$STILL_RUNNING" == false ]] && break
        sleep 1
    done

    while read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$(process_path_for_pid "$pid")" == "$EXECUTABLE_PATH" ]] \
            && kill -0 "$pid" 2>/dev/null \
            && fail "the current app did not exit cleanly (pid $pid)"
    done <<< "$RUNNING_PIDS"
fi

BACKUP_ROOT="$(mktemp -d "/Applications/.OpenTypelessInstall.XXXXXX")"
BACKUP_APP="$BACKUP_ROOT/$PROJECT_NAME.previous.app"
STAGED_APP="$BACKUP_ROOT/$PROJECT_NAME.new.app"

ditto --noqtn "$BUILT_APP" "$STAGED_APP"
if [[ "$ALLOW_UNSIGNED" == false ]]; then
    codesign --verify --deep --strict "$STAGED_APP" \
        || fail "staged app signature validation failed"
fi

if [[ -L "$INSTALL_PATH" ]]; then
    fail "install path is a symlink; remove it manually before installing: $INSTALL_PATH"
fi
if [[ -e "$INSTALL_PATH" && ! -d "$INSTALL_PATH" ]]; then
    fail "install path is not an app directory: $INSTALL_PATH"
fi

if [[ -d "$INSTALL_PATH" ]]; then
    mv -- "$INSTALL_PATH" "$BACKUP_APP"
    HAD_EXISTING_APP=true
fi

[[ ! -e "$INSTALL_PATH" && ! -L "$INSTALL_PATH" ]] \
    || fail "install path became occupied during replacement: $INSTALL_PATH"

echo "Installing one canonical copy at $INSTALL_PATH..."
REPLACEMENT_STARTED=true
mv -- "$STAGED_APP" "$INSTALL_PATH"

if [[ "$ALLOW_UNSIGNED" == false ]]; then
    codesign --verify --deep --strict "$INSTALL_PATH" \
        || fail "installed app signature validation failed"
fi

INSTALL_SUCCEEDED=true
rm -rf -- "$BACKUP_ROOT"
BACKUP_ROOT=""
release_lock
trap - EXIT

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INSTALL_PATH/Contents/Info.plist")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$INSTALL_PATH/Contents/Info.plist")"
echo "Installed $PROJECT_NAME $VERSION ($BUILD_NUMBER) at $INSTALL_PATH"

if [[ "$LAUNCH_AFTER_INSTALL" == true ]]; then
    open "$INSTALL_PATH"
    echo "Launched $INSTALL_PATH"
fi

#!/usr/bin/env bash

set -euo pipefail

PROJECT_NAME="OpenTypeless"
SCHEME="OpenTypeless"
NOTARY_PROFILE="OpenTypelessNotary"
VERSION=""
BUILD_NUMBER=""
TEAM_ID=""
TAG=""
PREFLIGHT_ONLY=false

usage() {
    echo "Usage: scripts/release-dmg.sh --version <version> --build <number> --team-id <team-id> --tag <tag> [options]"
    echo ""
    echo "Options:"
    echo "  --notary-profile <name>  Keychain profile (default: OpenTypelessNotary)"
    echo "  --tag <tag>              Required release tag (version or v-prefixed version)"
    echo "  --preflight-only         Validate release prerequisites without building"
    echo "  -h, --help               Show this help"
}

fail() {
    echo "error: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || fail "--version requires a value"
            VERSION="$2"
            shift 2
            ;;
        --build)
            [[ $# -ge 2 ]] || fail "--build requires a value"
            BUILD_NUMBER="$2"
            shift 2
            ;;
        --team-id)
            [[ $# -ge 2 ]] || fail "--team-id requires a value"
            TEAM_ID="$2"
            shift 2
            ;;
        --notary-profile)
            [[ $# -ge 2 ]] || fail "--notary-profile requires a value"
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --tag)
            [[ $# -ge 2 ]] || fail "--tag requires a value"
            TAG="$2"
            shift 2
            ;;
        --preflight-only)
            PREFLIGHT_ONLY=true
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

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
    || fail "--version must look like 1.0.0"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
    || fail "--build must be a positive integer"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
    || fail "--team-id must be a 10-character Apple team ID"
[[ -n "$TAG" ]] || fail "--tag is required for a release"
[[ "$TAG" == "$VERSION" || "$TAG" == "v$VERSION" ]] \
    || fail "--tag must match --version, optionally prefixed with v"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

for command_name in git xcodegen xcodebuild security hdiutil codesign spctl shasum xcrun ditto lipo plutil; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command not found: $command_name"
done

[[ -z "$(git status --porcelain)" ]] \
    || fail "working tree must be clean before creating a release"

TAG_COMMIT="$(git rev-list -n 1 "refs/tags/$TAG" 2>/dev/null)" \
    || fail "tag does not exist: $TAG"
HEAD_COMMIT="$(git rev-parse HEAD)"
[[ "$TAG_COMMIT" == "$HEAD_COMMIT" ]] \
    || fail "tag $TAG does not point to HEAD"

IDENTITIES="$(
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' -v team="($TEAM_ID)" \
            '/Developer ID Application:/ && index($2, team) { print $2 }'
)"
IDENTITY_COUNT="$(printf '%s\n' "$IDENTITIES" | awk 'NF { count++ } END { print count + 0 }')"
[[ "$IDENTITY_COUNT" -eq 1 ]] \
    || fail "expected exactly one Developer ID Application identity for team $TEAM_ID, found $IDENTITY_COUNT"
SIGNING_IDENTITY="$(printf '%s\n' "$IDENTITIES" | sed -n '1p')"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -d "$DEVELOPER_DIR" ]] || fail "Xcode developer directory not found: $DEVELOPER_DIR"
export DEVELOPER_DIR

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    || fail "notary credentials are unavailable in Keychain profile: $NOTARY_PROFILE"

if [[ "$PREFLIGHT_ONLY" == true ]]; then
    echo "Release preflight passed."
    echo "Signing identity: $SIGNING_IDENTITY"
    echo "Notary profile: $NOTARY_PROFILE"
    exit 0
fi

DIST_DIR="$REPO_ROOT/dist"
DMG_NAME="$PROJECT_NAME-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
mkdir -p "$DIST_DIR"
LOCK_DIR="$DIST_DIR/.OpenTypeless-$VERSION.lock"
mkdir "$LOCK_DIR" 2>/dev/null \
    || fail "another release process is already publishing version $VERSION"

TEMP_ROOT=""
PUBLISHED=false
CHECKSUM_PUBLISHED=false
cleanup() {
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" \
        && "$(basename "$TEMP_ROOT")" == .OpenTypelessRelease.* ]]; then
        rm -rf -- "$TEMP_ROOT"
    fi
    if [[ "$PUBLISHED" == false && "$CHECKSUM_PUBLISHED" == true ]]; then
        rm -f -- "$CHECKSUM_PATH"
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

TEMP_ROOT="$(mktemp -d "$DIST_DIR/.OpenTypelessRelease.XXXXXX")"
[[ ! -e "$DMG_PATH" && ! -e "$CHECKSUM_PATH" ]] \
    || fail "release artifact already exists: $DMG_PATH"

ARCHIVE_PATH="$TEMP_ROOT/$PROJECT_NAME.xcarchive"
EXPORT_PATH="$TEMP_ROOT/export"
STAGE_PATH="$TEMP_ROOT/stage"
TEMP_DMG_PATH="$TEMP_ROOT/$DMG_NAME"
TEMP_CHECKSUM_PATH="$TEMP_ROOT/$DMG_NAME.sha256"
mkdir -p "$EXPORT_PATH" "$STAGE_PATH"

xcodegen generate
git diff --quiet -- \
    OpenTypeless.xcodeproj \
    Sources/OpenTypeless/Info.plist \
    Sources/OpenTypeless/OpenTypeless.entitlements \
    || fail "xcodegen changed generated project files; commit them before releasing"

PRIVACY_MANIFEST="$REPO_ROOT/Resources/PrivacyInfo.xcprivacy"
PRIVACY_POLICY="$REPO_ROOT/PRIVACY.md"
APP_ENTITLEMENTS_SOURCE="$REPO_ROOT/Sources/OpenTypeless/OpenTypeless.entitlements"
[[ -s "$PRIVACY_POLICY" ]] || fail "bundled privacy policy is missing or empty"
plutil -lint "$PRIVACY_MANIFEST" >/dev/null
plutil -lint "$APP_ENTITLEMENTS_SOURCE" >/dev/null
[[ "$(plutil -extract NSPrivacyTracking raw -o - "$PRIVACY_MANIFEST")" == "false" ]] \
    || fail "privacy manifest must declare tracking disabled"
[[ "$(plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType raw -o - "$PRIVACY_MANIFEST")" \
    == "NSPrivacyAccessedAPICategoryUserDefaults" ]] \
    || fail "privacy manifest is missing the UserDefaults reason declaration"
[[ "$(plutil -extract NSPrivacyAccessedAPITypes.1.NSPrivacyAccessedAPIType raw -o - "$PRIVACY_MANIFEST")" \
    == "NSPrivacyAccessedAPICategoryFileTimestamp" ]] \
    || fail "privacy manifest is missing the file timestamp reason declaration"
[[ "$(plutil -extract keychain-access-groups.0 raw -o - "$APP_ENTITLEMENTS_SOURCE")" \
    == "\$(AppIdentifierPrefix)com.scinttt.open-typeless" ]] \
    || fail "app entitlements are missing the stable API key access group"

xcodebuild test \
    -project "$PROJECT_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -destination "platform=macOS" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$TEAM_ID"

xcodebuild archive \
    -project "$PROJECT_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$TEAM_ID"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$REPO_ROOT/Config/ExportOptions-DeveloperID.plist" \
    -allowProvisioningUpdates

APP_PATH="$EXPORT_PATH/$PROJECT_NAME.app"
[[ -d "$APP_PATH" ]] || fail "exported app not found: $APP_PATH"
[[ -s "$APP_PATH/Contents/Resources/PRIVACY.md" ]] \
    || fail "exported app is missing the bundled privacy policy"
[[ -f "$APP_PATH/Contents/embedded.provisionprofile" ]] \
    || fail "exported app is missing the Developer ID provisioning profile required by Keychain access groups"

APP_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/$PROJECT_NAME")"
[[ "$APP_ARCHS" == *"arm64"* && "$APP_ARCHS" == *"x86_64"* ]] \
    || fail "exported app is not universal: $APP_ARCHS"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
EXPORTED_ENTITLEMENTS="$TEMP_ROOT/exported-entitlements.plist"
codesign -d --entitlements :- "$APP_PATH" > "$EXPORTED_ENTITLEMENTS" 2>/dev/null
plutil -lint "$EXPORTED_ENTITLEMENTS" >/dev/null
[[ "$(plutil -extract keychain-access-groups.0 raw -o - "$EXPORTED_ENTITLEMENTS")" \
    == "$TEAM_ID.com.scinttt.open-typeless" ]] \
    || fail "exported app has an unexpected API key access group"
ditto "$APP_PATH" "$STAGE_PATH/$PROJECT_NAME.app"
ln -s /Applications "$STAGE_PATH/Applications"

hdiutil create \
    -volname "$PROJECT_NAME" \
    -srcfolder "$STAGE_PATH" \
    -ov \
    -format UDZO \
    "$TEMP_DMG_PATH"

codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$TEMP_DMG_PATH"
hdiutil verify "$TEMP_DMG_PATH"
xcrun notarytool submit \
    "$TEMP_DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$TEMP_DMG_PATH"
xcrun stapler validate "$TEMP_DMG_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --verbose=2 "$TEMP_DMG_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$TEMP_DMG_PATH"

(
    cd "$TEMP_ROOT"
    shasum -a 256 "$DMG_NAME" > "$TEMP_CHECKSUM_PATH"
)

mv "$TEMP_CHECKSUM_PATH" "$CHECKSUM_PATH"
CHECKSUM_PUBLISHED=true
mv "$TEMP_DMG_PATH" "$DMG_PATH"
PUBLISHED=true

echo "Release artifact created:"
echo "  $DMG_PATH"
echo "  $CHECKSUM_PATH"

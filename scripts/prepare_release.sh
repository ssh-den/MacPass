#!/bin/bash
# Stop at the first failed build or signing step instead of notarizing its result.
set -eo pipefail

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -s|--sign)
    IDENTITY="$2"
    shift # past argument
    shift # past value
    ;;
    -t|--teamid)
    TEAMID="$2"
    shift # past argument
    shift # past value
    ;;
    -k|--keychain-profile)
    NOTARY_PROFILE="$2"
    shift # past argument
    shift # past value
    ;;
    -e|--entitlements)
    ENTITLEMENTS="$2"
    shift # past argument
    shift # past value
    ;;
    --extension-entitlements)
    EXTENSION_ENTITLEMENTS="$2"
    shift # past argument
    shift # past value
    ;;
    --app-profile)
    APP_PROFILE="$2"
    shift # past argument
    shift # past value
    ;;
    --extension-profile)
    EXTENSION_PROFILE="$2"
    shift # past argument
    shift # past value
    ;;
    --bundle-id)
    BUNDLE_ID="$2"
    shift # past argument
    shift # past value
    ;;
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
esac
done

set -- "${POSITIONAL[@]}" # restore positional parameters

if [[ -z "${IDENTITY}" ]]; then
    echo "Missing identity"
    exit -1
fi
if [[ -z "${ENTITLEMENTS}" ]]; then
    echo "Missing entitlements"
    exit -1
fi
# Credentials stay in the keychain instead of the process list and shell history:
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
if [[ -z "${NOTARY_PROFILE}" ]]; then
    echo "Missing notarization keychain profile"
    exit -1
fi
if [[ -z "${TEAMID}" ]]; then
    echo "Missing team id"
    exit -1
fi
# The AutoFill entitlements are restricted: the app and its extension each need
# a Developer ID provisioning profile that grants them, or macOS refuses to launch.
if [[ -z "${EXTENSION_ENTITLEMENTS}" ]]; then
    echo "Missing extension entitlements"
    exit -1
fi
if [[ ! -f "${APP_PROFILE}" || ! -f "${EXTENSION_PROFILE}" ]]; then
    echo "Missing app or extension provisioning profile"
    exit -1
fi
# The profiles name the App IDs: the app's identifier and <identifier>.AutoFill.
# A team can only register its own identifiers, so a fork passes its own.
BUNDLE_ID="${BUNDLE_ID:-com.hicknhacksoftware.MacPass}"

ENTITLEMENTS_FOLDER="$(mktemp -d)"
trap 'rm -rf "${ENTITLEMENTS_FOLDER}"' EXIT

# A mismatched profile still signs and notarizes, but macOS refuses to launch the result.
check_profile() {
    local decoded="${ENTITLEMENTS_FOLDER}/profile.plist"
    local identifier
    if ! security cms -D -i "$1" > "${decoded}" 2>/dev/null; then
        echo "Cannot read provisioning profile $1"
        exit -1
    fi
    identifier="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "${decoded}" 2>/dev/null || true)"
    if [[ "${identifier}" != "${TEAMID}.$2" ]]; then
        echo "Provisioning profile $1 is for '${identifier}', expected '${TEAMID}.$2'"
        exit -1
    fi
}
check_profile "${APP_PROFILE}" "${BUNDLE_ID}"
check_profile "${EXTENSION_PROFILE}" "${BUNDLE_ID}.AutoFill"
# Entitlement files use build settings that only Xcode expands: the App Group
# names $(DEVELOPMENT_TEAM), the keychain group the App ID. Expand them here;
# an unexpanded restricted entitlement does not match the profile.
expand_entitlements() {
    sed -e "s/\$(DEVELOPMENT_TEAM)/${TEAMID}/g" -e "s/\$(AppIdentifierPrefix)/${TEAMID}./g" \
        -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$2/g" "$1" > "$3"
    if grep -q '\$(' "$3"; then
        echo "Unexpanded build setting in $1"
        exit -1
    fi
}
APP_ENTITLEMENTS="${ENTITLEMENTS_FOLDER}/MacPass.entitlements"
APPEX_ENTITLEMENTS="${ENTITLEMENTS_FOLDER}/MacPassAutoFill.entitlements"
expand_entitlements "${ENTITLEMENTS}" "${BUNDLE_ID}" "${APP_ENTITLEMENTS}"
expand_entitlements "${EXTENSION_ENTITLEMENTS}" "${BUNDLE_ID}.AutoFill" "${APPEX_ENTITLEMENTS}"
APP_PROFILE="$(cd "$(dirname "${APP_PROFILE}")" && pwd)/$(basename "${APP_PROFILE}")"
EXTENSION_PROFILE="$(cd "$(dirname "${EXTENSION_PROFILE}")" && pwd)/$(basename "${EXTENSION_PROFILE}")"

# Works from any directory; argument paths above are relative to the caller's.
REPO_FOLDER="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_FOLDER="${REPO_FOLDER}"/build/release
BUILD_FOLDER="${DERIVED_DATA_FOLDER}"/Build/Products/Release
APP_BUNDLE=MacPass.app
APP_BUNDLE_ZIP="${APP_BUNDLE}".zip
APP_FRAMEWORK_PATH="${APP_BUNDLE}"/Contents/Frameworks
SPARKLE_FRAMEWORK="${APP_FRAMEWORK_PATH}"/Sparkle.framework
SPARKLE_VERSION="${SPARKLE_FRAMEWORK}"/Versions/B
TRANSFORMERKIT_FRAMEWORK="${APP_FRAMEWORK_PATH}"/TransformerKit.framework
KEEPASSKIT_FRAMEWORK="${APP_FRAMEWORK_PATH}"/KeePassKit.framework
KISSXML_FRAMEWORK="${APP_FRAMEWORK_PATH}"/KissXML.framework
HNHUI_FRAMEWORK="${APP_FRAMEWORK_PATH}"/HNHUi.framework
APPEX_BUNDLE="${APP_BUNDLE}"/Contents/PlugIns/MacPassAutoFill.appex
cd "${REPO_FOLDER}"
echo "Building..."
# Use the signing team and identifier for Info.plist expansion as well as the entitlements.
# Everything is signed below, so Xcode must not look for development profiles.
xcodebuild build -configuration Release -project MacPass.xcodeproj -scheme MacPass DEVELOPMENT_TEAM="${TEAMID}" MACPASS_APP_BUNDLE_IDENTIFIER="${BUNDLE_ID}" CODE_SIGNING_ALLOWED=NO -derivedDataPath "${DERIVED_DATA_FOLDER}"
cd "${BUILD_FOLDER}"
echo ""
# Sparkle 2 helpers, innermost first, as Sparkle documents: they keep their own
# entitlements (the Downloader's sandbox) and take none of MacPass's.
echo "Signing Sparkle - XPC services..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force "${SPARKLE_VERSION}"/XPCServices/Installer.xpc
codesign --sign "${IDENTITY}" --options runtime --timestamp --force --preserve-metadata=entitlements "${SPARKLE_VERSION}"/XPCServices/Downloader.xpc
echo "Signing Sparkle - Autoupdate and Updater..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force "${SPARKLE_VERSION}"/Autoupdate
codesign --sign "${IDENTITY}" --options runtime --timestamp --force "${SPARKLE_VERSION}"/Updater.app
echo "Signing Sparkle..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force "${SPARKLE_FRAMEWORK}"
echo "Signing TransformerKit..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force "${TRANSFORMERKIT_FRAMEWORK}"
echo "Signing HNHUi..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force "${HNHUI_FRAMEWORK}"
echo "Signing KeePassKit - KissXML..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force "${KISSXML_FRAMEWORK}"
echo "Signing KeePassKit..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force "${KEEPASSKIT_FRAMEWORK}"
echo "Embedding provisioning profiles..."
cp "${APP_PROFILE}" "${APP_BUNDLE}"/Contents/embedded.provisionprofile
cp "${EXTENSION_PROFILE}" "${APPEX_BUNDLE}"/Contents/embedded.provisionprofile
echo "Signing AutoFill extension..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force --entitlements "${APPEX_ENTITLEMENTS}" "${APPEX_BUNDLE}"
echo "Signing MacPass..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force --entitlements "${APP_ENTITLEMENTS}" "${APP_BUNDLE}"
echo ""
echo "Archiving for notarization..."
ditto -c -k --keepParent "${APP_BUNDLE}" "${APP_BUNDLE_ZIP}"
echo "Requesting Notarization..."
xcrun notarytool submit "${APP_BUNDLE_ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait
# Stapling fails unless notarization was accepted. The ticket lets Gatekeeper
# verify the app offline; the first archive predates it, so archive again.
echo "Stapling..."
xcrun stapler staple "${APP_BUNDLE}"
echo "Archiving..."
rm -f "${APP_BUNDLE_ZIP}"
ditto -c -k --keepParent "${APP_BUNDLE}" "${APP_BUNDLE_ZIP}"
echo "Release archive: ${BUILD_FOLDER}/${APP_BUNDLE_ZIP}"

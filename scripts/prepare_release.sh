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
    -a|--appleid)
    APPLEID="$2"
    shift # past argument
    shift # past value
    ;;
    -t|--teamid)
    TEAMID="$2"
    shift # past argument
    shift # past value
    ;;
    -p|--password)
    PASSWORD="$2"
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
if [[ -z "${APPLEID}" ]]; then
    echo "Missing Apple id"
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

# Entitlement files name the App Group with $(DEVELOPMENT_TEAM), which only
# Xcode expands. Nested helpers such as Sparkle's Autoupdate.app have no profile
# and must not carry the restricted AutoFill entitlements.
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
APP_ENTITLEMENTS="${ENTITLEMENTS_FOLDER}/MacPass.entitlements"
NESTED_ENTITLEMENTS="${ENTITLEMENTS_FOLDER}/Nested.entitlements"
APPEX_ENTITLEMENTS="${ENTITLEMENTS_FOLDER}/MacPassAutoFill.entitlements"
sed "s/\$(DEVELOPMENT_TEAM)/${TEAMID}/g" "${ENTITLEMENTS}" > "${APP_ENTITLEMENTS}"
sed "s/\$(DEVELOPMENT_TEAM)/${TEAMID}/g" "${EXTENSION_ENTITLEMENTS}" > "${APPEX_ENTITLEMENTS}"
cp "${APP_ENTITLEMENTS}" "${NESTED_ENTITLEMENTS}"
/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.authentication-services.autofill-credential-provider" "${NESTED_ENTITLEMENTS}"
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups" "${NESTED_ENTITLEMENTS}"
APP_PROFILE="$(cd "$(dirname "${APP_PROFILE}")" && pwd)/$(basename "${APP_PROFILE}")"
EXTENSION_PROFILE="$(cd "$(dirname "${EXTENSION_PROFILE}")" && pwd)/$(basename "${EXTENSION_PROFILE}")"
if [[ -z "${PASSWORD}" ]]; then
    echo "Missing password"
    exit -1
fi

DERIVED_DATA_FOLDER="${TMPDIR}"
BUILD_FOLDER="${DERIVED_DATA_FOLDER}"/Build/Products/Release
APP_BUNDLE=MacPass.app
APP_BUNDLE_ZIP="${APP_BUNDLE}".zip
APP_FRAMEWORK_PATH="${APP_BUNDLE}"/Contents/Frameworks
SPARKLE_FRAMEWORK="${APP_FRAMEWORK_PATH}"/Sparkle.framework
SPARKLE_AUTOUPDATE_BUNDLE="${SPARKLE_FRAMEWORK}"/Resources/Autoupdate.app
SPARKLE_FILEOP="${SPARKLE_AUTOUPDATE_BUNDLE}"/Contents/MacOS/fileop
TRANSFORMERKIT_FRAMEWORK="${APP_FRAMEWORK_PATH}"/TransformerKit.framework
KEEPASSKIT_FRAMEWORK="${APP_FRAMEWORK_PATH}"/KeePassKit.framework
KISSXML_FRAMEWORK="${APP_FRAMEWORK_PATH}"/KissXML.framework
HNHUI_FRAMEWORK="${APP_FRAMEWORK_PATH}"/HNHUi.framework
APPEX_BUNDLE="${APP_BUNDLE}"/Contents/PlugIns/MacPassAutoFill.appex
cd ..
echo "Building..."
# Use the signing team and identifier for Info.plist expansion as well as the entitlements.
# Everything is signed below, so Xcode must not look for development profiles.
xcodebuild build -configuration Release -project MacPass.xcodeproj -scheme MacPass DEVELOPMENT_TEAM="${TEAMID}" MACPASS_APP_BUNDLE_IDENTIFIER="${BUNDLE_ID}" CODE_SIGNING_ALLOWED=NO -derivedDataPath "${DERIVED_DATA_FOLDER}"
cd "${BUILD_FOLDER}"
echo ""
echo "Signing Sparkle - fileop..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force --entitlements "${NESTED_ENTITLEMENTS}" "${SPARKLE_FILEOP}"
echo "Signing Sparkle - Autoupdate..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force --entitlements "${NESTED_ENTITLEMENTS}" "${SPARKLE_AUTOUPDATE_BUNDLE}"
echo "Signing Sparkle..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force --entitlements "${NESTED_ENTITLEMENTS}" "${SPARKLE_FRAMEWORK}"
echo "Signing TransformerKit..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force --entitlements "${NESTED_ENTITLEMENTS}" "${TRANSFORMERKIT_FRAMEWORK}"
echo "Signing HNHUi..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force --entitlements "${NESTED_ENTITLEMENTS}" "${HNHUI_FRAMEWORK}"
echo "Signing KeePassKit - KissXML..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force --entitlements "${NESTED_ENTITLEMENTS}" "${KISSXML_FRAMEWORK}"
echo "Signing KeePassKit..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force --entitlements "${NESTED_ENTITLEMENTS}" "${KEEPASSKIT_FRAMEWORK}"
echo "Embedding provisioning profiles..."
cp "${APP_PROFILE}" "${APP_BUNDLE}"/Contents/embedded.provisionprofile
cp "${EXTENSION_PROFILE}" "${APPEX_BUNDLE}"/Contents/embedded.provisionprofile
echo "Signing AutoFill extension..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force --entitlements "${APPEX_ENTITLEMENTS}" "${APPEX_BUNDLE}"
echo "Signing MacPass..."
codesign --sign "${IDENTITY}" --options runtime --timestamp --force --entitlements "${APP_ENTITLEMENTS}" "${APP_BUNDLE}"
echo ""
echo "Archiving..."
ditto -c -k --keepParent "${APP_BUNDLE}" "${APP_BUNDLE_ZIP}"
echo "Requesting Notarization..."
xcrun notarytool submit "${APP_BUNDLE_ZIP}" --apple-id "${APPLEID}" --team-id "${TEAMID}" --password "${PASSWORD}" --wait
#xcrun stapler staple "${APP_BUNDLE}"
#xmllint --xpath "/plist/dict/key[contains(text(),'success-message')]::following-sibling" status.xml

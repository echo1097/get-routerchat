#!/bin/sh
set -eu

updaterVersion="1.0.0"
appRepo="echo1097/routerchat"
releaseApiUrl="https://api.github.com/repos/$appRepo/releases/latest"
appZipUrl="https://github.com/$appRepo/releases/latest/download/routerchat-app.zip"
appChecksumUrl="https://github.com/$appRepo/releases/latest/download/routerchat-app.zip.sha256"
installerUrl="https://echo1097.github.io/get-routerchat/install.sh"

installRoot="${ROUTERCHAT_INSTALL_ROOT:-}"
workDir=""
lockDir=""

fail() {
    printf 'RouterChat update failed: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    if [ -n "$workDir" ] && [ -d "$workDir" ]; then
        rm -rf "$workDir"
    fi
    if [ -n "$lockDir" ] && [ -d "$lockDir" ]; then
        rm -f "$lockDir/owner.pid"
        rmdir "$lockDir" 2>/dev/null || true
    fi
}

acquireUpdateLock() {
    lockDir="$installRoot/update.lock"

    if mkdir "$lockDir" 2>/dev/null; then
        printf '%s\n' "$$" >"$lockDir/owner.pid"
        return 0
    fi

    lockOwner=""
    if [ -f "$lockDir/owner.pid" ]; then
        lockOwner="$(head -n 1 "$lockDir/owner.pid" | tr -dc '0-9')"
    fi

    if [ -n "$lockOwner" ] && kill -0 "$lockOwner" 2>/dev/null; then
        fail "another RouterChat update is already running"
    fi

    rm -f "$lockDir/owner.pid" 2>/dev/null || true
    rmdir "$lockDir" 2>/dev/null || fail "the stale update lock could not be cleared; rerun the one-click installer"
    mkdir "$lockDir" 2>/dev/null || fail "another RouterChat update is already running"
    printf '%s\n' "$$" >"$lockDir/owner.pid"
}

download() {
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --retry-delay 2 -o "$2" "$1" \
        || fail "could not download $1"
}

jsonString() {
    fieldName="$1"
    filePath="$2"
    sed -n 's/.*"'"$fieldName"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$filePath" | head -n 1
}

normalizeVersion() {
    printf '%s' "$1" | sed 's/^v//'
}

versionParts() {
    normalizedValue="$(normalizeVersion "$1")"
    case "$normalizedValue" in
        *[!0-9.]* | .* | *. | *..*) return 1 ;;
    esac

    oldIfs="$IFS"
    IFS=.
    set -- $normalizedValue
    IFS="$oldIfs"
    [ "$#" -eq 3 ] || return 1
    printf '%s %s %s\n' "$1" "$2" "$3"
}

versionAtLeast() {
    currentParts="$(versionParts "$1")" || return 1
    minimumParts="$(versionParts "$2")" || return 1

    set -- $currentParts
    currentMajor="$1"
    currentMinor="$2"
    currentPatch="$3"

    set -- $minimumParts
    minimumMajor="$1"
    minimumMinor="$2"
    minimumPatch="$3"

    [ "$currentMajor" -gt "$minimumMajor" ] && return 0
    [ "$currentMajor" -lt "$minimumMajor" ] && return 1
    [ "$currentMinor" -gt "$minimumMinor" ] && return 0
    [ "$currentMinor" -lt "$minimumMinor" ] && return 1
    [ "$currentPatch" -ge "$minimumPatch" ]
}

verifyChecksum() {
    expectedSum="$(awk '{print $1; exit}' "$2")"
    actualSum="$(shasum -a 256 "$1" | awk '{print $1}')"

    case "$expectedSum" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*) ;;
        *) fail "the published application checksum could not be read" ;;
    esac

    [ "${#expectedSum}" -eq 64 ] || fail "the published application checksum is invalid"
    [ "$expectedSum" = "$actualSum" ] || fail "the application package did not match its published checksum"
}

checkInstallRoot() {
    [ -n "$installRoot" ] || fail "the installation location was not provided"
    [ "$installRoot" != "/" ] && [ "$installRoot" != "$HOME" ] || fail "the installation location is unsafe"

    expectedRoot="$HOME/Library/Application Support/RouterChat"
    [ "$installRoot" = "$expectedRoot" ] || fail "the installation location is not a supported RouterChat installation"
}

readInstalledMetadata() {
    metadataPath="$installRoot/install.json"
    versionPath="$installRoot/app/version.json"

    [ -f "$metadataPath" ] || fail "install.json is missing; rerun the one-click installer to repair RouterChat"
    [ -f "$versionPath" ] || fail "app/version.json is missing; rerun the one-click installer to repair RouterChat"

    schemaVersion="$(sed -n 's/.*"schemaVersion"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$metadataPath" | head -n 1)"
    [ "$schemaVersion" = "1" ] || fail "this installation metadata version is not supported; rerun the one-click installer"

    installedVersion="$(jsonString version "$versionPath")"
    metadataVersion="$(jsonString installedVersion "$metadataPath")"
    [ -n "$installedVersion" ] && [ -n "$metadataVersion" ] || fail "the installed version could not be read"
    [ "$(normalizeVersion "$installedVersion")" = "$(normalizeVersion "$metadataVersion")" ] \
        || fail "installed version metadata does not match; rerun the one-click installer to repair RouterChat"
    versionParts "$installedVersion" >/dev/null || fail "the installed version is invalid"
}

readLatestRelease() {
    download "$releaseApiUrl" "$workDir/release.json"
    latestTag="$(jsonString tag_name "$workDir/release.json")"
    latestVersion="$(normalizeVersion "$latestTag")"
    versionParts "$latestVersion" >/dev/null || fail "the latest stable release has an invalid version"
}

validateLatestPackage() {
    download "$appZipUrl" "$workDir/routerchat-app.zip"
    download "$appChecksumUrl" "$workDir/routerchat-app.zip.sha256"
    verifyChecksum "$workDir/routerchat-app.zip" "$workDir/routerchat-app.zip.sha256"
    validatedAppSum="$(shasum -a 256 "$workDir/routerchat-app.zip" | awk '{print $1}')"

    mkdir -p "$workDir/app"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$workDir/routerchat-app.zip" -d "$workDir/app" || fail "the application package could not be extracted"
    else
        ditto -x -k "$workDir/routerchat-app.zip" "$workDir/app" || fail "the application package could not be extracted"
    fi

    for requiredPath in backend/main.py dist/index.html requirements.lock version.json TOS.md LICENSE; do
        [ -f "$workDir/app/$requiredPath" ] || fail "the application package is missing $requiredPath"
    done

    packageVersion="$(jsonString version "$workDir/app/version.json")"
    releaseTag="$(jsonString releaseTag "$workDir/app/version.json")"
    minimumUpdaterVersion="$(jsonString minimumUpdaterVersion "$workDir/app/version.json")"

    [ "$(normalizeVersion "$packageVersion")" = "$latestVersion" ] || fail "the package version does not match the latest stable release"
    [ "$(normalizeVersion "$releaseTag")" = "$latestVersion" ] || fail "the package release tag does not match the latest stable release"
    versionParts "$minimumUpdaterVersion" >/dev/null || fail "the package has an invalid minimum updater version"

    if ! versionAtLeast "$updaterVersion" "$minimumUpdaterVersion"; then
        fail "RouterChat $latestVersion requires a newer updater; rerun the one-click installer"
    fi
}

main() {
    command -v curl >/dev/null 2>&1 || fail "curl is required"
    command -v shasum >/dev/null 2>&1 || fail "shasum is required"

    checkInstallRoot

    acquireUpdateLock
    trap cleanup EXIT INT TERM HUP

    workDir="$(mktemp -d "${TMPDIR:-/tmp}/routerchat-update.XXXXXX")"
    chmod 700 "$workDir"

    readInstalledMetadata
    readLatestRelease

    if [ "$(normalizeVersion "$installedVersion")" = "$latestVersion" ]; then
        printf 'RouterChat %s is already the latest version.\n' "$installedVersion"
        exit 0
    fi

    if versionAtLeast "$installedVersion" "$latestVersion"; then
        printf 'RouterChat %s is newer than the latest stable release, so no update was installed.\n' "$installedVersion"
        exit 0
    fi

    printf 'Updating RouterChat from %s to %s.\n' "$installedVersion" "$latestVersion"
    validateLatestPackage

    ROUTERCHAT_EXPECTED_VERSION="$latestVersion"
    ROUTERCHAT_EXPECTED_APP_SHA256="$validatedAppSum"
    export ROUTERCHAT_EXPECTED_VERSION ROUTERCHAT_EXPECTED_APP_SHA256

    download "$installerUrl" "$workDir/install.sh"

    if sh "$workDir/install.sh"; then
        printf 'RouterChat was updated to %s.\n' "$latestVersion"
        exit 0
    fi

    fail "the installer could not complete the update; the rollback process was attempted"
}

main

#!/bin/sh
set -eu

repoDir="$(cd "$(dirname "$0")/.." && pwd)"
testRoot="$(mktemp -d "${TMPDIR:-/tmp}/routerchat-updater-test.XXXXXX")"

cleanup() {
    rm -rf "$testRoot"
}
trap cleanup EXIT INT TERM HUP

fail() {
    printf 'update test failed: %s\n' "$1" >&2
    exit 1
}

fixtureDir="$testRoot/fixtures"
fakeBin="$testRoot/bin"
testHome="$testRoot/home"
installRoot="$testHome/Library/Application Support/RouterChat"
mkdir -p "$fixtureDir/app/backend" "$fixtureDir/app/dist" "$fakeBin" "$installRoot/app"

for requiredPath in backend/main.py dist/index.html requirements.lock TOS.md LICENSE; do
    mkdir -p "$fixtureDir/app/$(dirname "$requiredPath")"
    : >"$fixtureDir/app/$requiredPath"
done

cat >"$fakeBin/curl" <<'FAKE_CURL'
#!/bin/sh
set -eu

destination=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            destination="$2"
            shift 2
            ;;
        -* )
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

case "$url" in
    */releases/latest) sourcePath="$TEST_RELEASE_JSON" ;;
    */routerchat-app.zip) sourcePath="$TEST_APP_ZIP" ;;
    */routerchat-app.zip.sha256) sourcePath="$TEST_APP_CHECKSUM" ;;
    */install.sh) sourcePath="$TEST_INSTALLER" ;;
    *) exit 22 ;;
esac

if [ -n "$destination" ]; then
    cp "$sourcePath" "$destination"
else
    sed -n '1,$p' "$sourcePath"
fi
FAKE_CURL
chmod 755 "$fakeBin/curl"

writeInstalledVersion() {
    versionValue="$1"
    mkdir -p "$installRoot/app"
    cat >"$installRoot/app/version.json" <<EOF
{"version":"$versionValue","releaseTag":"$versionValue","minimumUpdaterVersion":"1.0.0"}
EOF
    cat >"$installRoot/install.json" <<EOF
{"schemaVersion":1,"installedVersion":"$versionValue"}
EOF
}

buildPackage() {
    versionValue="$1"
    minimumValue="$2"
    cat >"$fixtureDir/app/version.json" <<EOF
{"version":"$versionValue","releaseTag":"$versionValue","minimumUpdaterVersion":"$minimumValue"}
EOF
    (
        cd "$fixtureDir/app"
        zip -q -r "$fixtureDir/routerchat-app.zip" .
    )
    shasum -a 256 "$fixtureDir/routerchat-app.zip" >"$fixtureDir/routerchat-app.zip.sha256"
}

cat >"$fixtureDir/installer.sh" <<'INSTALLER'
#!/bin/sh
set -eu
[ "$ROUTERCHAT_EXPECTED_VERSION" = "$TEST_EXPECTED_VERSION" ]
[ "$ROUTERCHAT_EXPECTED_APP_SHA256" = "$TEST_EXPECTED_SUM" ]
: >"$TEST_INSTALLER_CALLED"
INSTALLER

export HOME="$testHome"
export PATH="$fakeBin:/usr/bin:/bin:/usr/sbin:/sbin"
export ROUTERCHAT_INSTALL_ROOT="$installRoot"
export TEST_RELEASE_JSON="$fixtureDir/release.json"
export TEST_APP_ZIP="$fixtureDir/routerchat-app.zip"
export TEST_APP_CHECKSUM="$fixtureDir/routerchat-app.zip.sha256"
export TEST_INSTALLER="$fixtureDir/installer.sh"
export TEST_INSTALLER_CALLED="$fixtureDir/installer-called"

writeInstalledVersion "1.0.0"
printf '%s\n' '{"tag_name":"v1.0.0"}' >"$TEST_RELEASE_JSON"
output="$(sh "$repoDir/updater/update.sh")"
printf '%s' "$output" | grep -q 'already the latest version' || fail "current-version message was missing"
[ ! -e "$installRoot/update.lock" ] || fail "the update lock was not cleaned up"

mkdir "$installRoot/update.lock"
printf '%s\n' '999999' >"$installRoot/update.lock/owner.pid"
sh "$repoDir/updater/update.sh" >/dev/null
[ ! -e "$installRoot/update.lock" ] || fail "a stale update lock was not recovered"

mkdir "$installRoot/update.lock"
printf '%s\n' "$$" >"$installRoot/update.lock/owner.pid"
if sh "$repoDir/updater/update.sh" >/dev/null 2>&1; then
    fail "a live update lock was ignored"
fi
[ -e "$installRoot/update.lock" ] || fail "another process update lock was removed"
rm -rf "$installRoot/update.lock"

buildPackage "1.0.1" "1.0.0"
printf '%s\n' '{"tag_name":"v1.0.1"}' >"$TEST_RELEASE_JSON"
export TEST_EXPECTED_VERSION="1.0.1"
export TEST_EXPECTED_SUM="$(shasum -a 256 "$TEST_APP_ZIP" | awk '{print $1}')"
sh "$repoDir/updater/update.sh" >/dev/null
[ -f "$TEST_INSTALLER_CALLED" ] || fail "the verified installer was not invoked"

rm -f "$TEST_INSTALLER_CALLED"
workingInstaller="$TEST_INSTALLER"
export TEST_INSTALLER="$fixtureDir/missing-installer.sh"
if sh "$repoDir/updater/update.sh" >/dev/null 2>&1; then
    fail "a failed installer download reported a successful update"
fi
[ ! -e "$installRoot/update.lock" ] || fail "the update lock survived a failed installer download"
export TEST_INSTALLER="$workingInstaller"

rm -f "$TEST_APP_ZIP"
buildPackage "1.0.1" "2.0.0"
if sh "$repoDir/updater/update.sh" >/dev/null 2>&1; then
    fail "an unsupported minimum updater version was accepted"
fi
[ ! -e "$TEST_INSTALLER_CALLED" ] || fail "the installer ran with an unsupported updater"

printf '%s\n' '{"schemaVersion":2,"installedVersion":"1.0.0"}' >"$installRoot/install.json"
if sh "$repoDir/updater/update.sh" >/dev/null 2>&1; then
    fail "an unsupported install schema was accepted"
fi

printf 'update.sh tests passed\n'

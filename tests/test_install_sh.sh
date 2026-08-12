#!/bin/sh
set -eu

repoDir="$(cd "$(dirname "$0")/.." && pwd)"
testRoot="$(mktemp -d "${TMPDIR:-/tmp}/routerchat-installer-test.XXXXXX")"
export HOME="$testRoot/home"

cleanup() {
    rm -rf "$testRoot"
}
trap cleanup EXIT INT TERM HUP

failTest() {
    printf 'install test failed: %s\n' "$1" >&2
    exit 1
}

sed '$d' "$repoDir/install.sh" >"$testRoot/install-functions.sh"
. "$testRoot/install-functions.sh"

resetFixture() {
    rm -rf "$installRoot"
    createDirectories
    mkdir -p "$appDir/backend" "$appDir/dist"
    printf '%s\n' '{"version":"1.0.0"}' >"$appDir/version.json"
    : >"$appDir/backend/main.py"
    : >"$appDir/dist/index.html"
    : >"$appDir/requirements.lock"
    backupDir=""
    hadEnv="no"
    hadDatabase="no"
    wasRunning="no"
}

stageFailedVersion() {
    newVersion="1.0.1"
    mv "$appDir" "$previousApp"
    mkdir -p "$appDir/backend" "$appDir/dist"
    printf '%s\n' '{"version":"1.0.1"}' >"$appDir/version.json"
    : >"$appDir/backend/main.py"
    : >"$appDir/dist/index.html"
    : >"$appDir/requirements.lock"
}

resetFixture
printf '%s\n' 'old-env' >"$userDataDir/.env"
printf '%s\n' 'old-database' >"$userDataDir/routerchat.sqlite3"
backupUserData
stageFailedVersion
printf '%s\n' 'changed-env' >"$userDataDir/.env"
printf '%s\n' 'migrated-database' >"$userDataDir/routerchat.sqlite3"
: >"$userDataDir/routerchat.sqlite3-wal"
restoreApplication
grep -q '"1.0.0"' "$appDir/version.json" || failTest "the previous app was not restored"
grep -q 'old-env' "$userDataDir/.env" || failTest "the previous environment file was not restored"
grep -q 'old-database' "$userDataDir/routerchat.sqlite3" || failTest "the previous database was not restored"
[ ! -e "$userDataDir/routerchat.sqlite3-wal" ] || failTest "a database sidecar survived rollback"

resetFixture
backupUserData
stageFailedVersion
: >"$userDataDir/.env"
: >"$userDataDir/routerchat.sqlite3"
restoreApplication
[ ! -e "$userDataDir/.env" ] || failTest "rollback kept an environment file that did not exist before"
[ ! -e "$userDataDir/routerchat.sqlite3" ] || failTest "rollback kept a database that did not exist before"

resetFixture
printf '%s\n' 'old-database' >"$userDataDir/routerchat.sqlite3"
backupUserData
stageFailedVersion
printf '%s\n' 'migrated-database' >"$userDataDir/routerchat.sqlite3"
portIsBusy() { return 0; }
if (startRouterchat) >/dev/null 2>&1; then
    failTest "a port conflict reported success"
fi
grep -q '"1.0.0"' "$appDir/version.json" || failTest "a port conflict did not restore the previous app"
grep -q 'old-database' "$userDataDir/routerchat.sqlite3" || failTest "a port conflict did not restore the previous database"

resetFixture
printf '%s\n' 'old-database' >"$userDataDir/routerchat.sqlite3"
backupUserData
stageFailedVersion
printf '%s\n' 'migrated-database' >"$userDataDir/routerchat.sqlite3"
cat >"$installRoot/install.json" <<'EOF'
{"schemaVersion":1,"installedVersion":"1.0.0"}
EOF
recoverInterruptedInstallation
grep -q '"1.0.0"' "$appDir/version.json" || failTest "an interrupted update did not restore the previous app"
grep -q 'old-database' "$userDataDir/routerchat.sqlite3" || failTest "an interrupted update did not restore the previous database"
[ ! -d "$previousApp" ] || failTest "the interrupted rollback directory was not cleaned up"

resetFixture
printf '%s\n' 'old-database' >"$userDataDir/routerchat.sqlite3"
backupUserData
mv "$appDir" "$previousApp"
mkdir -p "$appDir/backend" "$appDir/dist"
printf '%s\n' '{"version":"1.0.0"}' >"$appDir/version.json"
: >"$appDir/backend/main.py"
: >"$appDir/dist/index.html"
: >"$appDir/requirements.lock"
printf '%s\n' 'migrated-database' >"$userDataDir/routerchat.sqlite3"
printf '%s\n' '1.0.0' >"$transactionFile"
cat >"$installRoot/install.json" <<'EOF'
{"schemaVersion":1,"installedVersion":"1.0.0"}
EOF
recoverInterruptedInstallation
grep -q 'old-database' "$userDataDir/routerchat.sqlite3" || failTest "an interrupted same-version repair did not restore the previous database"
[ ! -d "$previousApp" ] || failTest "the same-version rollback directory was not cleaned up"
[ ! -e "$transactionFile" ] || failTest "the transaction marker survived rollback"

resetFixture
writeLaunchers
createAliases
grep -q 'backend.local_access serve' "$installRoot/Start RouterChat.command" \
    || failTest "the macOS launcher did not use authenticated local access"
grep -q 'backend.local_access open-browser' "$installRoot/Start RouterChat.command" \
    || failTest "the macOS launcher did not bootstrap the browser"
grep -q 'ownedProcessId' "$installRoot/Start RouterChat.command" \
    || failTest "the macOS launcher did not verify an existing process"
grep -q 'chmod 700.*runDir' "$installRoot/Start RouterChat.command" \
    || failTest "the macOS launcher did not protect its run directory"
grep -q -- '--secret-file.*apiSecretFile' "$installRoot/Start RouterChat.command" \
    || failTest "the macOS launcher did not pass the credential by protected file"
grep -q 'pip sync --require-hashes' "$repoDir/install.sh" \
    || failTest "the macOS installer did not enforce dependency hashes"
grep -q 'Use of RouterChat is subject to the Terms of Service:' "$repoDir/install.sh" \
    || failTest "the macOS installer did not show the Terms of Service notice"
grep -q 'https://github.com/echo1097/routerchat/blob/main/TOS.md' "$repoDir/install.sh" \
    || failTest "the macOS installer did not link the Terms of Service"
printf 'n\n' | "$installRoot/Uninstall RouterChat.command" >/dev/null
[ -d "$installRoot" ] || failTest "declining uninstall removed RouterChat"
[ -L "$HOME/Applications/RouterChat/Uninstall RouterChat.command" ] || failTest "the macOS uninstall alias was not created"

resetFixture
writeLaunchers
mkdir -p "$venvDir/bin"
cat >"$venvPython" <<'EOF'
#!/bin/sh
cp "$3" "$4"
EOF
chmod 755 "$venvPython"
printf '%s\n' 'saved-database' >"$userDataDir/routerchat.sqlite3"
printf 'y\ny\n' | "$installRoot/Uninstall RouterChat.command" >/dev/null
[ ! -e "$installRoot" ] || failTest "confirmed uninstall kept the RouterChat installation"
[ ! -e "$HOME/Applications/RouterChat" ] || failTest "confirmed uninstall kept the macOS launcher aliases"
backupDatabase="$(find "$HOME/Downloads" -name routerchat.sqlite3 -type f -print | head -n 1)"
[ -n "$backupDatabase" ] || failTest "the uninstaller did not save the database"
grep -q 'saved-database' "$backupDatabase" || failTest "the saved database does not match the user data"
backupReadme="$(dirname "$backupDatabase")/README-userdata.txt"
[ -f "$backupReadme" ] || failTest "the user data README was not created"
grep -q 'private content' "$backupReadme" || failTest "the user data README is missing its privacy warning"

resetFixture
writeLaunchers
printf '%s\n' 'do-not-save' >"$userDataDir/routerchat.sqlite3"
backupCountBefore="$(find "$HOME/Downloads" -name routerchat.sqlite3 -type f -print | wc -l | tr -d ' ')"
printf 'y\nn\n' | "$installRoot/Uninstall RouterChat.command" >/dev/null
backupCountAfter="$(find "$HOME/Downloads" -name routerchat.sqlite3 -type f -print | wc -l | tr -d ' ')"
[ "$backupCountBefore" = "$backupCountAfter" ] || failTest "declining the user data backup created one anyway"
[ ! -e "$installRoot" ] || failTest "uninstall without a backup kept the RouterChat installation"

resetFixture
writeLaunchers
mkdir -p "$venvDir/bin"
cat >"$venvPython" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$venvPython"
printf '%s\n' 'must-survive' >"$userDataDir/routerchat.sqlite3"
if printf 'y\ny\n' | "$installRoot/Uninstall RouterChat.command" >/dev/null 2>&1; then
    failTest "a failed user data backup reported a successful uninstall"
fi
[ -d "$installRoot" ] || failTest "a failed user data backup removed RouterChat"
grep -q 'must-survive' "$userDataDir/routerchat.sqlite3" || failTest "a failed user data backup damaged the database"

printf 'install.sh rollback and uninstaller tests passed\n'

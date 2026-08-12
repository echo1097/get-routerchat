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

printf 'install.sh rollback tests passed\n'

#!/bin/sh
set -eu

appRepo="echo1097/routerchat"
appZipUrl="https://github.com/$appRepo/releases/latest/download/routerchat-app.zip"
appChecksumUrl="https://github.com/$appRepo/releases/latest/download/routerchat-app.zip.sha256"
installerUrl="https://echo1097.github.io/get-routerchat/install.sh"
uvVersion="0.7.19"
pythonVersion="3.13"
routerchatPort="8000"
keptBackups="3"

installRoot="$HOME/Library/Application Support/RouterChat"
appDir="$installRoot/app"
runtimeDir="$installRoot/runtime"
userDataDir="$installRoot/user-data"
backupsDir="$installRoot/backups"
logsDir="$installRoot/logs"
venvDir="$runtimeDir/.venv"
venvPython="$venvDir/bin/python"
logFile=""
workDir=""

fail() {
    printf 'RouterChat installation failed: %s\n' "$1" >&2
    if [ -n "$logFile" ]; then
        printf 'RouterChat installation failed: %s\n' "$1" >>"$logFile" 2>/dev/null || true
        printf 'A sanitized log is at %s\n' "$logFile" >&2
    fi
    exit 1
}

say() {
    printf '%s\n' "$1"
    if [ -n "$logFile" ]; then
        printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >>"$logFile" 2>/dev/null || true
    fi
}

cleanup() {
    if [ -n "$workDir" ] && [ -d "$workDir" ]; then
        rm -rf "$workDir"
    fi
}

requireCommand() {
    command -v "$1" >/dev/null 2>&1 || fail "the required command '$1' is not available"
}

routerchatIsHealthy() {
    curl -fsS --max-time 2 "http://127.0.0.1:$routerchatPort/api/health" 2>/dev/null | grep -q '"ok"'
}

portIsBusy() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$routerchatPort" -sTCP:LISTEN >/dev/null 2>&1
    else
        nc -z 127.0.0.1 "$routerchatPort" >/dev/null 2>&1
    fi
}

checkPlatform() {
    [ "$(uname -s)" = "Darwin" ] || fail "this installer only supports macOS"

    machineName="$(uname -m)"
    case "$machineName" in
        arm64)
            platformName="macos-arm64"
            uvTarget="aarch64-apple-darwin"
            ;;
        x86_64)
            platformName="macos-x64"
            uvTarget="x86_64-apple-darwin"
            ;;
        *)
            fail "the processor type '$machineName' is not supported yet"
            ;;
    esac
}

checkInstallRoot() {
    case "$installRoot" in
        "" | "/" | "$HOME" | "$HOME/")
            fail "the installation path is unsafe"
            ;;
        "$HOME"/*)
            ;;
        *)
            fail "the installation path must live inside your home folder"
            ;;
    esac
}

createDirectories() {
    mkdir -p "$installRoot" "$runtimeDir" "$userDataDir" "$backupsDir" "$logsDir"
    chmod 700 "$userDataDir" 2>/dev/null || true

    logFile="$logsDir/install-$(date -u '+%Y-%m-%d').log"
    : >>"$logFile"
}

download() {
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -o "$2" "$1" \
        || fail "could not download $1"
}

verifyChecksum() {
    filePath="$1"
    checksumPath="$2"

    expectedSum="$(awk '{print $1; exit}' "$checksumPath")"
    actualSum="$(shasum -a 256 "$filePath" | awk '{print $1}')"

    case "$expectedSum" in
        [0-9a-fA-F][0-9a-fA-F]*) ;;
        *) fail "the published checksum could not be read" ;;
    esac

    [ "$expectedSum" = "$actualSum" ] || fail "a downloaded file did not match its published checksum"
}

extractZip() {
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$1" -d "$2" || fail "the downloaded package could not be extracted"
    else
        ditto -x -k "$1" "$2" || fail "the downloaded package could not be extracted"
    fi
}

downloadApplication() {
    say "Downloading RouterChat."

    download "$appZipUrl" "$workDir/routerchat-app.zip"
    download "$appChecksumUrl" "$workDir/routerchat-app.zip.sha256"
    verifyChecksum "$workDir/routerchat-app.zip" "$workDir/routerchat-app.zip.sha256"

    mkdir -p "$workDir/app"
    extractZip "$workDir/routerchat-app.zip" "$workDir/app"

    for requiredPath in backend/main.py dist/index.html requirements.lock version.json TOS.md LICENSE; do
        [ -f "$workDir/app/$requiredPath" ] || fail "the downloaded package is missing $requiredPath"
    done

    newVersion="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$workDir/app/version.json" | head -n 1)"
    [ -n "$newVersion" ] || fail "the downloaded package has no readable version"
}

installRuntime() {
    UV_PYTHON_INSTALL_DIR="$runtimeDir/python"
    UV_CACHE_DIR="$runtimeDir/cache"
    UV_NO_MODIFY_PATH="1"
    export UV_PYTHON_INSTALL_DIR UV_CACHE_DIR UV_NO_MODIFY_PATH

    uvBin="$runtimeDir/tools/uv"
    if [ ! -x "$uvBin" ]; then
        say "Setting up RouterChat's private Python runtime."

        uvArchive="uv-$uvTarget.tar.gz"
        uvBaseUrl="https://github.com/astral-sh/uv/releases/download/$uvVersion"
        download "$uvBaseUrl/$uvArchive" "$workDir/$uvArchive"
        download "$uvBaseUrl/$uvArchive.sha256" "$workDir/$uvArchive.sha256"
        verifyChecksum "$workDir/$uvArchive" "$workDir/$uvArchive.sha256"

        mkdir -p "$workDir/uv" "$runtimeDir/tools"
        tar -xzf "$workDir/$uvArchive" -C "$workDir/uv" || fail "the private runtime tool could not be extracted"

        extractedUv="$(find "$workDir/uv" -type f -name uv -perm -u+x | head -n 1)"
        [ -n "$extractedUv" ] || fail "the private runtime tool was not found in its archive"

        cp "$extractedUv" "$uvBin"
        chmod 755 "$uvBin"
    fi

    "$uvBin" python install "$pythonVersion" >>"$logFile" 2>&1 \
        || fail "the private Python runtime could not be installed"
}

syncEnvironment() {
    if [ ! -x "$venvPython" ]; then
        say "Creating RouterChat's private environment."
        rm -rf "$venvDir"
        "$uvBin" venv --python "$pythonVersion" --managed-python "$venvDir" >>"$logFile" 2>&1 \
            || fail "the private environment could not be created"
    fi

    say "Installing RouterChat's dependencies."
    "$uvBin" pip sync --python "$venvPython" "$appDir/requirements.lock" >>"$logFile" 2>&1 \
        || fail "the RouterChat dependencies could not be installed"
}

backupUserData() {
    [ -f "$userDataDir/routerchat.sqlite3" ] || [ -f "$userDataDir/.env" ] || return 0

    backupDir="$backupsDir/$(date -u '+%Y%m%d-%H%M%S')"
    mkdir -p "$backupDir"
    chmod 700 "$backupDir" 2>/dev/null || true

    [ -f "$userDataDir/.env" ] && cp "$userDataDir/.env" "$backupDir/.env"
    [ -f "$userDataDir/routerchat.sqlite3" ] && cp "$userDataDir/routerchat.sqlite3" "$backupDir/routerchat.sqlite3"

    say "Saved a backup of your existing RouterChat data."
    trimBackups
}

trimBackups() {
    ls -1 "$backupsDir" 2>/dev/null | sort -r | tail -n +"$((keptBackups + 1))" | while read -r oldBackup; do
        case "$oldBackup" in
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
                rm -rf "$backupsDir/$oldBackup"
                ;;
        esac
    done
}

installApplication() {
    say "Installing RouterChat $newVersion."

    previousApp="$installRoot/app.previous"
    rm -rf "$previousApp"

    if [ -d "$appDir" ]; then
        mv "$appDir" "$previousApp"
    fi

    if mv "$workDir/app" "$appDir"; then
        rm -rf "$previousApp"
    else
        [ -d "$previousApp" ] && mv "$previousApp" "$appDir"
        fail "the new RouterChat files could not be installed"
    fi
}

writeInstallMetadata() {
    installedAt="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    firstInstalledAt="$installedAt"

    if [ -f "$installRoot/install.json" ]; then
        existingInstalledAt="$(sed -n 's/.*"installedAt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$installRoot/install.json" | head -n 1)"
        [ -n "$existingInstalledAt" ] && firstInstalledAt="$existingInstalledAt"
    fi

    cat >"$installRoot/install.json.tmp" <<METADATA
{
  "schemaVersion": 1,
  "installedVersion": "$newVersion",
  "installedAt": "$firstInstalledAt",
  "updatedAt": "$installedAt",
  "platform": "$platformName",
  "appDirectory": "app",
  "runtimeDirectory": "runtime",
  "userDataDirectory": "user-data"
}
METADATA

    mv "$installRoot/install.json.tmp" "$installRoot/install.json"
}

writeLaunchers() {
    cat >"$installRoot/Start RouterChat.command" <<'LAUNCHER'
#!/bin/sh
set -eu

installRoot="$(cd "$(dirname "$0")" && pwd)"
appDir="$installRoot/app"
venvPython="$installRoot/runtime/.venv/bin/python"
userDataDir="$installRoot/user-data"
logsDir="$installRoot/logs"
routerchatPort="8000"
routerchatUrl="http://127.0.0.1:$routerchatPort"
serverPid=""

stopServer() {
    if [ -n "$serverPid" ] && kill -0 "$serverPid" 2>/dev/null; then
        kill "$serverPid" 2>/dev/null || true
    fi
    rm -f "$logsDir/routerchat.pid"
}

isRouterchatHealthy() {
    curl -fsS --max-time 2 "$routerchatUrl/api/health" 2>/dev/null | grep -q '"ok"'
}

isPortBusy() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$routerchatPort" -sTCP:LISTEN >/dev/null 2>&1
    else
        nc -z 127.0.0.1 "$routerchatPort" >/dev/null 2>&1
    fi
}

for requiredPath in "$appDir/backend/main.py" "$appDir/dist/index.html" "$venvPython"; do
    if [ ! -e "$requiredPath" ]; then
        printf 'RouterChat is not installed correctly. Rerun the installer to repair it.\n' >&2
        printf 'Missing: %s\n' "$requiredPath" >&2
        exit 1
    fi
done

mkdir -p "$logsDir" "$userDataDir"
logFile="$logsDir/launcher-$(date -u '+%Y-%m-%d').log"

if isRouterchatHealthy; then
    printf 'RouterChat is already running. Opening it in your browser.\n'
    open "$routerchatUrl"
    exit 0
fi

if isPortBusy; then
    printf 'Port %s is used by another program, so RouterChat cannot start.\n' "$routerchatPort" >&2
    printf 'Close that program and start RouterChat again.\n' >&2
    exit 1
fi

trap stopServer EXIT INT TERM HUP

ROUTERCHAT_USER_DATA_DIR="$userDataDir"
export ROUTERCHAT_USER_DATA_DIR

cd "$appDir"
"$venvPython" -m uvicorn backend.main:app --host 127.0.0.1 --port "$routerchatPort" >>"$logFile" 2>&1 &
serverPid=$!
printf '%s\n' "$serverPid" >"$logsDir/routerchat.pid"

printf 'Starting RouterChat.\n'
attempt=0
while [ "$attempt" -lt 60 ]; do
    if isRouterchatHealthy; then
        break
    fi
    if ! kill -0 "$serverPid" 2>/dev/null; then
        printf 'RouterChat stopped while starting. See %s\n' "$logFile" >&2
        tail -n 20 "$logFile" >&2 || true
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1
done

if ! isRouterchatHealthy; then
    printf 'RouterChat did not become ready in time. See %s\n' "$logFile" >&2
    tail -n 20 "$logFile" >&2 || true
    exit 1
fi

open "$routerchatUrl"

printf 'RouterChat is running at %s\n' "$routerchatUrl"
printf 'Closing this window stops RouterChat.\n'

wait "$serverPid"
LAUNCHER

    cat >"$installRoot/Update RouterChat.command" <<UPDATER
#!/bin/sh
set -eu

printf 'Checking for a newer version of RouterChat.\n'
curl -fsSL --proto '=https' --tlsv1.2 "$installerUrl" | sh
UPDATER

    chmod 755 "$installRoot/Start RouterChat.command" "$installRoot/Update RouterChat.command"
}

createAliases() {
    aliasDir="$HOME/Applications/RouterChat"
    mkdir -p "$aliasDir" 2>/dev/null || return 0

    ln -sfn "$installRoot/Start RouterChat.command" "$aliasDir/Start RouterChat.command" 2>/dev/null || true
    ln -sfn "$installRoot/Update RouterChat.command" "$aliasDir/Update RouterChat.command" 2>/dev/null || true
}

startRouterchat() {
    say "Starting RouterChat."

    ROUTERCHAT_USER_DATA_DIR="$userDataDir"
    export ROUTERCHAT_USER_DATA_DIR

    startupLog="$logsDir/launcher-$(date -u '+%Y-%m-%d').log"
    if routerchatIsHealthy; then
        say "RouterChat is already running."
    elif portIsBusy; then
        say "Port $routerchatPort is used by another program, so RouterChat was installed but not started."
        return 0
    else
        (
            cd "$appDir"
            nohup "$venvPython" -m uvicorn backend.main:app --host 127.0.0.1 --port "$routerchatPort" \
                >>"$startupLog" 2>&1 &
            printf '%s\n' "$!" >"$logsDir/routerchat.pid"
        )
    fi

    attempt=0
    while [ "$attempt" -lt 60 ]; do
        if routerchatIsHealthy; then
            open "http://127.0.0.1:$routerchatPort"
            say "RouterChat is ready at http://127.0.0.1:$routerchatPort"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    say "RouterChat was installed but did not start in time. Use 'Start RouterChat.command' and check $startupLog"
}

main() {
    requireCommand curl
    requireCommand shasum
    requireCommand tar

    checkPlatform
    checkInstallRoot
    createDirectories

    workDir="$(mktemp -d "${TMPDIR:-/tmp}/routerchat-install.XXXXXX")"
    chmod 700 "$workDir"
    trap cleanup EXIT INT TERM HUP

    say "Installing RouterChat for $platformName into $installRoot"

    downloadApplication
    installRuntime
    backupUserData
    installApplication
    syncEnvironment
    writeInstallMetadata
    writeLaunchers
    createAliases
    startRouterchat

    say "Done. Start RouterChat later from 'Start RouterChat.command' in $installRoot"
}

main

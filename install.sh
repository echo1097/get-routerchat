#!/bin/sh
set -eu

appRepo="echo1097/routerchat"
appZipUrl="https://github.com/$appRepo/releases/latest/download/routerchat-app.zip"
appChecksumUrl="https://github.com/$appRepo/releases/latest/download/routerchat-app.zip.sha256"
uvVersion="0.7.19"
pythonVersion="3.13"
routerchatPort="8000"
keptBackups="3"

installRoot="$HOME/Library/Application Support/RouterChat"
appDir="$installRoot/app"
previousApp="$installRoot/app.previous"
transactionFile="$installRoot/install.transaction"
runtimeDir="$installRoot/runtime"
userDataDir="$installRoot/user-data"
backupsDir="$installRoot/backups"
logsDir="$installRoot/logs"
runDir="$installRoot/run"
apiSecretFile="$runDir/api-secret"
venvDir="$runtimeDir/.venv"
venvPython="$venvDir/bin/python"
logFile=""
workDir=""
wasRunning="no"
startupLog=""
backupDir=""
hadEnv="no"
hadDatabase="no"
previousVersion=""
newVersion=""
updateMode="no"
[ -n "${ROUTERCHAT_EXPECTED_VERSION:-}" ] && updateMode="yes"

stepWidth=46
barWidth=24
stepPrefix=""
stepOpen="no"
barDrawn="no"
spinTick=0
progressKind=""
progressPath=""
progressTotal=0
progressLabel=""
progressBase=0
nextMeasure=0
measuredKind=""
measuredBytes=0
measuredCount=0
stepPlain=""
stepNumber=0
packageTotal=0
runtimeWasReady="no"

if [ -t 1 ]; then
    fancy="yes"
    bold="$(printf '\033[1m')"
    dim="$(printf '\033[2m')"
    red="$(printf '\033[31m')"
    green="$(printf '\033[32m')"
    yellow="$(printf '\033[33m')"
    cyan="$(printf '\033[36m')"
    blue="$(printf '\033[38;5;33m')"
    reset="$(printf '\033[0m')"
    clearLine="$(printf '\033[K')"
    lineUp="$(printf '\033[1A')"
    hideCursor="$(printf '\033[?25l')"
    showCursor="$(printf '\033[?25h')"
else
    fancy="no"
    bold="" dim="" red="" green="" yellow="" cyan="" blue="" reset="" clearLine="" lineUp="" hideCursor="" showCursor=""
fi

logLine() {
    [ -n "$logFile" ] || return 0
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >>"$logFile" 2>/dev/null || true
}

note() {
    logLine "$1"
}

shortPath() {
    case "$1" in
        "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        *) printf '%s' "$1" ;;
    esac
}

dots() {
    count=$((stepWidth - ${#1}))
    [ "$count" -lt 3 ] && count=3

    dotLine=""
    while [ "$count" -gt 0 ]; do
        dotLine="$dotLine."
        count=$((count - 1))
    done

    printf '%s' "$dotLine"
}

spinnerFrame() {
    case $(($1 % 10)) in
        0) printf '⠋' ;;
        1) printf '⠙' ;;
        2) printf '⠹' ;;
        3) printf '⠸' ;;
        4) printf '⠼' ;;
        5) printf '⠴' ;;
        6) printf '⠦' ;;
        7) printf '⠧' ;;
        8) printf '⠇' ;;
        *) printf '⠏' ;;
    esac
}

repeatText() {
    repeatCount="$2"
    repeated=""
    while [ "$repeatCount" -gt 0 ]; do
        repeated="$repeated$1"
        repeatCount=$((repeatCount - 1))
    done
    printf '%s' "$repeated"
}

progressBar() {
    filled=$((barWidth * $1 / $2))
    [ "$filled" -gt "$barWidth" ] && filled="$barWidth"
    printf '%s%s%s%s%s' "$green" "$(repeatText '█' "$filled")" "$dim" "$(repeatText '░' $((barWidth - filled)))" "$reset"
}

movingBar() {
    blockSize=6
    blockEnd=$((spinTick * 3 / 2 % (barWidth + blockSize)))
    blockStart=$((blockEnd - blockSize))
    [ "$blockStart" -lt 0 ] && blockStart=0
    [ "$blockEnd" -gt "$barWidth" ] && blockEnd="$barWidth"

    printf '%s%s%s%s%s%s%s' "$dim" "$(repeatText '░' "$blockStart")" "$blue" "$(repeatText '█' $((blockEnd - blockStart)))" "$dim" "$(repeatText '░' $((barWidth - blockEnd)))" "$reset"
}

megabytes() {
    tenths=$(($1 * 10 / 1048576))
    printf '%d.%d MB' $((tenths / 10)) $((tenths % 10))
}

fileBytes() {
    if [ -f "$1" ]; then
        wc -c <"$1" | tr -d ' '
    else
        printf '0'
    fi
}

headerLength() {
    [ -f "$1" ] || { printf '0'; return 0; }
    tr -d '\r' <"$1" | awk 'tolower($1) == "content-length:" { size = $2 } END { print size + 0 }'
}

folderBytes() {
    if [ -d "$1" ]; then
        du -sk "$1" 2>/dev/null | awk '{ print $1 * 1024 }'
    else
        printf '0'
    fi
}

installedPackages() {
    find "$venvDir"/lib/python*/site-packages -maxdepth 1 -name '*.dist-info' 2>/dev/null | wc -l | tr -d ' '
}

lockedPackages() {
    grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*==' "$1" | grep -v "sys_platform == 'win32'" | wc -l | tr -d ' '
}

measureProgress() {
    measuredKind="$progressKind"
    measuredBytes=0
    measuredCount=0

    case "$progressKind" in
        bytes)
            [ "$progressTotal" -gt 0 ] || progressTotal="$(headerLength "$progressPath.headers")"
            measuredBytes="$(fileBytes "$progressPath")"
            ;;
        growth)
            measuredBytes="$(folderBytes "$progressPath")"
            ;;
        packages)
            measuredCount="$(installedPackages)"
            if [ "$measuredCount" -eq 0 ]; then
                measuredBytes=$(($(folderBytes "$progressPath") - progressBase))
            fi
            ;;
    esac
}

progressText() {
    case "$progressKind" in
        bytes)
            current="$measuredBytes"
            if [ "$progressTotal" -gt 0 ]; then
                [ "$current" -gt "$progressTotal" ] && current="$progressTotal"
                printf '%s %s / %s  %3d%%' "$(progressBar "$current" "$progressTotal")" "$(megabytes "$current")" "$(megabytes "$progressTotal")" $((100 * current / progressTotal))
            else
                printf '%s %s' "$(movingBar)" "$(megabytes "$current")"
            fi
            ;;
        growth)
            printf '%s %s  %s' "$(movingBar)" "$progressLabel" "$(megabytes "$measuredBytes")"
            ;;
        packages)
            current="$measuredCount"
            [ "$current" -gt "$progressTotal" ] && current="$progressTotal"
            if [ "$current" -eq 0 ]; then
                downloaded="$measuredBytes"
                [ "$downloaded" -lt 0 ] && downloaded=0
                printf '%s downloading packages  %s' "$(movingBar)" "$(megabytes "$downloaded")"
                return 0
            fi
            printf '%s %d / %d packages  %3d%%' "$(progressBar "$current" "$progressTotal")" "$current" "$progressTotal" $((100 * current / progressTotal))
            ;;
    esac
}

printTerms() {
    printf '%sUse of RouterChat is subject to the Terms of Service:%s\n' "$dim" "$reset"
    printf '%shttps://github.com/echo1097/routerchat/blob/main/TOS.md%s\n\n' "$dim" "$reset"
}

stepLabel() {
    stepPrefix="$dim[$1/6]$reset $2 $dim$(dots "$2")$reset"
    stepPlain="[$1/6] $2"
}

stepStart() {
    stepLabel "$1" "$2"
    stepNumber="$1"
    stepOpen="yes"
    barDrawn="no"
    progressKind=""
    progressTotal=0
    nextMeasure=0
    measuredBytes=0
    measuredCount=0
    note "$stepPlain"

    [ "$fancy" = "yes" ] && printf '%s' "$stepPrefix"
    return 0
}

stepTick() {
    [ "$stepOpen" = "yes" ] && [ "$fancy" = "yes" ] || return 0
    spinTick=$((spinTick + ${1:-1}))
    frame="$dim$(spinnerFrame $((spinTick / 2)))$reset"

    if [ -z "$progressKind" ]; then
        printf '\r%s %s' "$stepPrefix" "$frame"
        return 0
    fi

    if [ "$spinTick" -ge "$nextMeasure" ] || [ "$measuredKind" != "$progressKind" ]; then
        measureProgress
        nextMeasure=$((spinTick + 6))
    fi

    if [ "$barDrawn" = "yes" ]; then
        printf '%s' "$lineUp"
    fi

    printf '\r%s %s%s\n\r      %s%s' "$stepPrefix" "$frame" "$clearLine" "$(progressText)" "$clearLine"
    barDrawn="yes"
}

stepFinish() {
    [ "$stepOpen" = "yes" ] || return 0

    status="$1"
    tone="$2"
    barText="${3:-}"

    [ "$barDrawn" = "yes" ] && printf '%s' "$lineUp"
    printf '\r%s %s%s%s%s\n' "$stepPrefix" "$tone" "$status" "$reset" "$clearLine"

    if [ -n "$barText" ]; then
        printf '      %s %s%s%s%s\n' "$(progressBar 1 1)" "$dim" "$barText" "$reset" "$clearLine"
    elif [ "$barDrawn" = "yes" ]; then
        printf '%s' "$clearLine"
    fi

    stepOpen="no"
    barDrawn="no"
    note "$stepPlain $status"
}

stepFailed() {
    stepFinish "failed" "$red"
}

watchCommand() {
    "$@" &
    watchedPid=$!

    while kill -0 "$watchedPid" 2>/dev/null; do
        stepTick
        sleep 0.05
    done

    if wait "$watchedPid"; then
        return 0
    else
        return $?
    fi
}

pause() {
    pauseTicks=$(($1 * 5))
    while [ "$pauseTicks" -gt 0 ]; do
        stepTick 4
        sleep 0.2
        pauseTicks=$((pauseTicks - 1))
    done
}

warn() {
    stepFailed
    printf '%s! %s%s\n' "$yellow" "$1" "$reset"
    logLine "$1"
}

notice() {
    printf '%s! %s%s\n' "$yellow" "$1" "$reset"
    logLine "$1"
}

showFailure() {
    stepFailed
    printf '\n%s%s✗ %s:%s %s\n' "$red" "$bold" "$1" "$reset" "$2" >&2
    logLine "$1: $2"
    if [ -n "$logFile" ]; then
        printf '%s  Log: %s%s\n' "$dim" "$(shortPath "$logFile")" "$reset" >&2
    fi
}

fail() {
    showFailure "RouterChat installation failed" "$1"
    exit 1
}

failStart() {
    showFailure "RouterChat was installed but could not be started" "$1"
    exit 1
}

cleanup() {
    printf '%s' "$showCursor"
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

runningVersion() {
    curl -fsS --max-time 2 "http://127.0.0.1:$routerchatPort/api/health" 2>/dev/null \
        | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n 1
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

fetchFile() {
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --retry-delay 2 -D "$2.headers" -o "$2" "$1" 2>>"${logFile:-/dev/null}"
}

download() {
    if [ "${3:-}" = "track" ]; then
        progressKind="bytes"
        progressPath="$2"
        progressTotal=0
    fi

    watchCommand fetchFile "$1" "$2" || fail "could not download $1"
}

verifyChecksum() {
    filePath="$1"
    checksumPath="$2"

    expectedSum="$(awk '{print $1; exit}' "$checksumPath")"
    actualSum="$(shasum -a 256 "$filePath" | awk '{print $1}')"

    case "$expectedSum" in
        *[!0-9a-fA-F]* | "") fail "the published checksum could not be read" ;;
    esac

    [ "${#expectedSum}" -eq 64 ] || fail "the published checksum is invalid"

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
    download "$appZipUrl" "$workDir/routerchat-app.zip" track
    download "$appChecksumUrl" "$workDir/routerchat-app.zip.sha256"
    verifyChecksum "$workDir/routerchat-app.zip" "$workDir/routerchat-app.zip.sha256"

    if [ -n "${ROUTERCHAT_EXPECTED_APP_SHA256:-}" ]; then
        downloadedSum="$(shasum -a 256 "$workDir/routerchat-app.zip" | awk '{print $1}')"
        [ "$downloadedSum" = "$ROUTERCHAT_EXPECTED_APP_SHA256" ] \
            || fail "the latest release changed after the updater validated it; run the update again"
    fi

    mkdir -p "$workDir/app"
    extractZip "$workDir/routerchat-app.zip" "$workDir/app"

    for requiredPath in backend/main.py dist/index.html requirements.lock version.json TOS.md LICENSE; do
        [ -f "$workDir/app/$requiredPath" ] || fail "the downloaded package is missing $requiredPath"
    done

    newVersion="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$workDir/app/version.json" | head -n 1)"
    [ -n "$newVersion" ] || fail "the downloaded package has no readable version"

    if [ -n "${ROUTERCHAT_EXPECTED_VERSION:-}" ]; then
        [ "$newVersion" = "$ROUTERCHAT_EXPECTED_VERSION" ] \
            || fail "the latest release version changed after the updater validated it; run the update again"
    fi
}

installRuntime() {
    UV_PYTHON_INSTALL_DIR="$runtimeDir/python"
    UV_CACHE_DIR="$runtimeDir/cache"
    UV_NO_MODIFY_PATH="1"
    export UV_PYTHON_INSTALL_DIR UV_CACHE_DIR UV_NO_MODIFY_PATH

    uvBin="$runtimeDir/tools/uv"
    runtimeWasReady="no"
    if [ -x "$uvBin" ] && [ -n "$(ls -A "$runtimeDir/python" 2>/dev/null)" ]; then
        runtimeWasReady="yes"
    fi

    if [ ! -x "$uvBin" ]; then
        note "Setting up RouterChat's private Python runtime."

        uvArchive="uv-$uvTarget.tar.gz"
        uvBaseUrl="https://github.com/astral-sh/uv/releases/download/$uvVersion"
        download "$uvBaseUrl/$uvArchive" "$workDir/$uvArchive" track
        download "$uvBaseUrl/$uvArchive.sha256" "$workDir/$uvArchive.sha256"
        verifyChecksum "$workDir/$uvArchive" "$workDir/$uvArchive.sha256"

        mkdir -p "$workDir/uv" "$runtimeDir/tools"
        tar -xzf "$workDir/$uvArchive" -C "$workDir/uv" || fail "the private runtime tool could not be extracted"

        extractedUv="$(find "$workDir/uv" -type f -name uv -perm -u+x | head -n 1)"
        [ -n "$extractedUv" ] || fail "the private runtime tool was not found in its archive"

        cp "$extractedUv" "$uvBin"
        chmod 755 "$uvBin"
    fi

    if [ "$runtimeWasReady" = "no" ]; then
        progressKind="growth"
        progressPath="$runtimeDir/python"
        progressLabel="Python $pythonVersion"
    fi

    watchCommand runLogged "$uvBin" python install "$pythonVersion" \
        || fail "the private Python runtime could not be installed"
}

runLogged() {
    "$@" >>"$logFile" 2>&1
}

syncEnvironment() {
    if [ ! -x "$venvPython" ]; then
        note "Creating RouterChat's private environment."
        rm -rf "$venvDir"
        if ! "$uvBin" venv --python "$pythonVersion" --managed-python "$venvDir" >>"$logFile" 2>&1; then
            restoreApplication
            fail "the private environment could not be created"
        fi
    fi

    packageTotal="$(lockedPackages "$appDir/requirements.lock")"
    if [ "$packageTotal" -gt 0 ]; then
        progressKind="packages"
        progressTotal="$packageTotal"
        progressPath="$runtimeDir/cache"
        progressBase="$(folderBytes "$progressPath")"
    fi

    note "Installing RouterChat's dependencies."
    if ! watchCommand runLogged "$uvBin" pip sync --require-hashes --python "$venvPython" "$appDir/requirements.lock"; then
        restoreApplication
        fail "the RouterChat dependencies could not be installed"
    fi
}

backupUserData() {
    backupDir=""
    hadEnv="no"
    hadDatabase="no"

    [ -f "$userDataDir/.env" ] && hadEnv="yes"
    [ -f "$userDataDir/routerchat.sqlite3" ] && hadDatabase="yes"
    [ "$hadEnv" = "yes" ] || [ "$hadDatabase" = "yes" ] || [ -d "$appDir" ] || return 0

    backupDir="$backupsDir/$(date -u '+%Y%m%d-%H%M%S')-$$"
    mkdir "$backupDir" || return 1
    chmod 700 "$backupDir" 2>/dev/null || true

    if [ -f "$userDataDir/.env" ]; then
        cp "$userDataDir/.env" "$backupDir/.env" || return 1
    fi
    if [ -f "$userDataDir/routerchat.sqlite3" ]; then
        cp "$userDataDir/routerchat.sqlite3" "$backupDir/routerchat.sqlite3" || return 1
    fi

    note "Saved a backup of your existing RouterChat data."
    trimBackups
}

restoreUserData() {
    [ -n "$backupDir" ] && [ -d "$backupDir" ] || return 0

    rm -f "$userDataDir/routerchat.sqlite3-wal" "$userDataDir/routerchat.sqlite3-shm"

    if [ "$hadEnv" = "yes" ]; then
        cp "$backupDir/.env" "$userDataDir/.env.restore"
        chmod 600 "$userDataDir/.env.restore" 2>/dev/null || true
        mv "$userDataDir/.env.restore" "$userDataDir/.env"
    else
        rm -f "$userDataDir/.env"
    fi

    if [ "$hadDatabase" = "yes" ]; then
        cp "$backupDir/routerchat.sqlite3" "$userDataDir/routerchat.sqlite3.restore"
        mv "$userDataDir/routerchat.sqlite3.restore" "$userDataDir/routerchat.sqlite3"
    else
        rm -f "$userDataDir/routerchat.sqlite3"
    fi

    warn "Restored the previous RouterChat user data."
}

loadLatestBackupSnapshot() {
    latestBackup="$(find "$backupsDir" -mindepth 1 -maxdepth 1 -type d \( -name '????????-??????' -o -name '????????-??????-[0-9]*' \) 2>/dev/null | sort | tail -n 1)"
    [ -n "$latestBackup" ] || return 1

    backupName="$(basename "$latestBackup")"
    backupPrefix="$(printf '%s' "$backupName" | cut -c 1-15)"
    backupSuffix="$(printf '%s' "$backupName" | cut -c 16-)"
    case "$backupPrefix" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) return 1 ;;
    esac
    case "$backupSuffix" in
        "") ;;
        -*)
            backupSuffixDigits="${backupSuffix#-}"
            case "$backupSuffixDigits" in
                "" | *[!0-9]*) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac

    backupDir="$latestBackup"
    hadEnv="no"
    hadDatabase="no"
    [ -f "$backupDir/.env" ] && hadEnv="yes"
    [ -f "$backupDir/routerchat.sqlite3" ] && hadDatabase="yes"
}

fileVersion() {
    [ -f "$1" ] || return 0
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

recoverInterruptedInstallation() {
    if [ ! -d "$previousApp" ]; then
        rm -f "$transactionFile"
        return 0
    fi

    if [ ! -d "$appDir" ]; then
        loadLatestBackupSnapshot || true
        mv "$previousApp" "$appDir"
        restoreUserData
        rm -f "$transactionFile"
        notice "Recovered the previous RouterChat version after an interrupted update."
        return 0
    fi

    if [ -f "$transactionFile" ]; then
        loadLatestBackupSnapshot || true
        rm -rf "$appDir"
        mv "$previousApp" "$appDir"
        restoreUserData
        rm -f "$transactionFile"
        notice "Rolled back an interrupted RouterChat update."
        return 0
    fi

    appVersion="$(fileVersion "$appDir/version.json")"
    metadataVersion=""
    if [ -f "$installRoot/install.json" ]; then
        metadataVersion="$(sed -n 's/.*"installedVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$installRoot/install.json" | head -n 1)"
    fi

    if [ -n "$appVersion" ] && [ "$appVersion" = "$metadataVersion" ]; then
        rm -rf "$previousApp"
        note "Finished cleanup from the previous RouterChat update."
        return 0
    fi

    loadLatestBackupSnapshot || true
    rm -rf "$appDir"
    mv "$previousApp" "$appDir"
    restoreUserData
    notice "Rolled back an interrupted RouterChat update."
}

trimBackups() {
    ls -1 "$backupsDir" 2>/dev/null | sort -r | tail -n +"$((keptBackups + 1))" | while read -r oldBackup; do
        oldPrefix="$(printf '%s' "$oldBackup" | cut -c 1-15)"
        oldSuffix="$(printf '%s' "$oldBackup" | cut -c 16-)"
        case "$oldPrefix" in
            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
            *) continue ;;
        esac
        case "$oldSuffix" in
            "") rm -rf "$backupsDir/$oldBackup" ;;
            -*)
                oldSuffixDigits="${oldSuffix#-}"
                case "$oldSuffixDigits" in
                    "" | *[!0-9]*) continue ;;
                esac
                rm -rf "$backupsDir/$oldBackup"
                ;;
        esac
    done
}

installApplication() {
    note "Installing RouterChat $newVersion."

    if [ ! -d "$appDir" ] && [ -d "$previousApp" ]; then
        mv "$previousApp" "$appDir"
    fi

    previousVersion=""
    if [ -f "$appDir/version.json" ]; then
        previousVersion="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$appDir/version.json" | head -n 1)"
    fi

    rm -rf "$previousApp"

    if [ -d "$appDir" ]; then
        mv "$appDir" "$previousApp"
    fi

    if ! mv "$workDir/app" "$appDir"; then
        restoreApplication
        fail "the new RouterChat files could not be installed"
    fi
}

restoreApplication() {
    [ -d "$previousApp" ] || return 0

    rm -rf "$appDir"
    mv "$previousApp" "$appDir"
    restoreUserData
    rm -f "$transactionFile"
    warn "Restored the previous RouterChat application files."

    if [ -x "$venvPython" ] && [ -f "$appDir/requirements.lock" ]; then
        "$uvBin" pip sync --require-hashes --python "$venvPython" "$appDir/requirements.lock" >>"$logFile" 2>&1 || true
    fi

    restartPreviousInstance
}

discardPreviousApplication() {
    rm -rf "$previousApp"
}

beginInstallTransaction() {
    printf '%s\n' "$newVersion" >"$transactionFile.tmp" || return 1
    mv "$transactionFile.tmp" "$transactionFile" || return 1
}

finishInstallTransaction() {
    rm -f "$transactionFile" || return 1
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
    cat >"$installRoot/Start RouterChat.command" <<'LAUNCHER' || return 1
#!/bin/sh
set -eu

installRoot="$(cd "$(dirname "$0")" && pwd)"
appDir="$installRoot/app"
venvPython="$installRoot/runtime/.venv/bin/python"
userDataDir="$installRoot/user-data"
logsDir="$installRoot/logs"
runDir="$installRoot/run"
apiSecretFile="$runDir/api-secret"
routerchatPort="8000"
routerchatUrl="http://127.0.0.1:$routerchatPort"
serverPid=""

stopServer() {
    if [ -n "$serverPid" ] && kill -0 "$serverPid" 2>/dev/null; then
        kill "$serverPid" 2>/dev/null || true
    fi
    rm -f "$logsDir/routerchat.pid"
    rm -f "$apiSecretFile"
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

ownedProcessId() {
    pidFile="$logsDir/routerchat.pid"
    [ -f "$pidFile" ] || return 1

    ownedPid="$(head -n 1 "$pidFile" | tr -dc '0-9')"
    [ -n "$ownedPid" ] || return 1
    kill -0 "$ownedPid" 2>/dev/null || return 1
    ps -o command= -p "$ownedPid" 2>/dev/null | grep -Fq "$venvPython" || return 1
    printf '%s\n' "$ownedPid"
}

openRouterchat() {
    if [ -f "$appDir/backend/local_access.py" ]; then
        [ -f "$apiSecretFile" ] || return 1
        (
            cd "$appDir"
            "$venvPython" -m backend.local_access open-browser \
                --secret-file "$apiSecretFile" \
                --base-url "$routerchatUrl"
        )
        return
    fi

    open "$routerchatUrl"
}

for requiredPath in "$appDir/backend/main.py" "$appDir/dist/index.html" "$venvPython"; do
    if [ ! -e "$requiredPath" ]; then
        printf 'RouterChat is not installed correctly. Rerun the installer to repair it.\n' >&2
        printf 'Missing: %s\n' "$requiredPath" >&2
        exit 1
    fi
done

mkdir -p "$logsDir" "$userDataDir" "$runDir"
chmod 700 "$runDir" || {
    printf 'RouterChat could not protect its process credential directory.\n' >&2
    exit 1
}
logFile="$logsDir/launcher-$(date -u '+%Y-%m-%d').log"

if isRouterchatHealthy; then
    if ! ownedProcessId >/dev/null 2>&1; then
        printf 'RouterChat is running but it was not started by this installation.\n' >&2
        exit 1
    fi
    printf 'RouterChat is already running. Opening it in your browser.\n'
    openRouterchat || printf 'RouterChat is ready at %s, but the browser could not be authorized automatically.\n' "$routerchatUrl"
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
rm -f "$apiSecretFile"

cd "$appDir"
if [ -f "$appDir/backend/local_access.py" ]; then
    "$venvPython" -m backend.local_access serve \
        --secret-file "$apiSecretFile" \
        --base-url "$routerchatUrl" \
        --trusted-origin "$routerchatUrl" >>"$logFile" 2>&1 &
else
    "$venvPython" -m uvicorn backend.main:app --host 127.0.0.1 --port "$routerchatPort" >>"$logFile" 2>&1 &
fi
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

openRouterchat || printf 'RouterChat is ready at %s, but the browser could not be authorized automatically.\n' "$routerchatUrl"

printf 'RouterChat is running at %s\n' "$routerchatUrl"
printf 'Closing this window stops RouterChat.\n'

wait "$serverPid"
LAUNCHER

    cat >"$installRoot/Update RouterChat.command" <<'UPDATER' || return 1
#!/bin/sh
set -eu

installRoot="$(cd "$(dirname "$0")" && pwd)"
workDir="$(mktemp -d "${TMPDIR:-/tmp}/routerchat-updater-bootstrap.XXXXXX")"
updateUrl="https://echo1097.github.io/get-routerchat/updater/update.sh"
checksumsUrl="https://echo1097.github.io/get-routerchat/updater/checksums.txt"

cleanup() {
    rm -rf "$workDir"
}
trap cleanup EXIT INT TERM HUP

curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$workDir/update.sh" "$updateUrl"
curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$workDir/checksums.txt" "$checksumsUrl"

expectedSum="$(awk '$2 == "update.sh" {print $1; exit}' "$workDir/checksums.txt")"
actualSum="$(shasum -a 256 "$workDir/update.sh" | awk '{print $1}')"

if [ "${#expectedSum}" -ne 64 ] || [ "$expectedSum" != "$actualSum" ]; then
    printf 'RouterChat could not verify the updater, so nothing was changed.\n' >&2
    exit 1
fi

ROUTERCHAT_INSTALL_ROOT="$installRoot"
export ROUTERCHAT_INSTALL_ROOT
sh "$workDir/update.sh"
UPDATER

    cat >"$installRoot/Uninstall RouterChat.command" <<'UNINSTALLER' || return 1
#!/bin/sh
set -eu

installRoot="$HOME/Library/Application Support/RouterChat"
aliasDir="$HOME/Applications/RouterChat"
userDataDir="$installRoot/user-data"
logsDir="$installRoot/logs"
venvDir="$installRoot/runtime/.venv"
venvPython="$venvDir/bin/python"
routerchatUrl="http://127.0.0.1:8000"

askYesNo() {
    prompt="$1"

    while true; do
        printf '%s (y/n) ' "$prompt"
        IFS= read -r answer || answer=""

        case "$answer" in
            y | Y) return 0 ;;
            n | N) return 1 ;;
            *) printf 'Please enter y or n.\n' ;;
        esac
    done
}

routerchatIsHealthy() {
    curl -fsS --max-time 2 "$routerchatUrl/api/health" 2>/dev/null | grep -q '"ok"'
}

ownedProcessId() {
    pidFile="$logsDir/routerchat.pid"
    [ -f "$pidFile" ] || return 1

    ownedPid="$(head -n 1 "$pidFile")"
    case "$ownedPid" in
        "" | *[!0-9]*) return 1 ;;
    esac

    kill -0 "$ownedPid" 2>/dev/null || return 1
    ps -o command= -p "$ownedPid" 2>/dev/null | grep -Fq "$venvDir" || return 1

    printf '%s\n' "$ownedPid"
}

stopRouterchat() {
    ownedPid="$(ownedProcessId)" || {
        if routerchatIsHealthy; then
            printf 'RouterChat is running but the uninstaller cannot identify it safely. Close RouterChat and try again.\n' >&2
            return 1
        fi
        return 0
    }

    printf 'Stopping RouterChat.\n'
    kill "$ownedPid" 2>/dev/null || true

    attempt=0
    while [ "$attempt" -lt 30 ]; do
        if ! kill -0 "$ownedPid" 2>/dev/null; then
            rm -f "$logsDir/routerchat.pid"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    printf 'RouterChat could not be stopped safely. Close it and run the uninstaller again.\n' >&2
    return 1
}

saveUserData() {
    databasePath="$userDataDir/routerchat.sqlite3"
    if [ ! -f "$databasePath" ]; then
        printf 'No RouterChat database was found, so there is no user data to save.\n'
        return 0
    fi

    if [ ! -x "$venvPython" ]; then
        printf 'RouterChat cannot create a safe database backup because its private Python runtime is missing. Nothing was removed.\n' >&2
        return 1
    fi

    downloadsDir="$HOME/Downloads"
    mkdir -p "$downloadsDir" || return 1

    timestamp="$(date '+%Y%m%d-%H%M%S')"
    backupDir="$downloadsDir/RouterChat-user-data-$timestamp"
    suffix=1
    while [ -e "$backupDir" ]; do
        backupDir="$downloadsDir/RouterChat-user-data-$timestamp-$suffix"
        suffix=$((suffix + 1))
    done

    mkdir -m 700 "$backupDir" || return 1
    temporaryDatabase="$backupDir/routerchat.sqlite3.tmp"
    backupDatabase="$backupDir/routerchat.sqlite3"
    backupCode='import sqlite3, sys; source = sqlite3.connect(sys.argv[1]); destination = sqlite3.connect(sys.argv[2]); source.backup(destination); destination.close(); source.close()'

    if ! "$venvPython" -c "$backupCode" "$databasePath" "$temporaryDatabase"; then
        rm -rf "$backupDir"
        printf 'The RouterChat database could not be backed up. Nothing was removed.\n' >&2
        return 1
    fi

    mv "$temporaryDatabase" "$backupDatabase" || return 1
    chmod 600 "$backupDatabase" 2>/dev/null || true

    cat >"$backupDir/README-userdata.txt" <<'README'
This SQLite database contains your RouterChat chats and writing data.

To restore it, install RouterChat again, close RouterChat, then replace:
~/Library/Application Support/RouterChat/user-data/routerchat.sqlite3

with the routerchat.sqlite3 file in this folder before starting RouterChat.
The database may contain private content, so do not share it publicly.
README

    chmod 600 "$backupDir/README-userdata.txt" 2>/dev/null || true
    printf 'User data was saved to %s\n' "$backupDir"
}

if [ "$installRoot" = "/" ] || [ "$installRoot" = "$HOME" ] || [ -L "$installRoot" ]; then
    printf 'The RouterChat installation path is unsafe. Nothing was removed.\n' >&2
    exit 1
fi

if [ ! -d "$installRoot" ]; then
    printf 'RouterChat is not installed.\n'
    exit 0
fi

if ! askYesNo 'Are you sure you want to remove RouterChat'; then
    printf 'Nothing was removed.\n'
    exit 0
fi

saveData="no"
if askYesNo 'Would you like to save user data'; then
    saveData="yes"
fi

stopRouterchat || exit 1

if [ "$saveData" = "yes" ]; then
    saveUserData || exit 1
fi

rm -f "$aliasDir/Start RouterChat.command"
rm -f "$aliasDir/Update RouterChat.command"
rm -f "$aliasDir/Uninstall RouterChat.command"
rmdir "$aliasDir" 2>/dev/null || true

desktopLink="$HOME/Desktop/RouterChat"
if [ -L "$desktopLink" ] && [ "$(readlink "$desktopLink")" = "$aliasDir" ]; then
    rm -f "$desktopLink"
fi

cd "$HOME"
rm -rf "$installRoot"

if [ -e "$installRoot" ]; then
    printf 'RouterChat could not be fully removed.\n' >&2
    exit 1
fi

printf 'RouterChat has been removed.\n'
UNINSTALLER

    chmod 755 \
        "$installRoot/Start RouterChat.command" \
        "$installRoot/Update RouterChat.command" \
        "$installRoot/Uninstall RouterChat.command" || return 1
}

createAliases() {
    aliasDir="$HOME/Applications/RouterChat"
    mkdir -p "$aliasDir" 2>/dev/null || return 0

    ln -sfn "$installRoot/Start RouterChat.command" "$aliasDir/Start RouterChat.command" 2>/dev/null || true
    ln -sfn "$installRoot/Update RouterChat.command" "$aliasDir/Update RouterChat.command" 2>/dev/null || true
    ln -sfn "$installRoot/Uninstall RouterChat.command" "$aliasDir/Uninstall RouterChat.command" 2>/dev/null || true
}

createDesktopShortcut() {
    desktopLink="$HOME/Desktop/RouterChat"

    [ -z "$previousVersion" ] || return 0
    [ -d "$HOME/Desktop" ] || return 0
    [ -d "$aliasDir" ] || return 0
    [ -L "$desktopLink" ] || [ ! -e "$desktopLink" ] || return 0

    ln -sfn "$aliasDir" "$desktopLink" 2>/dev/null || true
}

ownedProcessId() {
    pidFile="$logsDir/routerchat.pid"
    [ -f "$pidFile" ] || return 1

    ownedPid="$(head -n 1 "$pidFile" | tr -dc '0-9')"
    [ -n "$ownedPid" ] || return 1
    kill -0 "$ownedPid" 2>/dev/null || return 1
    ps -o command= -p "$ownedPid" 2>/dev/null | grep -Fq "$venvDir" || return 1

    printf '%s\n' "$ownedPid"
}

stopOwnedInstance() {
    ownedPid="$(ownedProcessId)" || return 1

    kill "$ownedPid" 2>/dev/null || true

    attempt=0
    while [ "$attempt" -lt 15 ]; do
        if ! kill -0 "$ownedPid" 2>/dev/null && ! portIsBusy; then
            rm -f "$logsDir/routerchat.pid"
            rm -f "$apiSecretFile"
            return 0
        fi
        attempt=$((attempt + 1))
        pause 1
    done

    return 1
}

detectRunningInstance() {
    wasRunning="no"

    if ! routerchatIsHealthy; then
        if ! ownedProcessId >/dev/null 2>&1; then
            return 0
        fi
    fi

    wasRunning="yes"
}

stopRunningInstance() {
    detectRunningInstance
    [ "$wasRunning" = "yes" ] || return 0
    note "Stopping the running RouterChat so it can be updated safely."

    stopOwnedInstance || fail "RouterChat is running but was not started by this installation. Close it, then run the installer again."
}

launchBackend() {
    launcherCommand="$installRoot/Start RouterChat.command"
    startupLog="$logsDir/launcher-$(date -u '+%Y-%m-%d').log"

    [ -x "$launcherCommand" ] || return 1

    mkdir -p "$logsDir" "$runDir" || return 1
    chmod 700 "$runDir" || return 1

    open -a Terminal "$launcherCommand" || return 1
}

restartPreviousInstance() {
    [ "$wasRunning" = "yes" ] || return 0
    [ -x "$venvPython" ] && [ -f "$appDir/backend/main.py" ] || return 0

    if portIsBusy; then
        warn "The previous RouterChat version was restored but port $routerchatPort is busy, so it could not be restarted."
        return 0
    fi

    if ! launchBackend; then
        restoreApplication
        fail "the RouterChat backend process could not be started"
    fi

    attempt=0
    while [ "$attempt" -lt 60 ]; do
        restoredVersion="$(runningVersion)"
        if [ -n "$restoredVersion" ] && { [ -z "$previousVersion" ] || [ "$restoredVersion" = "$previousVersion" ]; }; then
            warn "Restarted the RouterChat version that was running before."
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done

    stopOwnedInstance || true
    warn "The previous RouterChat version was restored but could not be restarted. Use 'Start RouterChat.command' to try again."
}

startRouterchat() {
    note "Starting RouterChat $newVersion in its own window."

    if portIsBusy; then
        if [ -d "$previousApp" ]; then
            restoreApplication
            fail "port $routerchatPort is used by another program. The previous RouterChat version was restored."
        fi

        writeInstallMetadata
        failStart "port $routerchatPort is used by another program. Close it, then use 'Start RouterChat.command'."
    fi

    if ! launchBackend; then
        warn "RouterChat $newVersion could not create its backend process, so the previous version is being restored."
        restoreApplication
        fail "the RouterChat backend process could not be started"
    fi

    attempt=0
    while [ "$attempt" -lt 300 ]; do
        startedVersion="$(runningVersion)"
        if [ "$startedVersion" = "$newVersion" ]; then
            note "RouterChat $newVersion is ready at http://127.0.0.1:$routerchatPort"
            return 0
        fi
        attempt=$((attempt + 1))
        stepTick 4
        sleep 0.2
    done

    startupFailed
}

startupFailed() {
    if ownedProcessId >/dev/null 2>&1; then
        stopOwnedInstance || fail "the failed RouterChat process could not be stopped safely; rerun the installer"
    elif portIsBusy; then
        fail "the process on port $routerchatPort could not be identified safely; close it, then rerun the installer"
    fi

    warn "RouterChat $newVersion did not start, so the previous version is being restored."

    failedLog="$startupLog"
    restoreApplication

    fail "the new version did not start in time. The previous version was restored. See $failedLog"
}

printHeader() {
    if [ "$updateMode" = "yes" ]; then
        printTerms
        return 0
    fi

    printf '%sRouterChat installer%s\n' "$bold" "$reset"
    printTerms
    printf '%sInstalling RouterChat%s\n\n' "$bold" "$reset"
}

printEnding() {
    if [ "$updateMode" = "yes" ] || { [ -n "$previousVersion" ] && [ "$previousVersion" != "$newVersion" ]; }; then
        headline="RouterChat updated to $newVersion and running"
    else
        headline="RouterChat $newVersion is installed and running"
    fi

    startCommand="$installRoot/Start RouterChat.command"
    [ -L "$HOME/Applications/RouterChat/Start RouterChat.command" ] && startCommand="$HOME/Applications/RouterChat/Start RouterChat.command"
    [ -L "$HOME/Desktop/RouterChat" ] && [ -e "$HOME/Desktop/RouterChat/Start RouterChat.command" ] && startCommand="$HOME/Desktop/RouterChat/Start RouterChat.command"

    printf '\n%s%s✓ %s%s\n' "$green" "$bold" "$headline" "$reset"
    printf '%s  Open:   %s%shttp://127.0.0.1:%s%s\n' "$dim" "$reset" "$cyan" "$routerchatPort" "$reset"
    printf '%s  Stop:   %sClose the RouterChat window that just opened\n' "$dim" "$reset"
    printf '%s  Later:  %s%s\n' "$dim" "$reset" "$(shortPath "$startCommand")"
    printf '%s  Logs:   %s%s\n' "$dim" "$(shortPath "$logsDir")" "$reset"
    note "$headline"
}

main() {
    trap cleanup EXIT INT TERM HUP
    printHeader

    requireCommand curl
    requireCommand shasum
    requireCommand tar

    checkPlatform
    checkInstallRoot
    createDirectories
    recoverInterruptedInstallation

    workDir="$(mktemp -d "${TMPDIR:-/tmp}/routerchat-install.XXXXXX")"
    chmod 700 "$workDir"

    printf '%s' "$hideCursor"
    note "Installing RouterChat for $platformName into $installRoot"

    stepStart 1 "Downloading RouterChat${ROUTERCHAT_EXPECTED_VERSION:+ $ROUTERCHAT_EXPECTED_VERSION}"
    downloadApplication
    stepLabel 1 "Downloading RouterChat $newVersion"
    stepFinish "done" "$green" "$(megabytes "$(fileBytes "$workDir/routerchat-app.zip")")  100%"

    stepStart 2 "Setting up Python"
    installRuntime
    if [ "$runtimeWasReady" = "yes" ]; then
        stepFinish "already set up" "$dim"
    else
        stepFinish "done" "$green" "uv $uvVersion + Python $pythonVersion  100%"
    fi

    detectRunningInstance
    if [ "$wasRunning" = "yes" ]; then
        stepStart 3 "Stopping RouterChat and backing up data"
    else
        stepStart 3 "Backing up your data"
    fi
    stopRunningInstance
    if ! backupUserData; then
        restartPreviousInstance
        fail "the existing user data could not be backed up"
    fi
    if [ -n "$backupDir" ]; then
        stepFinish "done" "$green"
    else
        stepFinish "nothing to back up" "$dim"
    fi

    beginInstallTransaction || fail "the update transaction could not be started"

    stepStart 4 "Installing files"
    installApplication
    stepFinish "done" "$green"

    stepStart 5 "Installing dependencies"
    syncEnvironment
    stepFinish "done" "$green" "$packageTotal packages  100%"

    stepStart 6 "Starting RouterChat"
    if ! writeLaunchers; then
        restoreApplication
        fail "the RouterChat launcher files could not be written"
    fi
    createAliases
    createDesktopShortcut
    startRouterchat
    if ! finishInstallTransaction; then
        stopOwnedInstance || true
        restoreApplication
        fail "the update transaction could not be completed"
    fi
    if ! writeInstallMetadata; then
        stopOwnedInstance || true
        restoreApplication
        fail "install.json could not be written"
    fi
    stepFinish "done" "$green"

    discardPreviousApplication || notice "The old application cleanup will be retried during the next update."

    printEnding
}

main

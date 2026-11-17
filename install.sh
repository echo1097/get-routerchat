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
hadUsageDatabase="no"
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
    reset="$(printf '\033[0m')"
    clearLine="$(printf '\033[K')"
    lineUp="$(printf '\033[1A')"
    hideCursor="$(printf '\033[?25l')"
    showCursor="$(printf '\033[?25h')"
else
    fancy="no"
    bold="" dim="" red="" green="" yellow="" cyan="" reset="" clearLine="" lineUp="" hideCursor="" showCursor=""
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
                printf '%s' "$(megabytes "$current")"
            fi
            ;;
        growth)
            printf '%s  %s' "$progressLabel" "$(megabytes "$measuredBytes")"
            ;;
        packages)
            current="$measuredCount"
            [ "$current" -gt "$progressTotal" ] && current="$progressTotal"
            if [ "$current" -eq 0 ]; then
                downloaded="$measuredBytes"
                [ "$downloaded" -lt 0 ] && downloaded=0
                printf 'downloading packages  %s' "$(megabytes "$downloaded")"
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
    hadUsageDatabase="no"

    [ -f "$userDataDir/.env" ] && hadEnv="yes"
    [ -f "$userDataDir/routerchat.sqlite3" ] && hadDatabase="yes"
    [ -f "$userDataDir/usage.sqlite3" ] && hadUsageDatabase="yes"
    [ "$hadEnv" = "yes" ] || [ "$hadDatabase" = "yes" ] || [ "$hadUsageDatabase" = "yes" ] || [ -d "$appDir" ] || return 0

    backupDir="$backupsDir/$(date -u '+%Y%m%d-%H%M%S')-$$"
    mkdir "$backupDir" || return 1
    chmod 700 "$backupDir" 2>/dev/null || true

    if [ -f "$userDataDir/.env" ]; then
        cp "$userDataDir/.env" "$backupDir/.env" || return 1
    fi
    if [ -f "$userDataDir/routerchat.sqlite3" ]; then
        cp "$userDataDir/routerchat.sqlite3" "$backupDir/routerchat.sqlite3" || return 1
    fi
    if [ -f "$userDataDir/usage.sqlite3" ]; then
        cp "$userDataDir/usage.sqlite3" "$backupDir/usage.sqlite3" || return 1
    fi

    note "Saved a backup of your existing RouterChat data."
    trimBackups
}

restoreUserData() {
    [ -n "$backupDir" ] && [ -d "$backupDir" ] || return 0

    rm -f "$userDataDir/routerchat.sqlite3-wal" "$userDataDir/routerchat.sqlite3-shm"
    rm -f "$userDataDir/usage.sqlite3-wal" "$userDataDir/usage.sqlite3-shm" "$userDataDir/usage.sqlite3-journal"

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

    if [ "$hadUsageDatabase" = "yes" ]; then
        cp "$backupDir/usage.sqlite3" "$userDataDir/usage.sqlite3.restore"
        mv "$userDataDir/usage.sqlite3.restore" "$userDataDir/usage.sqlite3"
    else
        rm -f "$userDataDir/usage.sqlite3"
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
    hadUsageDatabase="no"
    [ -f "$backupDir/.env" ] && hadEnv="yes"
    [ -f "$backupDir/routerchat.sqlite3" ] && hadDatabase="yes"
    [ -f "$backupDir/usage.sqlite3" ] && hadUsageDatabase="yes"
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

    usageDatabasePath="$userDataDir/usage.sqlite3"
    if [ -f "$usageDatabasePath" ]; then
        temporaryUsageDatabase="$backupDir/usage.sqlite3.tmp"
        backupUsageDatabase="$backupDir/usage.sqlite3"

        if ! "$venvPython" -c "$backupCode" "$usageDatabasePath" "$temporaryUsageDatabase"; then
            rm -rf "$backupDir"
            printf 'The RouterChat usage history could not be backed up. Nothing was removed.\n' >&2
            return 1
        fi

        mv "$temporaryUsageDatabase" "$backupUsageDatabase" || return 1
        chmod 600 "$backupUsageDatabase" 2>/dev/null || true
    fi

    cat >"$backupDir/README-userdata.txt" <<'README'
This folder contains your RouterChat data:
- routerchat.sqlite3 holds your chats and writing.
- usage.sqlite3 holds your usage and cost history.

To restore it, install RouterChat again, close RouterChat, then replace
the files with the same names in:
~/Library/Application Support/RouterChat/user-data/

with the files in this folder before starting RouterChat.
These files may contain private content, so do not share them publicly.
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

playLogoSwirl() {
    [ -t 1 ] || return 0
    [ "${TERM:-dumb}" != "dumb" ] || return 0

    swirlSize="$( (stty size </dev/tty) 2>/dev/null || true)"
    swirlRows="${swirlSize%% *}"
    swirlCols="${swirlSize##* }"

    case "$swirlRows$swirlCols" in
        ""|*[!0-9]*)
            swirlRows="$(tput lines 2>/dev/null || echo 24)"
            swirlCols="$(tput cols 2>/dev/null || echo 80)"
            ;;
    esac

    (
        trap 'printf "\033[?25h\033[0m"' EXIT
        trap 'exit 130' INT TERM
        printf '\033[?25l'

        LC_ALL=C awk -v termCols="$swirlCols" -v termRows="$swirlRows" '
function smaller(a, b) {
    return a < b ? a : b
}

function hasInk(sourceX, sourceY,    span) {
    for (span = 1; span < spanCount[sourceY]; span += 2) {
        if (sourceX >= spans[sourceY, span] && sourceX <= spans[sourceY, span + 1]) return 1
    }

    return 0
}

function fitToTerminal(    scale, logoCellRows) {
    scale = smaller(maxLogoDots / sourceWide, (termCols - 1) * 2 * logoShare / sourceWide)
    scale = smaller(scale, (termRows - 1 - marginRows * 2) * 4 / sourceHigh)

    logoWide = int(sourceWide * scale)
    logoHigh = int(sourceHigh * scale)

    if (logoWide < minLogoDots) return 0

    logoCellRows = int((logoHigh + 3) / 4)
    canvasRows = logoCellRows + marginRows * 2
    canvasCols = smaller(termCols - 1, int(logoWide / 2 / logoShare + 0.5))
    dotsWide = canvasCols * 2
    dotsHigh = canvasRows * 4
    wordmarkRow = canvasRows - 2

    offsetX = int((dotsWide - logoWide) / 2)
    offsetY = marginRows * 4
    centerX = offsetX + logoWide / 2
    centerY = offsetY + logoHigh / 2
    pushOut = logoWide * 0.14

    leftPad = sprintf("%" int((termCols - canvasCols) / 2) "s", "")
    wordmarkText = sprintf("%" int((canvasCols - length(wordmark)) / 2) "s%s", "", wordmark)

    return 1
}

function buildParticles(    x, y, dx, dy, distance, farthest, i) {
    farthest = 1

    for (y = 0; y < logoHigh; y++) {
        for (x = 0; x < logoWide; x++) {
            if (!hasInk(int((x + 0.5) * sourceWide / logoWide), int((y + 0.5) * sourceHigh / logoHigh) + 1)) continue

            dx = x + offsetX - centerX
            dy = y + offsetY - centerY
            distance = sqrt(dx * dx + dy * dy)

            particleCount++
            homeX[particleCount] = dx
            homeY[particleCount] = dy
            unitX[particleCount] = distance > 0 ? dx / distance : 0
            unitY[particleCount] = distance > 0 ? dy / distance : 0
            reach[particleCount] = distance

            if (distance > farthest) farthest = distance
        }
    }

    for (i = 1; i <= particleCount; i++) {
        delay[i] = maxDelay * reach[i] / farthest + rand() * maxJitter
    }
}

function buildMotionTable(    step, progress, settled, remaining, turn) {
    for (step = 0; step <= motionSteps; step++) {
        progress = step / motionSteps
        settled = 1 - (1 - progress) ^ 3
        remaining = 1 - settled
        turn = swirlTurns * 6.2831853 * remaining ^ 1.4

        stepSettled[step] = settled
        stepGrow[step] = 1 + spreadAmount * remaining
        stepPush[step] = pushOut * remaining
        stepCos[step] = cos(turn)
        stepSin[step] = sin(turn)
    }
}

function buildFrame(swirlProgress,    i, progress, step, pullX, pullY, x, y, key) {
    split("", cellBits)
    split("", cellSettled)
    split("", cellCount)
    split("", dotSeen)

    for (i = 1; i <= particleCount; i++) {
        progress = (swirlProgress - delay[i]) / flightSpan

        if (progress <= 0) continue
        if (progress > 1) progress = 1

        step = int(progress * motionSteps)
        pullX = stepGrow[step] * homeX[i] + stepPush[step] * unitX[i]
        pullY = stepGrow[step] * homeY[i] + stepPush[step] * unitY[i]

        x = int(centerX + pullX * stepCos[step] + pullY * stepSin[step] + 0.5)
        y = int(centerY + pullY * stepCos[step] - pullX * stepSin[step] + 0.5)

        if (x < 0 || y < 0 || x >= dotsWide || y >= dotsHigh) continue

        key = int(x / 2) "," int(y / 4)
        cellSettled[key] += stepSettled[step]
        cellCount[key]++

        if ((x, y) in dotSeen) continue

        dotSeen[x, y] = 1
        cellBits[key] += dotBit[y % 4, x % 2]
    }
}

function cellColor(col, row, key, shineProgress,    level, position, glow) {
    if (shineProgress >= 0) {
        position = (col + row * 2) / (canvasCols + canvasRows * 2)
        glow = exp(-((position - (-0.2 + 1.4 * shineProgress)) / 0.09) ^ 2)

        if (glow > 0.6) return 231
        if (glow > 0.25) return 255
        return restColor
    }

    level = cellSettled[key] / cellCount[key]
    return flightRamp[int(level * level * 8 + 0.5) + 1]
}

function drawFrame(shineProgress, wordmarkLevel,    row, col, key, color, lastColor, out) {
    out = frameNumber > 0 ? "\033[" canvasRows "A" : ""

    for (row = 0; row < canvasRows; row++) {
        out = out "\r" leftPad

        if (row == wordmarkRow && wordmarkLevel > 0) {
            out = out "\033[38;5;" wordmarkRamp[wordmarkLevel] "m" wordmarkText "\033[0m\033[K\n"
            continue
        }

        lastColor = -1

        for (col = 0; col < canvasCols; col++) {
            key = col "," row

            if (!(key in cellBits)) {
                out = out " "
                continue
            }

            color = cellColor(col, row, key, shineProgress)

            if (color != lastColor) {
                out = out "\033[38;5;" color "m"
                lastColor = color
            }

            out = out braille[cellBits[key]]
        }

        out = out "\033[0m\033[K\n"
    }

    printf "%s", out
    fflush()
    system("sleep " framePause)
    frameNumber++
}

BEGIN {
    maxLogoDots = 132
    minLogoDots = 40
    logoShare = 0.69
    marginRows = 3
    wordmark = "R O U T E R C H A T"

    swirlFrames = 38
    shineFrames = 14
    swirlTurns = 0.85
    spreadAmount = 1.5
    maxDelay = 0.45
    maxJitter = 0.08
    flightSpan = 1 - maxDelay - maxJitter
    motionSteps = 240
    restColor = 252

    split("60 61 62 63 69 111 147 189 252", flightRamp, " ")
    split("238 241 244 246", wordmarkRamp, " ")

    dotBit[0, 0] = 1;  dotBit[0, 1] = 8
    dotBit[1, 0] = 2;  dotBit[1, 1] = 16
    dotBit[2, 0] = 4;  dotBit[2, 1] = 32
    dotBit[3, 0] = 64; dotBit[3, 1] = 128

    for (bits = 0; bits < 256; bits++) {
        braille[bits] = sprintf("%c%c%c", 226, 160 + int(bits / 64), 128 + bits % 64)
    }

    srand(7)
}

{
    spanCount[NR] = split($0, rowSpans, " ")

    for (span = 1; span <= spanCount[NR]; span++) {
        spans[NR, span] = rowSpans[span]

        if (rowSpans[span] + 1 > sourceWide) sourceWide = rowSpans[span] + 1
    }
}

END {
    sourceHigh = NR

    if (!fitToTerminal()) exit

    buildParticles()
    buildMotionTable()

    framePause = 0.034 - particleCount * 0.0000025
    if (framePause < 0.004) framePause = 0.004

    for (frame = 1; frame <= swirlFrames; frame++) {
        buildFrame(frame / swirlFrames)
        drawFrame(-1, 0)
    }

    for (frame = 1; frame <= shineFrames; frame++) {
        wordmarkLevel = int(frame / shineFrames * 6)
        if (wordmarkLevel > 4) wordmarkLevel = 4

        drawFrame(frame / shineFrames, wordmarkLevel)
    }

    drawFrame(2, 4)
}
' <<'LOGO'

17 70 121 173
16 74 117 174
15 76 114 174
14 78 111 174
13 80 109 174
12 82 107 174
11 83 106 174
10 84 104 174
10 85 103 174
9 87 101 174
8 88 100 174
7 88 99 174
6 89 98 174
5 90 97 174
4 91 96 174
3 91 95 174
3 92 95 174
2 174
1 174
1 174
1 174
1 173
3 171
69 123
71 120
72 118
73 116
74 115
74 114
75 113
75 112
75 111
75 110
76 109
75 109
75 108
75 108
75 107
74 107
74 106
73 106
72 106
71 106
69 106
66 106
9 105
8 105
8 105
8 105
8 106
8 106
8 106
8 106
8 106
8 107
8 107
8 108
8 108
8 108
8 83 86 109
8 81 86 110
8 79 87 111
8 77 87 111
8 74 87 112
8 72 88 114
8 73 88 115
8 33 37 75 89 116
8 33 38 76 89 118
8 33 39 77 90 120
8 33 41 79 90 123
8 33 42 80 91 171
8 33 43 81 91 173
8 33 45 83 92 173
8 33 46 84 93 174
8 33 47 85 93 174
8 33 48 86 94 174
8 33 49 88 95 174
8 33 51 89 96 174
8 33 52 90 97 174
8 33 53 92 98 174
8 33 55 93 99 174
8 33 56 95 100 174
8 33 57 96 101 174
8 33 58 97 103 174
8 33 60 98 104 174
8 33 61 100 106 174
8 33 62 101 107 174
8 33 64 102 109 174
8 33 65 104 111 174
8 33 66 105 113 174
8 32 68 105 115 174
8 32 69 105 118 173
9 31 71 104 122 172

LOGO
    ) || true
}

printHeader() {
    if [ "$updateMode" = "yes" ]; then
        printTerms
        return 0
    fi

    playLogoSwirl
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

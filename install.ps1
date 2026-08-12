$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$appRepo = 'echo1097/routerchat'
$appZipUrl = "https://github.com/$appRepo/releases/latest/download/routerchat-app.zip"
$appChecksumUrl = "https://github.com/$appRepo/releases/latest/download/routerchat-app.zip.sha256"
$uvVersion = '0.7.19'
$pythonVersion = '3.13'
$routerchatPort = 8000
$routerchatUrl = "http://127.0.0.1:$routerchatPort"
$keptBackups = 3

$installRoot = Join-Path $env:LOCALAPPDATA 'RouterChat'
$appDir = Join-Path $installRoot 'app'
$previousApp = Join-Path $installRoot 'app.previous'
$transactionPath = Join-Path $installRoot 'install.transaction'
$runtimeDir = Join-Path $installRoot 'runtime'
$userDataDir = Join-Path $installRoot 'user-data'
$backupsDir = Join-Path $installRoot 'backups'
$logsDir = Join-Path $installRoot 'logs'
$venvDir = Join-Path $runtimeDir '.venv'
$venvPython = Join-Path $venvDir 'Scripts\python.exe'
$uvBin = Join-Path $runtimeDir 'tools\uv.exe'

$script:logFile = $null
$script:workDir = $null
$script:installFailed = $false
$script:startFailed = $false
$script:wasRunning = $false
$script:startupLog = $null
$script:backupDir = $null
$script:hadEnv = $false
$script:hadDatabase = $false
$script:previousVersion = $null
$script:transactionStarted = $false

function Write-Step {
    param([string] $Message)

    Write-Host $Message

    if ($script:logFile) {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Add-Content -LiteralPath $script:logFile -Value "$stamp $Message" -Encoding utf8
    }
}

function Test-SupportedPlatform {
    if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
        throw 'This installer only supports Windows.'
    }

    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) {
        $architecture = $env:PROCESSOR_ARCHITEW6432
    }

    if ($architecture -ne 'AMD64') {
        throw "The processor type '$architecture' is not supported yet. Only Windows x64 is supported."
    }

    return 'windows-x64'
}

function Test-InstallRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'The Local AppData folder could not be found.'
    }

    $rootPath = [System.IO.Path]::GetFullPath($installRoot)
    $localAppData = [System.IO.Path]::GetFullPath($env:LOCALAPPDATA)

    if ($rootPath -eq $localAppData -or $rootPath -eq [System.IO.Path]::GetPathRoot($rootPath)) {
        throw 'The installation path is unsafe.'
    }

    if (-not $rootPath.StartsWith($localAppData, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installation path must live inside your Local AppData folder.'
    }
}

function New-InstallDirectories {
    foreach ($directory in @($installRoot, $runtimeDir, $userDataDir, $backupsDir, $logsDir)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $script:logFile = Join-Path $logsDir "install-$today.log"

    if (-not (Test-Path -LiteralPath $script:logFile)) {
        New-Item -ItemType File -Path $script:logFile -Force | Out-Null
    }
}

function Get-RemoteFile {
    param([string] $Url, [string] $Destination)

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -MaximumRedirection 5
    }
    catch {
        throw "Could not download $Url"
    }
}

function Confirm-Checksum {
    param([string] $FilePath, [string] $ChecksumPath)

    $firstLine = (Get-Content -LiteralPath $ChecksumPath -TotalCount 1).Trim()
    $expectedSum = ($firstLine -split '\s+')[0]

    if ($expectedSum -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The published checksum could not be read.'
    }

    $actualSum = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash

    if ($expectedSum -ne $actualSum) {
        throw 'A downloaded file did not match its published checksum.'
    }
}

function Get-RouterchatPackage {
    Write-Step 'Downloading RouterChat.'

    $zipPath = Join-Path $script:workDir 'routerchat-app.zip'
    $checksumPath = "$zipPath.sha256"

    Get-RemoteFile -Url $appZipUrl -Destination $zipPath
    Get-RemoteFile -Url $appChecksumUrl -Destination $checksumPath
    Confirm-Checksum -FilePath $zipPath -ChecksumPath $checksumPath

    if ($env:ROUTERCHAT_EXPECTED_APP_SHA256) {
        $downloadedSum = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($downloadedSum -ne $env:ROUTERCHAT_EXPECTED_APP_SHA256) {
            throw 'The latest release changed after the updater validated it. Run the update again.'
        }
    }

    $stageDir = Join-Path $script:workDir 'app'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $stageDir -Force

    foreach ($requiredPath in @('backend\main.py', 'dist\index.html', 'requirements.lock', 'version.json', 'TOS.md', 'LICENSE')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stageDir $requiredPath))) {
            throw "The downloaded package is missing $requiredPath"
        }
    }

    $metadata = Get-Content -LiteralPath (Join-Path $stageDir 'version.json') -Raw | ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace($metadata.version)) {
        throw 'The downloaded package has no readable version.'
    }

    if ($env:ROUTERCHAT_EXPECTED_VERSION -and $metadata.version -ne $env:ROUTERCHAT_EXPECTED_VERSION) {
        throw 'The latest release version changed after the updater validated it. Run the update again.'
    }

    return $metadata.version
}

function Install-PrivateRuntime {
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $runtimeDir 'python'
    $env:UV_CACHE_DIR = Join-Path $runtimeDir 'cache'
    $env:UV_NO_MODIFY_PATH = '1'

    if (-not (Test-Path -LiteralPath $uvBin)) {
        Write-Step "Setting up RouterChat's private Python runtime."

        $uvArchive = 'uv-x86_64-pc-windows-msvc.zip'
        $uvBaseUrl = "https://github.com/astral-sh/uv/releases/download/$uvVersion"
        $archivePath = Join-Path $script:workDir $uvArchive

        Get-RemoteFile -Url "$uvBaseUrl/$uvArchive" -Destination $archivePath
        Get-RemoteFile -Url "$uvBaseUrl/$uvArchive.sha256" -Destination "$archivePath.sha256"
        Confirm-Checksum -FilePath $archivePath -ChecksumPath "$archivePath.sha256"

        $uvStageDir = Join-Path $script:workDir 'uv'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $uvStageDir -Force

        $extractedUv = Get-ChildItem -LiteralPath $uvStageDir -Filter 'uv.exe' -Recurse | Select-Object -First 1
        if (-not $extractedUv) {
            throw 'The private runtime tool was not found in its archive.'
        }

        New-Item -ItemType Directory -Path (Split-Path -Parent $uvBin) -Force | Out-Null
        Copy-Item -LiteralPath $extractedUv.FullName -Destination $uvBin -Force
    }

    Invoke-PrivateTool -Arguments @('python', 'install', $pythonVersion) -FailureMessage 'The private Python runtime could not be installed.'
}

function Invoke-PrivateTool {
    param([string[]] $Arguments, [string] $FailureMessage)

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        $output = & $uvBin @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($output) {
        Add-Content -LiteralPath $script:logFile -Value ($output | Out-String) -Encoding utf8
    }

    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

function Sync-PrivateEnvironment {
    if (-not (Test-Path -LiteralPath $venvPython)) {
        Write-Step "Creating RouterChat's private environment."

        if (Test-Path -LiteralPath $venvDir) {
            Remove-Item -LiteralPath $venvDir -Recurse -Force
        }

        try {
            Invoke-PrivateTool `
                -Arguments @('venv', '--python', $pythonVersion, '--managed-python', $venvDir) `
                -FailureMessage 'The private environment could not be created.'
        }
        catch {
            $failure = $_
            Restore-Application
            throw $failure
        }
    }

    Write-Step "Installing RouterChat's dependencies."

    try {
        Invoke-PrivateTool `
            -Arguments @('pip', 'sync', '--python', $venvPython, (Join-Path $appDir 'requirements.lock')) `
            -FailureMessage 'The RouterChat dependencies could not be installed.'
    }
    catch {
        $failure = $_
        Restore-Application
        throw $failure
    }
}

function Backup-UserData {
    $databasePath = Join-Path $userDataDir 'routerchat.sqlite3'
    $envPath = Join-Path $userDataDir '.env'

    $script:backupDir = $null
    $script:hadEnv = Test-Path -LiteralPath $envPath
    $script:hadDatabase = Test-Path -LiteralPath $databasePath

    if (-not $script:hadDatabase -and -not $script:hadEnv -and -not (Test-Path -LiteralPath $appDir)) {
        return
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + "-$PID"
    $script:backupDir = Join-Path $backupsDir $stamp
    New-Item -ItemType Directory -Path $script:backupDir | Out-Null

    foreach ($sourcePath in @($envPath, $databasePath)) {
        if (Test-Path -LiteralPath $sourcePath) {
            Copy-Item -LiteralPath $sourcePath -Destination $script:backupDir -Force
        }
    }

    Write-Step 'Saved a backup of your existing RouterChat data.'

    Get-ChildItem -LiteralPath $backupsDir -Directory |
        Where-Object { $_.Name -match '^\d{8}-\d{6}(?:-\d+)?$' } |
        Sort-Object Name -Descending |
        Select-Object -Skip $keptBackups |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
}

function Restore-UserData {
    if (-not $script:backupDir -or -not (Test-Path -LiteralPath $script:backupDir)) {
        return
    }

    $databasePath = Join-Path $userDataDir 'routerchat.sqlite3'
    $envPath = Join-Path $userDataDir '.env'

    foreach ($sidecarPath in @("$databasePath-wal", "$databasePath-shm")) {
        Remove-Item -LiteralPath $sidecarPath -Force -ErrorAction SilentlyContinue
    }

    if ($script:hadEnv) {
        $temporaryEnv = "$envPath.restore"
        Copy-Item -LiteralPath (Join-Path $script:backupDir '.env') -Destination $temporaryEnv -Force
        Move-Item -LiteralPath $temporaryEnv -Destination $envPath -Force
    }
    else {
        Remove-Item -LiteralPath $envPath -Force -ErrorAction SilentlyContinue
    }

    if ($script:hadDatabase) {
        $temporaryDatabase = "$databasePath.restore"
        Copy-Item -LiteralPath (Join-Path $script:backupDir 'routerchat.sqlite3') -Destination $temporaryDatabase -Force
        Move-Item -LiteralPath $temporaryDatabase -Destination $databasePath -Force
    }
    else {
        Remove-Item -LiteralPath $databasePath -Force -ErrorAction SilentlyContinue
    }

    Write-Step 'Restored the previous RouterChat user data.'
}

function Set-LatestBackupSnapshot {
    $latestBackup = Get-ChildItem -LiteralPath $backupsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}-\d{6}(?:-\d+)?$' } |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if (-not $latestBackup) {
        return $false
    }

    $script:backupDir = $latestBackup.FullName
    $script:hadEnv = Test-Path -LiteralPath (Join-Path $script:backupDir '.env')
    $script:hadDatabase = Test-Path -LiteralPath (Join-Path $script:backupDir 'routerchat.sqlite3')
    return $true
}

function Get-FileVersion {
    param([string] $VersionPath)

    if (-not (Test-Path -LiteralPath $VersionPath)) {
        return $null
    }

    try {
        return [string] ((Get-Content -LiteralPath $VersionPath -Raw | ConvertFrom-Json).version)
    }
    catch {
        return $null
    }
}

function Restore-InterruptedUserData {
    if (Set-LatestBackupSnapshot) {
        Restore-UserData
    }
}

function Repair-InterruptedInstallation {
    if (-not (Test-Path -LiteralPath $previousApp)) {
        Remove-Item -LiteralPath $transactionPath -Force -ErrorAction SilentlyContinue
        return
    }

    if (-not (Test-Path -LiteralPath $appDir)) {
        Restore-InterruptedUserData
        Move-Item -LiteralPath $previousApp -Destination $appDir -Force
        Remove-Item -LiteralPath $transactionPath -Force -ErrorAction SilentlyContinue
        Write-Step 'Recovered the previous RouterChat version after an interrupted update.'
        return
    }

    if (Test-Path -LiteralPath $transactionPath) {
        Restore-InterruptedUserData
        Remove-Item -LiteralPath $appDir -Recurse -Force
        Move-Item -LiteralPath $previousApp -Destination $appDir -Force
        Remove-Item -LiteralPath $transactionPath -Force -ErrorAction SilentlyContinue
        Write-Step 'Rolled back an interrupted RouterChat update.'
        return
    }

    $appVersion = Get-FileVersion (Join-Path $appDir 'version.json')
    $metadataVersion = $null
    $metadataPath = Join-Path $installRoot 'install.json'
    if (Test-Path -LiteralPath $metadataPath) {
        try {
            $metadataVersion = [string] ((Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json).installedVersion)
        }
        catch {
            $metadataVersion = $null
        }
    }

    if ($appVersion -and $appVersion -eq $metadataVersion) {
        Remove-Item -LiteralPath $previousApp -Recurse -Force
        Write-Step 'Finished cleanup from the previous RouterChat update.'
        return
    }

    Restore-InterruptedUserData
    Remove-Item -LiteralPath $appDir -Recurse -Force
    Move-Item -LiteralPath $previousApp -Destination $appDir -Force
    Write-Step 'Rolled back an interrupted RouterChat update.'
}

function Install-Application {
    param([string] $Version)

    Write-Step "Installing RouterChat $Version."

    $stageDir = Join-Path $script:workDir 'app'

    if (-not (Test-Path -LiteralPath $appDir) -and (Test-Path -LiteralPath $previousApp)) {
        Move-Item -LiteralPath $previousApp -Destination $appDir -Force
    }

    $script:previousVersion = $null
    $previousVersionPath = Join-Path $appDir 'version.json'
    if (Test-Path -LiteralPath $previousVersionPath) {
        try {
            $script:previousVersion = [string] ((Get-Content -LiteralPath $previousVersionPath -Raw | ConvertFrom-Json).version)
        }
        catch {
            $script:previousVersion = $null
        }
    }

    if (Test-Path -LiteralPath $previousApp) {
        Remove-Item -LiteralPath $previousApp -Recurse -Force
    }

    if (Test-Path -LiteralPath $appDir) {
        Move-Item -LiteralPath $appDir -Destination $previousApp -Force
    }

    try {
        Move-Item -LiteralPath $stageDir -Destination $appDir -Force
    }
    catch {
        try {
            Copy-Item -LiteralPath $stageDir -Destination $appDir -Recurse -Force
        }
        catch {
            Restore-Application
            throw 'The new RouterChat files could not be installed.'
        }
    }
}

function Restore-Application {
    if (-not (Test-Path -LiteralPath $previousApp)) {
        return
    }

    if (Test-Path -LiteralPath $appDir) {
        Remove-Item -LiteralPath $appDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Move-Item -LiteralPath $previousApp -Destination $appDir -Force
    Restore-UserData
    Remove-Item -LiteralPath $transactionPath -Force -ErrorAction SilentlyContinue
    Write-Step 'Restored the previous RouterChat application files.'

    $restoredLock = Join-Path $appDir 'requirements.lock'
    if ((Test-Path -LiteralPath $venvPython) -and (Test-Path -LiteralPath $restoredLock)) {
        try {
            Invoke-PrivateTool `
                -Arguments @('pip', 'sync', '--python', $venvPython, $restoredLock) `
                -FailureMessage 'The previous dependencies could not be restored.'
        }
        catch {
            Write-Step 'The previous dependencies could not be restored. Rerun the installer to repair RouterChat.'
        }
    }

    Restart-PreviousInstance
}

function Remove-PreviousApplication {
    if (Test-Path -LiteralPath $previousApp) {
        Remove-Item -LiteralPath $previousApp -Recurse -Force
    }
}

function Start-InstallTransaction {
    Set-Content -LiteralPath $transactionPath -Value $script:newVersion -Encoding ascii
}

function Complete-InstallTransaction {
    Remove-Item -LiteralPath $transactionPath -Force
}

function Write-InstallMetadata {
    param([string] $Version, [string] $Platform)

    $metadataPath = Join-Path $installRoot 'install.json'
    $updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $installedAt = $updatedAt

    if (Test-Path -LiteralPath $metadataPath) {
        try {
            $existing = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            if ($existing.installedAt) {
                $installedAt = $existing.installedAt
            }
        }
        catch {
            $installedAt = $updatedAt
        }
    }

    $metadata = [ordered] @{
        schemaVersion = 1
        installedVersion = $Version
        installedAt = $installedAt
        updatedAt = $updatedAt
        platform = $Platform
        appDirectory = 'app'
        runtimeDirectory = 'runtime'
        userDataDirectory = 'user-data'
    }

    $temporaryPath = "$metadataPath.tmp"
    $withoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporaryPath, ($metadata | ConvertTo-Json), $withoutBom)
    Move-Item -LiteralPath $temporaryPath -Destination $metadataPath -Force
}

function Write-Launchers {
    $startScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$installRoot = $PSScriptRoot
$appDir = Join-Path $installRoot 'app'
$venvPython = Join-Path $installRoot 'runtime\.venv\Scripts\python.exe'
$userDataDir = Join-Path $installRoot 'user-data'
$logsDir = Join-Path $installRoot 'logs'
$routerchatPort = 8000
$routerchatUrl = "http://127.0.0.1:$routerchatPort"

function Test-RouterchatHealthy {
    try {
        $response = Invoke-RestMethod -Uri "$routerchatUrl/api/health" -TimeoutSec 2 -UseBasicParsing
        return [bool] $response.ok
    }
    catch {
        return $false
    }
}

function Test-PortBusy {
    try {
        $listener = Get-NetTCPConnection -LocalPort $routerchatPort -State Listen -ErrorAction Stop
        return [bool] $listener
    }
    catch [System.Management.Automation.CommandNotFoundException] {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $connected = $client.ConnectAsync('127.0.0.1', $routerchatPort).Wait(1000)
            $client.Close()
            return $connected
        }
        catch {
            return $false
        }
    }
    catch {
        return $false
    }
}

foreach ($requiredPath in @((Join-Path $appDir 'backend\main.py'), (Join-Path $appDir 'dist\index.html'), $venvPython)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        Write-Host 'RouterChat is not installed correctly. Rerun the installer to repair it.'
        Write-Host "Missing: $requiredPath"
        exit 1
    }
}

New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null

$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd-HHmmss')
$logFile = Join-Path $logsDir "launcher-$stamp.log"

if (Test-RouterchatHealthy) {
    Write-Host 'RouterChat is already running. Opening it in your browser.'
    try {
        Start-Process $routerchatUrl
    }
    catch {
        Write-Host "RouterChat is ready at $routerchatUrl, but the browser could not be opened automatically."
    }
    exit 0
}

if (Test-PortBusy) {
    Write-Host "Port $routerchatPort is used by another program, so RouterChat cannot start."
    Write-Host 'Close that program and start RouterChat again.'
    exit 1
}

$env:ROUTERCHAT_USER_DATA_DIR = $userDataDir
Set-Location -LiteralPath $appDir

$server = Start-Process -FilePath $venvPython `
    -ArgumentList @('-m', 'uvicorn', 'backend.main:app', '--host', '127.0.0.1', '--port', "$routerchatPort") `
    -WorkingDirectory $appDir `
    -RedirectStandardOutput $logFile `
    -RedirectStandardError "$logFile.error" `
    -NoNewWindow `
    -PassThru

try {
    Set-Content -LiteralPath (Join-Path $logsDir 'routerchat.pid') -Value $server.Id -Encoding utf8
}
catch {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    throw
}

Write-Host 'Starting RouterChat.'
$ready = $false

for ($attempt = 0; $attempt -lt 60; $attempt++) {
    if (Test-RouterchatHealthy) {
        $ready = $true
        break
    }
    if ($server.HasExited) {
        break
    }
    Start-Sleep -Seconds 1
}

if (-not $ready) {
    Write-Host "RouterChat did not start. See $logFile"
    if (-not $server.HasExited) {
        Stop-Process -Id $server.Id -Force
    }
    Read-Host 'Press Enter to close this window'
    exit 1
}

try {
    Start-Process $routerchatUrl
}
catch {
    Write-Host "RouterChat is ready at $routerchatUrl, but the browser could not be opened automatically."
}

Write-Host "RouterChat is running at $routerchatUrl"
Write-Host 'Closing this window stops RouterChat.'

try {
    Wait-Process -Id $server.Id
}
finally {
    if (-not $server.HasExited) {
        Stop-Process -Id $server.Id -Force
    }
    Remove-Item -LiteralPath (Join-Path $logsDir 'routerchat.pid') -Force -ErrorAction SilentlyContinue
}
'@

    $updateScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host 'Checking for a newer version of RouterChat.'

$updateUrl = 'https://echo1097.github.io/get-routerchat/updater/update.ps1'
$checksumsUrl = 'https://echo1097.github.io/get-routerchat/updater/checksums.txt'
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("routerchat-updater-bootstrap-" + [System.Guid]::NewGuid().ToString('N'))
$exitCode = 1

try {
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $updatePath = Join-Path $workDir 'update.ps1'
    $checksumsPath = Join-Path $workDir 'checksums.txt'

    Invoke-WebRequest -Uri $updateUrl -OutFile $updatePath -UseBasicParsing -MaximumRedirection 5
    Invoke-WebRequest -Uri $checksumsUrl -OutFile $checksumsPath -UseBasicParsing -MaximumRedirection 5

    $checksumLine = Get-Content -LiteralPath $checksumsPath | Where-Object { $_ -match '\supdate\.ps1$' } | Select-Object -First 1
    $expectedSum = ($checksumLine -split '\s+')[0]
    $actualSum = (Get-FileHash -LiteralPath $updatePath -Algorithm SHA256).Hash

    if ($expectedSum -notmatch '^[0-9a-fA-F]{64}$' -or $expectedSum -ne $actualSum) {
        throw 'RouterChat could not verify the updater, so nothing was changed.'
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $updatePath -InstallRoot $PSScriptRoot
    $exitCode = $LASTEXITCODE
}
catch {
    Write-Host "RouterChat could not be updated: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Read-Host 'Press Enter to close this window'
exit $exitCode
'@

    $startCommand = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-routerchat.ps1"
'@

    $updateCommand = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-routerchat.ps1"
'@

    Set-Content -LiteralPath (Join-Path $installRoot 'start-routerchat.ps1') -Value $startScript -Encoding utf8
    Set-Content -LiteralPath (Join-Path $installRoot 'update-routerchat.ps1') -Value $updateScript -Encoding utf8
    Set-Content -LiteralPath (Join-Path $installRoot 'Start RouterChat.cmd') -Value $startCommand -Encoding ascii
    Set-Content -LiteralPath (Join-Path $installRoot 'Update RouterChat.cmd') -Value $updateCommand -Encoding ascii
}

function New-StartMenuShortcuts {
    try {
        $startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\RouterChat'
        New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null

        $shell = New-Object -ComObject WScript.Shell

        $startShortcut = $shell.CreateShortcut((Join-Path $startMenuDir 'RouterChat.lnk'))
        $startShortcut.TargetPath = Join-Path $installRoot 'Start RouterChat.cmd'
        $startShortcut.WorkingDirectory = $installRoot
        $startShortcut.Description = 'Start RouterChat'
        $startShortcut.Save()

        $updateShortcut = $shell.CreateShortcut((Join-Path $startMenuDir 'Update RouterChat.lnk'))
        $updateShortcut.TargetPath = Join-Path $installRoot 'Update RouterChat.cmd'
        $updateShortcut.WorkingDirectory = $installRoot
        $updateShortcut.Description = 'Update RouterChat'
        $updateShortcut.Save()
    }
    catch {
        Write-Step 'Start Menu shortcuts could not be created. The launcher files still work.'
    }
}

function Get-RunningVersion {
    try {
        $response = Invoke-RestMethod -Uri "$routerchatUrl/api/health" -TimeoutSec 2 -UseBasicParsing
        if ($response.ok) {
            return [string] $response.version
        }
    }
    catch {
    }

    return $null
}

function Test-PortInUse {
    try {
        return [bool] (Get-NetTCPConnection -LocalPort $routerchatPort -State Listen -ErrorAction Stop)
    }
    catch {
        return $false
    }
}

function Get-OwnedProcess {
    $pidFile = Join-Path $logsDir 'routerchat.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) {
        return $null
    }

    $recordedLine = Get-Content -LiteralPath $pidFile -TotalCount 1
    if ([string]::IsNullOrWhiteSpace($recordedLine)) {
        return $null
    }

    $recordedId = 0
    if (-not [int]::TryParse($recordedLine.Trim(), [ref] $recordedId)) {
        return $null
    }

    $process = Get-Process -Id $recordedId -ErrorAction SilentlyContinue
    if (-not $process) {
        return $null
    }

    try {
        $details = Get-CimInstance Win32_Process -Filter "ProcessId = $recordedId" -ErrorAction Stop
        if (-not $details.CommandLine -or -not $details.CommandLine.Contains($venvDir)) {
            return $null
        }
    }
    catch {
        return $null
    }

    return $process
}

function Stop-OwnedInstance {
    $process = Get-OwnedProcess
    if (-not $process) {
        return $false
    }

    Stop-Process -Id $process.Id -ErrorAction SilentlyContinue

    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        if ($process.HasExited -and -not (Test-PortInUse)) {
            Remove-Item -LiteralPath (Join-Path $logsDir 'routerchat.pid') -Force -ErrorAction SilentlyContinue
            return $true
        }
        Start-Sleep -Seconds 1
    }

    return $false
}

function Stop-RunningInstance {
    $script:wasRunning = $false

    $runningVersion = Get-RunningVersion
    $ownedProcess = Get-OwnedProcess
    if (-not $runningVersion -and -not $ownedProcess) {
        return
    }

    $script:wasRunning = $true
    Write-Step 'Stopping the running RouterChat so it can be updated safely.'

    if (-not (Stop-OwnedInstance)) {
        throw 'RouterChat is running but was not started by this installation. Close it, then run the installer again.'
    }
}

function Start-Backend {
    $env:ROUTERCHAT_USER_DATA_DIR = $userDataDir

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd-HHmmss')
    $script:startupLog = Join-Path $logsDir "launcher-$stamp.log"

    $server = Start-Process -FilePath $venvPython `
        -ArgumentList @('-m', 'uvicorn', 'backend.main:app', '--host', '127.0.0.1', '--port', "$routerchatPort") `
        -WorkingDirectory $appDir `
        -RedirectStandardOutput $script:startupLog `
        -RedirectStandardError "$($script:startupLog).error" `
        -WindowStyle Hidden `
        -PassThru

    try {
        Set-Content -LiteralPath (Join-Path $logsDir 'routerchat.pid') -Value $server.Id -Encoding utf8
    }
    catch {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Restart-PreviousInstance {
    if (-not $script:wasRunning) {
        return
    }

    if (-not (Test-Path -LiteralPath $venvPython) -or -not (Test-Path -LiteralPath (Join-Path $appDir 'backend\main.py'))) {
        return
    }

    if (Test-PortInUse) {
        Write-Step "The previous RouterChat version was restored but port $routerchatPort is busy, so it could not be restarted."
        return
    }

    try {
        Start-Backend
    }
    catch {
        Write-Step 'The previous RouterChat version was restored but could not be restarted. Use Start RouterChat.cmd to try again.'
        return
    }

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $restoredVersion = Get-RunningVersion
        if ($restoredVersion -and (-not $script:previousVersion -or $restoredVersion -eq $script:previousVersion)) {
            Write-Step 'Restarted the RouterChat version that was running before.'
            return
        }
        Start-Sleep -Seconds 1
    }

    Stop-OwnedInstance | Out-Null
    Write-Step "The previous RouterChat version was restored but could not be restarted. Use 'Start RouterChat.cmd' to try again."
}

function Start-Routerchat {
    param([string] $Version, [string] $Platform)

    Write-Step "Starting RouterChat $Version."

    if (Test-PortInUse) {
        if (Test-Path -LiteralPath $previousApp) {
            Restore-Application
            throw "Port $routerchatPort is used by another program. The previous RouterChat version was restored."
        }

        Write-InstallMetadata -Version $Version -Platform $Platform
        $script:startFailed = $true
        throw "Port $routerchatPort is used by another program. Close it, then use 'Start RouterChat.cmd'."
    }

    try {
        Start-Backend
    }
    catch {
        Write-Step "RouterChat $Version could not create its backend process, so the previous version is being restored."
        Restore-Application
        throw 'The RouterChat backend process could not be started.'
    }

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        if ((Get-RunningVersion) -eq $Version) {
            try {
                Start-Process $routerchatUrl
            }
            catch {
                Write-Step 'RouterChat is ready, but the browser could not be opened automatically.'
            }
            Write-Step "RouterChat $Version is ready at $routerchatUrl"
            return
        }
        Start-Sleep -Seconds 1
    }

    Stop-OwnedInstance | Out-Null

    Write-Step "RouterChat $Version did not start, so the previous version is being restored."

    $failedLog = $script:startupLog
    Restore-Application

    throw "The new version did not start in time. The previous version was restored. See $failedLog"
}

try {
    $platformName = Test-SupportedPlatform
    Test-InstallRoot
    New-InstallDirectories
    Repair-InterruptedInstallation

    $script:workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("routerchat-install-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:workDir -Force | Out-Null

    Write-Step "Installing RouterChat for $platformName into $installRoot"

    $newVersion = Get-RouterchatPackage
    $script:newVersion = $newVersion
    Install-PrivateRuntime
    Stop-RunningInstance
    $script:transactionStarted = $true
    Backup-UserData
    Start-InstallTransaction
    Install-Application -Version $newVersion
    Sync-PrivateEnvironment
    Write-Launchers
    New-StartMenuShortcuts
    Start-Routerchat -Version $newVersion -Platform $platformName
    Complete-InstallTransaction
    Write-InstallMetadata -Version $newVersion -Platform $platformName
    $script:transactionStarted = $false

    try {
        Remove-PreviousApplication
    }
    catch {
        Write-Step 'The old application cleanup will be retried during the next update.'
    }

    Write-Step "Done. Start RouterChat later from the Start Menu or 'Start RouterChat.cmd' in $installRoot"
    $script:installFailed = $false
}
catch {
    $script:installFailed = $true

    if ($script:transactionStarted) {
        try {
            if (Test-Path -LiteralPath $previousApp) {
                Stop-OwnedInstance | Out-Null
                Restore-Application
            }
            elseif ($script:wasRunning -and -not (Get-RunningVersion)) {
                Restart-PreviousInstance
            }
        }
        catch {
            Write-Step 'Automatic rollback could not finish. Rerun the installer to repair RouterChat.'
        }
    }

    $prefix = if ($script:startFailed) {
        'RouterChat was installed but could not be started'
    }
    else {
        'RouterChat installation failed'
    }

    Write-Host "${prefix}: $($_.Exception.Message)"
    if ($script:logFile) {
        Add-Content -LiteralPath $script:logFile -Value "${prefix}: $($_.Exception.Message)" -Encoding utf8
        Write-Host "A sanitized log is at $script:logFile"
    }
}
finally {
    if ($script:workDir -and (Test-Path -LiteralPath $script:workDir)) {
        Remove-Item -LiteralPath $script:workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:installFailed) {
    exit 1
}

exit 0

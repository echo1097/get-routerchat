$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$appRepo = 'echo1097/routerchat'
$appZipUrl = "https://github.com/$appRepo/releases/latest/download/routerchat-app.zip"
$appChecksumUrl = "https://github.com/$appRepo/releases/latest/download/routerchat-app.zip.sha256"
$installerUrl = 'https://echo1097.github.io/get-routerchat/install.ps1'
$uvVersion = '0.7.19'
$pythonVersion = '3.13'
$routerchatPort = 8000
$routerchatUrl = "http://127.0.0.1:$routerchatPort"
$keptBackups = 3

$installRoot = Join-Path $env:LOCALAPPDATA 'RouterChat'
$appDir = Join-Path $installRoot 'app'
$previousApp = Join-Path $installRoot 'app.previous'
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

    if (-not (Test-Path -LiteralPath $databasePath) -and -not (Test-Path -LiteralPath $envPath)) {
        return
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $backupDir = Join-Path $backupsDir $stamp
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    foreach ($sourcePath in @($envPath, $databasePath)) {
        if (Test-Path -LiteralPath $sourcePath) {
            Copy-Item -LiteralPath $sourcePath -Destination $backupDir -Force
        }
    }

    Write-Step 'Saved a backup of your existing RouterChat data.'

    Get-ChildItem -LiteralPath $backupsDir -Directory |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
        Sort-Object Name -Descending |
        Select-Object -Skip $keptBackups |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
}

function Install-Application {
    param([string] $Version)

    Write-Step "Installing RouterChat $Version."

    $stageDir = Join-Path $script:workDir 'app'

    if (-not (Test-Path -LiteralPath $appDir) -and (Test-Path -LiteralPath $previousApp)) {
        Move-Item -LiteralPath $previousApp -Destination $appDir -Force
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
}

function Remove-PreviousApplication {
    if (Test-Path -LiteralPath $previousApp) {
        Remove-Item -LiteralPath $previousApp -Recurse -Force
    }
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
    Start-Process $routerchatUrl
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

Set-Content -LiteralPath (Join-Path $logsDir 'routerchat.pid') -Value $server.Id -Encoding utf8

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

Start-Process $routerchatUrl

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

    $updateScript = @"
`$ProgressPreference = 'SilentlyContinue'

Write-Host 'Checking for a newer version of RouterChat.'

& powershell -NoProfile -ExecutionPolicy Bypass -Command "irm '$installerUrl' | iex"

if (`$LASTEXITCODE -ne 0) {
    Write-Host 'RouterChat could not be updated. Your existing installation was left in place.'
}

Read-Host 'Press Enter to close this window'
exit `$LASTEXITCODE
"@

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

function Start-Routerchat {
    Write-Step 'Starting RouterChat.'

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd-HHmmss')
    $startupLog = Join-Path $logsDir "launcher-$stamp.log"

    $alreadyHealthy = $false
    try {
        $response = Invoke-RestMethod -Uri "$routerchatUrl/api/health" -TimeoutSec 2 -UseBasicParsing
        $alreadyHealthy = [bool] $response.ok
    }
    catch {
        $alreadyHealthy = $false
    }

    if (-not $alreadyHealthy) {
        $portOwner = $null
        try {
            $portOwner = Get-NetTCPConnection -LocalPort $routerchatPort -State Listen -ErrorAction Stop
        }
        catch {
            $portOwner = $null
        }

        if ($portOwner) {
            Write-Step "Port $routerchatPort is used by another program, so RouterChat was installed but not started."
            return
        }

        $env:ROUTERCHAT_USER_DATA_DIR = $userDataDir

        $server = Start-Process -FilePath $venvPython `
            -ArgumentList @('-m', 'uvicorn', 'backend.main:app', '--host', '127.0.0.1', '--port', "$routerchatPort") `
            -WorkingDirectory $appDir `
            -RedirectStandardOutput $startupLog `
            -RedirectStandardError "$startupLog.error" `
            -WindowStyle Hidden `
            -PassThru

        Set-Content -LiteralPath (Join-Path $logsDir 'routerchat.pid') -Value $server.Id -Encoding utf8
    }

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri "$routerchatUrl/api/health" -TimeoutSec 2 -UseBasicParsing
            if ($response.ok) {
                Start-Process $routerchatUrl
                Write-Step "RouterChat is ready at $routerchatUrl"
                return
            }
        }
        catch {
        }
        Start-Sleep -Seconds 1
    }

    Write-Step "RouterChat was installed but did not start in time. Use 'Start RouterChat.cmd' and check $startupLog"
}

try {
    $platformName = Test-SupportedPlatform
    Test-InstallRoot
    New-InstallDirectories

    $script:workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("routerchat-install-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:workDir -Force | Out-Null

    Write-Step "Installing RouterChat for $platformName into $installRoot"

    $newVersion = Get-RouterchatPackage
    Install-PrivateRuntime
    Backup-UserData
    Install-Application -Version $newVersion
    Sync-PrivateEnvironment
    Remove-PreviousApplication
    Write-InstallMetadata -Version $newVersion -Platform $platformName
    Write-Launchers
    New-StartMenuShortcuts
    Start-Routerchat

    Write-Step "Done. Start RouterChat later from the Start Menu or 'Start RouterChat.cmd' in $installRoot"
    $script:installFailed = $false
}
catch {
    $script:installFailed = $true

    Write-Host "RouterChat installation failed: $($_.Exception.Message)"
    if ($script:logFile) {
        Add-Content -LiteralPath $script:logFile -Value "RouterChat installation failed: $($_.Exception.Message)" -Encoding utf8
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

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
$runDir = Join-Path $installRoot 'run'
$apiSecretFile = Join-Path $runDir 'api-secret'
$venvDir = Join-Path $runtimeDir '.venv'
$venvPython = Join-Path $venvDir 'Scripts\python.exe'
$uvBin = Join-Path $runtimeDir 'tools\uv.exe'

$script:logFile = $null
$script:workDir = $null
$script:installFailed = $false
$script:startFailed = $false
$script:wasRunning = $false
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
            -Arguments @('pip', 'sync', '--require-hashes', '--python', $venvPython, (Join-Path $appDir 'requirements.lock')) `
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
                -Arguments @('pip', 'sync', '--require-hashes', '--python', $venvPython, $restoredLock) `
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
$runDir = Join-Path $installRoot 'run'
$apiSecretFile = Join-Path $runDir 'api-secret'
$localAccessPath = Join-Path $appDir 'backend\local_access.py'
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

function Get-OwnedProcess {
    $pidFile = Join-Path $logsDir 'routerchat.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) {
        return $null
    }

    $recordedLine = Get-Content -LiteralPath $pidFile -TotalCount 1
    $recordedId = 0
    if ([string]::IsNullOrWhiteSpace($recordedLine) -or -not [int]::TryParse($recordedLine.Trim(), [ref] $recordedId)) {
        return $null
    }

    $process = Get-Process -Id $recordedId -ErrorAction SilentlyContinue
    if (-not $process) {
        return $null
    }

    try {
        $details = Get-CimInstance Win32_Process -Filter "ProcessId = $recordedId" -ErrorAction Stop
        if (-not $details.CommandLine -or -not $details.CommandLine.Contains($venvPython)) {
            return $null
        }
    }
    catch {
        return $null
    }

    return $process
}

function Initialize-SecureRunDirectory {
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $currentGrant = "*$($currentSid):(OI)(CI)F"
    & icacls.exe $runDir /inheritance:r /grant:r $currentGrant '*S-1-5-18:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'RouterChat could not protect its process credential directory.'
    }
}

function Open-Routerchat {
    if (Test-Path -LiteralPath $localAccessPath) {
        if (-not (Test-Path -LiteralPath $apiSecretFile)) {
            throw 'RouterChat process credential is missing.'
        }
        Push-Location -LiteralPath $appDir
        try {
            & $venvPython -m backend.local_access open-browser --secret-file $apiSecretFile --base-url $routerchatUrl
            if ($LASTEXITCODE -ne 0) {
                throw 'The browser could not be authorized automatically.'
            }
        }
        finally {
            Pop-Location
        }
        return
    }

    Start-Process $routerchatUrl
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
Initialize-SecureRunDirectory

$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd-HHmmss')
$logFile = Join-Path $logsDir "launcher-$stamp.log"

if (Test-RouterchatHealthy) {
    if (-not (Get-OwnedProcess)) {
        Write-Host 'RouterChat is running but it was not started by this installation.'
        exit 1
    }
    Write-Host 'RouterChat is already running. Opening it in your browser.'
    try {
        Open-Routerchat
    }
    catch {
        Write-Host "RouterChat is ready at $routerchatUrl, but the browser could not be authorized automatically."
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
Remove-Item -LiteralPath $apiSecretFile -Force -ErrorAction SilentlyContinue
$quotedSecretFile = '"' + $apiSecretFile + '"'

$serverArguments = if (Test-Path -LiteralPath $localAccessPath) {
    @(
        '-m', 'backend.local_access', 'serve',
        '--secret-file', $quotedSecretFile,
        '--base-url', $routerchatUrl,
        '--trusted-origin', $routerchatUrl
    )
}
else {
    @('-m', 'uvicorn', 'backend.main:app', '--host', '127.0.0.1', '--port', "$routerchatPort")
}

$server = Start-Process -FilePath $venvPython `
    -ArgumentList $serverArguments `
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
    Open-Routerchat
}
catch {
    Write-Host "RouterChat is ready at $routerchatUrl, but the browser could not be authorized automatically."
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
    Remove-Item -LiteralPath $apiSecretFile -Force -ErrorAction SilentlyContinue
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

    $uninstallScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$installRoot = $PSScriptRoot
$expectedRoot = Join-Path $env:LOCALAPPDATA 'RouterChat'
$userDataDir = Join-Path $installRoot 'user-data'
$logsDir = Join-Path $installRoot 'logs'
$venvDir = Join-Path $installRoot 'runtime\.venv'
$venvPython = Join-Path $venvDir 'Scripts\python.exe'
$routerchatUrl = 'http://127.0.0.1:8000'
$startMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\RouterChat'

function Read-YesNo {
    param([string] $Prompt)

    while ($true) {
        $answer = (Read-Host "$Prompt (y/n)").Trim()

        if ($answer -ieq 'y') {
            return $true
        }
        if ($answer -ieq 'n') {
            return $false
        }

        Write-Host 'Please enter y or n.'
    }
}

function Test-RouterchatHealthy {
    try {
        $response = Invoke-RestMethod -Uri "$routerchatUrl/api/health" -TimeoutSec 2 -UseBasicParsing
        return [bool] $response.ok
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
    $recordedId = 0
    if ([string]::IsNullOrWhiteSpace($recordedLine) -or -not [int]::TryParse($recordedLine.Trim(), [ref] $recordedId)) {
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

function Stop-Routerchat {
    $process = Get-OwnedProcess
    if (-not $process) {
        if (Test-RouterchatHealthy) {
            throw 'RouterChat is running but the uninstaller cannot identify it safely. Close RouterChat and try again.'
        }
        return
    }

    Write-Host 'Stopping RouterChat.'
    Stop-Process -Id $process.Id -ErrorAction SilentlyContinue

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
            break
        }
        Start-Sleep -Seconds 1
    }

    if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) {
        throw 'RouterChat could not be stopped safely. Close it and run the uninstaller again.'
    }

    Remove-Item -LiteralPath (Join-Path $logsDir 'routerchat.pid') -Force -ErrorAction SilentlyContinue
}

function Save-UserData {
    $databasePath = Join-Path $userDataDir 'routerchat.sqlite3'
    if (-not (Test-Path -LiteralPath $databasePath)) {
        Write-Host 'No RouterChat database was found, so there is no user data to save.'
        return
    }

    if (-not (Test-Path -LiteralPath $venvPython)) {
        throw 'RouterChat cannot create a safe database backup because its private Python runtime is missing. Nothing was removed.'
    }

    $downloadsDir = Join-Path $env:USERPROFILE 'Downloads'
    New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $downloadsDir "RouterChat-user-data-$timestamp"
    $suffix = 1
    while (Test-Path -LiteralPath $backupDir) {
        $backupDir = Join-Path $downloadsDir "RouterChat-user-data-$timestamp-$suffix"
        $suffix++
    }

    New-Item -ItemType Directory -Path $backupDir | Out-Null
    $temporaryDatabase = Join-Path $backupDir 'routerchat.sqlite3.tmp'
    $backupDatabase = Join-Path $backupDir 'routerchat.sqlite3'
    $backupCode = 'import sqlite3, sys; source = sqlite3.connect(sys.argv[1]); destination = sqlite3.connect(sys.argv[2]); source.backup(destination); destination.close(); source.close()'

    & $venvPython -c $backupCode $databasePath $temporaryDatabase
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryDatabase)) {
        Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        throw 'The RouterChat database could not be backed up. Nothing was removed.'
    }

    Move-Item -LiteralPath $temporaryDatabase -Destination $backupDatabase

    $readmePath = Join-Path $backupDir 'README-userdata.txt'
    $readme = @"
This SQLite database contains your RouterChat chats and writing data.

To restore it, install RouterChat again, close RouterChat, then replace:
%LOCALAPPDATA%\RouterChat\user-data\routerchat.sqlite3

with the routerchat.sqlite3 file in this folder before starting RouterChat.
The database may contain private content, so do not share it publicly.
"@
    $withoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($readmePath, $readme, $withoutBom)

    Write-Host "User data was saved to $backupDir"
}

function Start-DeferredCleanup {
    $cleanupPath = Join-Path ([System.IO.Path]::GetTempPath()) ("routerchat-uninstall-" + [System.Guid]::NewGuid().ToString('N') + '.ps1')
    $cleanupScript = @(
        'param('
        '    [string] $InstallRoot,'
        '    [int] $ParentProcessId,'
        '    [string] $CleanupPath'
        ')'
        ''
        '$ErrorActionPreference = ''SilentlyContinue'''
        ''
        'for ($attempt = 0; $attempt -lt 600; $attempt++) {'
        '    if (-not (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) {'
        '        break'
        '    }'
        '    Start-Sleep -Milliseconds 500'
        '}'
        ''
        'for ($attempt = 0; $attempt -lt 120; $attempt++) {'
        '    Remove-Item -LiteralPath $InstallRoot -Recurse -Force'
        '    if (-not (Test-Path -LiteralPath $InstallRoot)) {'
        '        break'
        '    }'
        '    Start-Sleep -Milliseconds 500'
        '}'
        ''
        'Remove-Item -LiteralPath $CleanupPath -Force'
    ) -join [Environment]::NewLine

    $withoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($cleanupPath, $cleanupScript, $withoutBom)

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$cleanupPath`"",
        '-InstallRoot', "`"$installRoot`"",
        '-ParentProcessId', $PID,
        '-CleanupPath', "`"$cleanupPath`""
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory ([System.IO.Path]::GetTempPath()) -WindowStyle Hidden
}

try {
    $rootPath = [System.IO.Path]::GetFullPath($installRoot).TrimEnd('\')
    $safeRoot = [System.IO.Path]::GetFullPath($expectedRoot).TrimEnd('\')
    if ($rootPath -ne $safeRoot -or $rootPath -eq [System.IO.Path]::GetPathRoot($rootPath)) {
        throw 'The RouterChat installation path is unsafe. Nothing was removed.'
    }

    if (-not (Test-Path -LiteralPath $installRoot)) {
        Write-Host 'RouterChat is not installed.'
        exit 0
    }

    if (-not (Read-YesNo -Prompt 'Are you sure you want to remove RouterChat')) {
        Write-Host 'Nothing was removed.'
        exit 0
    }

    $saveData = Read-YesNo -Prompt 'Would you like to save user data'

    Stop-Routerchat
    if ($saveData) {
        Save-UserData
    }

    Remove-Item -LiteralPath $startMenuDir -Recurse -Force -ErrorAction SilentlyContinue
    Start-DeferredCleanup

    Write-Host 'RouterChat has been removed.'
    exit 0
}
catch {
    Write-Host "RouterChat could not be removed: $($_.Exception.Message)"
    Read-Host 'Press Enter to close this window'
    exit 1
}
'@

    $startCommand = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-routerchat.ps1"
'@

    $updateCommand = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-routerchat.ps1"
'@

    $uninstallCommand = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-routerchat.ps1"
'@

    Set-Content -LiteralPath (Join-Path $installRoot 'start-routerchat.ps1') -Value $startScript -Encoding utf8
    Set-Content -LiteralPath (Join-Path $installRoot 'update-routerchat.ps1') -Value $updateScript -Encoding utf8
    Set-Content -LiteralPath (Join-Path $installRoot 'uninstall-routerchat.ps1') -Value $uninstallScript -Encoding utf8
    Set-Content -LiteralPath (Join-Path $installRoot 'Start RouterChat.cmd') -Value $startCommand -Encoding ascii
    Set-Content -LiteralPath (Join-Path $installRoot 'Update RouterChat.cmd') -Value $updateCommand -Encoding ascii
    Set-Content -LiteralPath (Join-Path $installRoot 'Uninstall RouterChat.cmd') -Value $uninstallCommand -Encoding ascii
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

        $uninstallShortcut = $shell.CreateShortcut((Join-Path $startMenuDir 'Uninstall RouterChat.lnk'))
        $uninstallShortcut.TargetPath = Join-Path $installRoot 'Uninstall RouterChat.cmd'
        $uninstallShortcut.WorkingDirectory = $installRoot
        $uninstallShortcut.Description = 'Uninstall RouterChat'
        $uninstallShortcut.Save()
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

function Initialize-SecureRunDirectory {
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $currentGrant = "*$($currentSid):(OI)(CI)F"
    & icacls.exe $runDir /inheritance:r /grant:r $currentGrant '*S-1-5-18:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'RouterChat could not protect its process credential directory.'
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
            Remove-Item -LiteralPath $apiSecretFile -Force -ErrorAction SilentlyContinue
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

function Get-LatestStartupLog {
    $latestLog = Get-ChildItem -LiteralPath $logsDir -Filter 'launcher-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($latestLog) {
        return $latestLog.FullName
    }

    return $logsDir
}

function Start-Backend {
    $launcherCommand = Join-Path $installRoot 'Start RouterChat.cmd'
    if (-not (Test-Path -LiteralPath $launcherCommand)) {
        throw 'The RouterChat launcher is missing.'
    }

    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Initialize-SecureRunDirectory

    Start-Process -FilePath $launcherCommand -WorkingDirectory $installRoot | Out-Null
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

    Write-Step "Starting RouterChat $Version in its own window."

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
            Write-Step "RouterChat $Version is ready at $routerchatUrl"
            Write-Step 'It runs in the RouterChat window that just opened. Closing that window stops RouterChat.'
            return
        }
        Start-Sleep -Seconds 1
    }

    Stop-OwnedInstance | Out-Null

    Write-Step "RouterChat $Version did not start, so the previous version is being restored."

    $failedLog = Get-LatestStartupLog
    Restore-Application

    throw "The new version did not start in time. The previous version was restored. See $failedLog"
}

Write-Host 'Use of RouterChat is subject to the Terms of Service:'
Write-Host 'https://github.com/echo1097/routerchat/blob/main/TOS.md'
Write-Host ''

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

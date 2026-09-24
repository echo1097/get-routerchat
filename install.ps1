$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

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
$script:newVersion = $null
$script:updateMode = [bool] $env:ROUTERCHAT_EXPECTED_VERSION
$script:shortcutsFailed = $false

$script:fancy = -not [Console]::IsOutputRedirected
$script:richGlyphs = [bool] $env:WT_SESSION
$script:stepWidth = 46
$script:barWidth = 24
$script:stepOpen = $false
$script:stepNumber = 0
$script:stepLabel = ''
$script:barDrawn = $false
$script:spinTick = 0
$script:animationStart = Get-Date
$script:lastTick = [DateTime]::MinValue
$script:progressKind = $null
$script:progressPath = $null
$script:progressTotal = 0
$script:progressCurrent = 0
$script:progressLabel = ''
$script:progressBase = 0
$script:folderSize = 0
$script:folderCheckedAt = [DateTime]::MinValue
$script:packageTotal = 0
$script:runtimeWasReady = $false

$fullBlock = [string] [char] 0x2588
$lightBlock = [string] [char] 0x2591

if ($script:richGlyphs) {
    $checkMark = [string] [char] 0x2713
    $crossMark = [string] [char] 0x2717
    $spinnerFrames = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F) | ForEach-Object { [string] [char] $_ }
}
else {
    $checkMark = [string] [char] 0x221A
    $crossMark = 'X'
    $spinnerFrames = @('|', '/', '-', '\')
}

function Write-Log {
    param([string] $Message)

    if ($script:logFile) {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Add-Content -LiteralPath $script:logFile -Value "$stamp $Message" -Encoding utf8
    }
}

function Write-Note {
    param([string] $Message)

    Write-Log $Message
}

function Write-Notice {
    param([string] $Message)

    Write-Host "! $Message" -ForegroundColor Yellow
    Write-Log $Message
}

function Write-Warn {
    param([string] $Message)

    Complete-Step -Status 'failed' -Color Red
    Write-Notice $Message
}

function Get-ShortPath {
    param([string] $PathValue)

    if ($env:LOCALAPPDATA -and $PathValue.StartsWith($env:LOCALAPPDATA, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '%LOCALAPPDATA%' + $PathValue.Substring($env:LOCALAPPDATA.Length)
    }

    return $PathValue
}

function Format-Megabytes {
    param([long] $Bytes)

    return ('{0:N1} MB' -f ($Bytes / 1MB))
}

function Write-Terms {
    Write-Host 'Use of RouterChat is subject to the Terms of Service:' -ForegroundColor DarkGray
    Write-Host 'https://github.com/echo1097/routerchat/blob/main/TOS.md' -ForegroundColor DarkGray
    Write-Host ''
}

function Write-StepPrefix {
    $dotCount = [Math]::Max(3, $script:stepWidth - $script:stepLabel.Length)

    Write-Host -NoNewline "`r"
    Write-Host -NoNewline "[$($script:stepNumber)/6] " -ForegroundColor DarkGray
    Write-Host -NoNewline "$($script:stepLabel) "
    Write-Host -NoNewline ('.' * $dotCount) -ForegroundColor DarkGray
}

function Write-Bar {
    param([long] $Current, [long] $Total)

    $filled = 0
    if ($Total -gt 0) {
        $filled = [int] [Math]::Min($script:barWidth, [Math]::Floor($script:barWidth * $Current / $Total))
    }

    Write-Host -NoNewline ($fullBlock * $filled) -ForegroundColor Green
    Write-Host -NoNewline ($lightBlock * ($script:barWidth - $filled)) -ForegroundColor DarkGray
}

function Write-MovingBar {
    $blockSize = 6
    $travel = $script:barWidth - $blockSize
    $elapsed = ((Get-Date) - $script:animationStart).TotalMilliseconds
    $blockStart = [int] ([Math]::Floor($elapsed * 40 / 1000) % ($travel * 2))
    if ($blockStart -gt $travel) {
        $blockStart = $travel * 2 - $blockStart
    }
    $blockEnd = $blockStart + $blockSize

    Write-Host -NoNewline ($lightBlock * $blockStart) -ForegroundColor DarkGray
    Write-Host -NoNewline ($fullBlock * ($blockEnd - $blockStart)) -ForegroundColor Blue
    Write-Host -NoNewline ($lightBlock * ($script:barWidth - $blockEnd)) -ForegroundColor DarkGray
}

function Get-FolderSize {
    param([string] $FolderPath)

    if (((Get-Date) - $script:folderCheckedAt).TotalMilliseconds -lt 1000) {
        return $script:folderSize
    }

    $script:folderCheckedAt = Get-Date
    $script:folderSize = 0

    if (Test-Path -LiteralPath $FolderPath) {
        $sum = (Get-ChildItem -LiteralPath $FolderPath -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($sum) {
            $script:folderSize = [long] $sum
        }
    }

    return $script:folderSize
}

function Get-InstalledPackageCount {
    $sitePackages = Join-Path $venvDir 'Lib\site-packages'
    return @(Get-ChildItem -LiteralPath $sitePackages -Directory -Filter '*.dist-info' -ErrorAction SilentlyContinue).Count
}

function Get-LockedPackageCount {
    param([string] $LockPath)

    return @(Get-Content -LiteralPath $LockPath | Where-Object {
        $_ -match '^[A-Za-z0-9][A-Za-z0-9._-]*==' -and $_ -notmatch "sys_platform != 'win32'" -and $_ -notmatch "sys_platform == 'darwin'" -and $_ -notmatch "sys_platform == 'linux'"
    }).Count
}

function Write-ProgressText {
    switch ($script:progressKind) {
        'bytes' {
            if ($script:progressTotal -gt 0) {
                $current = [Math]::Min($script:progressCurrent, $script:progressTotal)
                $percent = [int] [Math]::Floor(100 * $current / $script:progressTotal)
                Write-Bar -Current $current -Total $script:progressTotal
                Write-Host -NoNewline (' {0} / {1}  {2,3}%' -f (Format-Megabytes $current), (Format-Megabytes $script:progressTotal), $percent)
            }
            else {
                Write-MovingBar
                Write-Host -NoNewline (' {0}' -f (Format-Megabytes $script:progressCurrent))
            }
        }
        'growth' {
            Write-MovingBar
            Write-Host -NoNewline (' {0}  {1}' -f $script:progressLabel, (Format-Megabytes (Get-FolderSize $script:progressPath)))
        }
        'packages' {
            $current = [Math]::Min((Get-InstalledPackageCount), $script:progressTotal)
            if ($current -eq 0) {
                $downloaded = [Math]::Max(0, (Get-FolderSize $script:progressPath) - $script:progressBase)
                Write-MovingBar
                Write-Host -NoNewline (' downloading packages  {0}' -f (Format-Megabytes $downloaded))
                break
            }
            $percent = [int] [Math]::Floor(100 * $current / $script:progressTotal)
            Write-Bar -Current $current -Total $script:progressTotal
            Write-Host -NoNewline (' {0} / {1} packages  {2,3}%' -f $current, $script:progressTotal, $percent)
        }
    }

    Write-Host -NoNewline (' ' * 12)
}

function Set-StepLabel {
    param([int] $Number, [string] $Label)

    $script:stepNumber = $Number
    $script:stepLabel = $Label
}

function Start-Step {
    param([int] $Number, [string] $Label)

    Set-StepLabel -Number $Number -Label $Label
    $script:stepOpen = $true
    $script:barDrawn = $false
    $script:progressKind = $null
    $script:progressTotal = 0
    $script:progressCurrent = 0
    Write-Log "[$Number/6] $Label"

    if ($script:fancy) {
        Write-StepPrefix
    }
}

function Update-Step {
    if (-not $script:stepOpen -or -not $script:fancy) {
        return
    }

    if (((Get-Date) - $script:lastTick).TotalMilliseconds -lt 45) {
        return
    }

    $script:lastTick = Get-Date
    $script:spinTick = [int] [Math]::Floor(((Get-Date) - $script:animationStart).TotalMilliseconds / 100)
    $frame = $spinnerFrames[$script:spinTick % $spinnerFrames.Count]

    if (-not $script:progressKind) {
        Write-StepPrefix
        Write-Host -NoNewline " $frame" -ForegroundColor DarkGray
        return
    }

    if ($script:barDrawn) {
        [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - 1))
    }

    Write-StepPrefix
    Write-Host " $frame" -ForegroundColor DarkGray
    Write-Host -NoNewline '      '
    Write-ProgressText
    $script:barDrawn = $true
}

function Complete-Step {
    param([string] $Status, [ConsoleColor] $Color = [ConsoleColor]::Green, [string] $BarText)

    if (-not $script:stepOpen) {
        return
    }

    if ($script:fancy) {
        if ($script:barDrawn) {
            [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - 1))
        }

        Write-StepPrefix
        Write-Host -NoNewline " $Status" -ForegroundColor $Color
        Write-Host (' ' * 4)
    }
    else {
        Write-Host "[$($script:stepNumber)/6] $($script:stepLabel) $('.' * [Math]::Max(3, $script:stepWidth - $script:stepLabel.Length)) $Status"
    }

    if ($BarText) {
        Write-Host -NoNewline '      '
        Write-Bar -Current 1 -Total 1
        Write-Host " $BarText$(' ' * 24)" -ForegroundColor DarkGray
    }
    elseif ($script:barDrawn) {
        Write-Host -NoNewline (' ' * 78)
        Write-Host -NoNewline "`r"
    }

    $script:stepOpen = $false
    $script:barDrawn = $false
    Write-Log "[$($script:stepNumber)/6] $($script:stepLabel) $Status"
}

function Wait-WithSpinner {
    param([int] $Seconds)

    for ($tick = 0; $tick -lt ($Seconds * 5); $tick++) {
        Update-Step
        Start-Sleep -Milliseconds 200
    }
}

function Format-ProcessArgument {
    param([string] $Value)

    if ($Value -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-WatchedProcess {
    param([string] $FilePath, [string[]] $Arguments)

    $outputPath = [System.IO.Path]::GetTempFileName()
    $errorPath = [System.IO.Path]::GetTempFileName()

    try {
        $argumentText = ($Arguments | ForEach-Object { Format-ProcessArgument $_ }) -join ' '
        $process = Start-Process -FilePath $FilePath -ArgumentList $argumentText -NoNewWindow -PassThru `
            -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath
        $null = $process.Handle

        while (-not $process.HasExited) {
            Update-Step
            Start-Sleep -Milliseconds 50
        }

        $process.WaitForExit()

        foreach ($capturedPath in @($outputPath, $errorPath)) {
            $captured = Get-Content -LiteralPath $capturedPath -Raw -ErrorAction SilentlyContinue
            if ($captured -and $script:logFile) {
                Add-Content -LiteralPath $script:logFile -Value $captured -Encoding utf8
            }
        }

        return $process.ExitCode
    }
    finally {
        Remove-Item -LiteralPath $outputPath, $errorPath -Force -ErrorAction SilentlyContinue
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

function Confirm-HttpsUri {
    param([string] $Url)

    $uri = [Uri] $Url

    if ($uri.Scheme -ne 'https') {
        throw "Refusing a download over an insecure connection: $Url"
    }

    return $uri
}

function Get-RedirectLocation {
    param($Response)

    if ($null -eq $Response) {
        return $null
    }

    $location = $null

    try {
        $location = $Response.Headers.Location | Select-Object -First 1
    }
    catch {
        $location = $null
    }

    if (-not $location) {
        try {
            $location = $Response.Headers['Location']
        }
        catch {
            $location = $null
        }
    }

    if (-not $location) {
        return $null
    }

    return [string] $location
}

function Get-WebExceptionResponse {
    param($Exception)

    $current = $Exception

    while ($null -ne $current) {
        if ($current -is [System.Net.WebException] -and $null -ne $current.Response) {
            return $current.Response
        }

        $current = $current.InnerException
    }

    return $null
}

function New-HttpRequest {
    param([string] $Url)

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.AllowAutoRedirect = $false
    $request.UserAgent = 'RouterChat-Installer'
    $request.Timeout = 120000
    $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

    return $request
}

function Save-ResponseBody {
    param($Response, [string] $Destination, [scriptblock] $OnProgress)

    $totalBytes = 0
    try {
        if ($null -ne $Response.ContentLength) {
            $totalBytes = [long] $Response.ContentLength
        }
    }
    catch {
        $totalBytes = 0
    }

    $responseStream = $Response.GetResponseStream()
    $fileStream = [System.IO.File]::Create($Destination)
    $buffer = New-Object byte[] 81920
    $savedBytes = 0

    try {
        while (($readCount = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $readCount)
            $savedBytes += $readCount

            if ($OnProgress) {
                & $OnProgress $savedBytes $totalBytes
            }
        }
    }
    finally {
        $fileStream.Dispose()
        $responseStream.Dispose()
    }
}

function Get-RemoteFile {
    param([string] $Url, [string] $Destination, [scriptblock] $OnProgress)

    $currentUrl = (Confirm-HttpsUri $Url).AbsoluteUri
    $hopsLeft = 5

    while ($true) {
        $request = New-HttpRequest -Url $currentUrl
        $response = $null

        try {
            $response = $request.GetResponse()
        }
        catch {
            $response = Get-WebExceptionResponse $_.Exception
        }

        if ($null -eq $response) {
            throw "Could not download $Url"
        }

        try {
            $statusCode = [int] $response.StatusCode

            if ($statusCode -ge 300 -and $statusCode -lt 400) {
                $location = Get-RedirectLocation $response

                if (-not $location -or $hopsLeft -le 0) {
                    throw "Could not download $Url"
                }

                $nextUri = [Uri]::new([Uri] $currentUrl, $location)
                $currentUrl = (Confirm-HttpsUri $nextUri.AbsoluteUri).AbsoluteUri
                $hopsLeft -= 1

                continue
            }

            if ($statusCode -ne 200) {
                throw "Could not download $Url"
            }

            Save-ResponseBody -Response $response -Destination $Destination -OnProgress $OnProgress

            return
        }
        finally {
            $response.Dispose()
        }
    }
}

function Get-TrackedFile {
    param([string] $Url, [string] $Destination)

    $script:progressKind = 'bytes'
    $script:progressTotal = 0
    $script:progressCurrent = 0

    Get-RemoteFile -Url $Url -Destination $Destination -OnProgress {
        param($savedBytes, $totalBytes)

        $script:progressCurrent = $savedBytes
        if ($totalBytes -gt 0) {
            $script:progressTotal = $totalBytes
        }
        Update-Step
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
    $zipPath = Join-Path $script:workDir 'routerchat-app.zip'
    $checksumPath = "$zipPath.sha256"

    Get-TrackedFile -Url $appZipUrl -Destination $zipPath
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

    $pythonDir = Join-Path $runtimeDir 'python'
    $script:runtimeWasReady = (Test-Path -LiteralPath $uvBin) -and [bool] (Get-ChildItem -LiteralPath $pythonDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)

    if (-not (Test-Path -LiteralPath $uvBin)) {
        Write-Note "Setting up RouterChat's private Python runtime."

        $uvArchive = 'uv-x86_64-pc-windows-msvc.zip'
        $uvBaseUrl = "https://github.com/astral-sh/uv/releases/download/$uvVersion"
        $archivePath = Join-Path $script:workDir $uvArchive

        Get-TrackedFile -Url "$uvBaseUrl/$uvArchive" -Destination $archivePath
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

    if (-not $script:runtimeWasReady) {
        $script:progressKind = 'growth'
        $script:progressPath = $pythonDir
        $script:progressLabel = "Python $pythonVersion"
    }

    Invoke-PrivateTool -Arguments @('python', 'install', $pythonVersion) -FailureMessage 'The private Python runtime could not be installed.'
}

function Invoke-PrivateTool {
    param([string[]] $Arguments, [string] $FailureMessage)

    $exitCode = Invoke-WatchedProcess -FilePath $uvBin -Arguments $Arguments

    if ($exitCode -ne 0) {
        throw $FailureMessage
    }
}

function Sync-PrivateEnvironment {
    if (-not (Test-Path -LiteralPath $venvPython)) {
        Write-Note "Creating RouterChat's private environment."

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

    $lockPath = Join-Path $appDir 'requirements.lock'
    $script:packageTotal = Get-LockedPackageCount $lockPath
    if ($script:packageTotal -gt 0) {
        $script:progressKind = 'packages'
        $script:progressTotal = $script:packageTotal
        $script:progressPath = Join-Path $runtimeDir 'cache'
        $script:folderCheckedAt = [DateTime]::MinValue
        $script:progressBase = Get-FolderSize $script:progressPath
        $script:folderCheckedAt = [DateTime]::MinValue
    }

    Write-Note "Installing RouterChat's dependencies."

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

    Write-Note 'Saved a backup of your existing RouterChat data.'

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

    Write-Warn 'Restored the previous RouterChat user data.'
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
        Write-Notice 'Recovered the previous RouterChat version after an interrupted update.'
        return
    }

    if (Test-Path -LiteralPath $transactionPath) {
        Restore-InterruptedUserData
        Remove-Item -LiteralPath $appDir -Recurse -Force
        Move-Item -LiteralPath $previousApp -Destination $appDir -Force
        Remove-Item -LiteralPath $transactionPath -Force -ErrorAction SilentlyContinue
        Write-Notice 'Rolled back an interrupted RouterChat update.'
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
        Write-Note 'Finished cleanup from the previous RouterChat update.'
        return
    }

    Restore-InterruptedUserData
    Remove-Item -LiteralPath $appDir -Recurse -Force
    Move-Item -LiteralPath $previousApp -Destination $appDir -Force
    Write-Notice 'Rolled back an interrupted RouterChat update.'
}

function Install-Application {
    param([string] $Version)

    Write-Note "Installing RouterChat $Version."

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
    Write-Warn 'Restored the previous RouterChat application files.'

    $restoredLock = Join-Path $appDir 'requirements.lock'
    if ((Test-Path -LiteralPath $venvPython) -and (Test-Path -LiteralPath $restoredLock)) {
        try {
            Invoke-PrivateTool `
                -Arguments @('pip', 'sync', '--require-hashes', '--python', $venvPython, $restoredLock) `
                -FailureMessage 'The previous dependencies could not be restored.'
        }
        catch {
            Write-Warn 'The previous dependencies could not be restored. Rerun the installer to repair RouterChat.'
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

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Confirm-HttpsUri {
    param([string] $Url)

    $uri = [Uri] $Url

    if ($uri.Scheme -ne 'https') {
        throw "Refusing a download over an insecure connection: $Url"
    }

    return $uri
}

function Get-RedirectLocation {
    param($Response)

    if ($null -eq $Response) {
        return $null
    }

    $location = $null

    try {
        $location = $Response.Headers.Location | Select-Object -First 1
    }
    catch {
        $location = $null
    }

    if (-not $location) {
        try {
            $location = $Response.Headers['Location']
        }
        catch {
            $location = $null
        }
    }

    if (-not $location) {
        return $null
    }

    return [string] $location
}

function Get-WebExceptionResponse {
    param($Exception)

    $current = $Exception

    while ($null -ne $current) {
        if ($current -is [System.Net.WebException] -and $null -ne $current.Response) {
            return $current.Response
        }

        $current = $current.InnerException
    }

    return $null
}

function New-HttpRequest {
    param([string] $Url)

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.AllowAutoRedirect = $false
    $request.UserAgent = 'RouterChat-Installer'
    $request.Timeout = 120000
    $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

    return $request
}

function Save-ResponseBody {
    param($Response, [string] $Destination)

    $responseStream = $Response.GetResponseStream()
    $fileStream = [System.IO.File]::Create($Destination)

    try {
        $responseStream.CopyTo($fileStream)
    }
    finally {
        $fileStream.Dispose()
        $responseStream.Dispose()
    }
}

function Get-RemoteFile {
    param([string] $Url, [string] $Destination)

    $currentUrl = (Confirm-HttpsUri $Url).AbsoluteUri
    $hopsLeft = 5

    while ($true) {
        $request = New-HttpRequest -Url $currentUrl
        $response = $null

        try {
            $response = $request.GetResponse()
        }
        catch {
            $response = Get-WebExceptionResponse $_.Exception
        }

        if ($null -eq $response) {
            throw "Could not download $Url"
        }

        try {
            $statusCode = [int] $response.StatusCode

            if ($statusCode -ge 300 -and $statusCode -lt 400) {
                $location = Get-RedirectLocation $response

                if (-not $location -or $hopsLeft -le 0) {
                    throw "Could not download $Url"
                }

                $nextUri = [Uri]::new([Uri] $currentUrl, $location)
                $currentUrl = (Confirm-HttpsUri $nextUri.AbsoluteUri).AbsoluteUri
                $hopsLeft -= 1

                continue
            }

            if ($statusCode -ne 200) {
                throw "Could not download $Url"
            }

            Save-ResponseBody -Response $response -Destination $Destination

            return
        }
        finally {
            $response.Dispose()
        }
    }
}

$updateUrl = 'https://echo1097.github.io/get-routerchat/updater/update.ps1'
$checksumsUrl = 'https://echo1097.github.io/get-routerchat/updater/checksums.txt'
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("routerchat-updater-bootstrap-" + [System.Guid]::NewGuid().ToString('N'))
$exitCode = 1

try {
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $updatePath = Join-Path $workDir 'update.ps1'
    $checksumsPath = Join-Path $workDir 'checksums.txt'

    Get-RemoteFile -Url $updateUrl -Destination $updatePath
    Get-RemoteFile -Url $checksumsUrl -Destination $checksumsPath

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
        Write-Note 'Start Menu shortcuts could not be created. The launcher files still work.'
        $script:shortcutsFailed = $true
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
        Wait-WithSpinner -Seconds 1
    }

    return $false
}

function Test-RunningInstance {
    $script:wasRunning = [bool] ((Get-RunningVersion) -or (Get-OwnedProcess))
}

function Stop-RunningInstance {
    Test-RunningInstance
    if (-not $script:wasRunning) {
        return
    }
    Write-Note 'Stopping the running RouterChat so it can be updated safely.'

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
        Write-Warn "The previous RouterChat version was restored but port $routerchatPort is busy, so it could not be restarted."
        return
    }

    try {
        Start-Backend
    }
    catch {
        Write-Warn 'The previous RouterChat version was restored but could not be restarted. Use Start RouterChat.cmd to try again.'
        return
    }

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $restoredVersion = Get-RunningVersion
        if ($restoredVersion -and (-not $script:previousVersion -or $restoredVersion -eq $script:previousVersion)) {
            Write-Warn 'Restarted the RouterChat version that was running before.'
            return
        }
        Start-Sleep -Seconds 1
    }

    Stop-OwnedInstance | Out-Null
    Write-Warn "The previous RouterChat version was restored but could not be restarted. Use 'Start RouterChat.cmd' to try again."
}

function Start-Routerchat {
    param([string] $Version, [string] $Platform)

    Write-Note "Starting RouterChat $Version in its own window."

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
        Write-Warn "RouterChat $Version could not create its backend process, so the previous version is being restored."
        Restore-Application
        throw 'The RouterChat backend process could not be started.'
    }

    for ($attempt = 0; $attempt -lt 300; $attempt++) {
        if ((Get-RunningVersion) -eq $Version) {
            Write-Note "RouterChat $Version is ready at $routerchatUrl"
            return
        }
        Update-Step
        Start-Sleep -Milliseconds 200
    }

    Stop-OwnedInstance | Out-Null

    Write-Warn "RouterChat $Version did not start, so the previous version is being restored."

    $failedLog = Get-LatestStartupLog
    Restore-Application

    throw "The new version did not start in time. The previous version was restored. See $failedLog"
}

function Write-Header {
    if ($script:updateMode) {
        Write-Terms
        return
    }

    Write-Host 'RouterChat installer'
    Write-Terms
    Write-Host 'Installing RouterChat'
    Write-Host ''
}

function Write-Ending {
    if ($script:updateMode -or ($script:previousVersion -and $script:previousVersion -ne $script:newVersion)) {
        $headline = "RouterChat updated to $($script:newVersion) and running"
    }
    else {
        $headline = "RouterChat $($script:newVersion) is installed and running"
    }

    $startLater = 'Start Menu > RouterChat'
    if ($script:shortcutsFailed) {
        $startLater = Get-ShortPath (Join-Path $installRoot 'Start RouterChat.cmd')
    }

    Write-Host ''
    Write-Host "$checkMark $headline" -ForegroundColor Green
    Write-Host -NoNewline '  Open:   ' -ForegroundColor DarkGray
    Write-Host $routerchatUrl -ForegroundColor Cyan
    Write-Host -NoNewline '  Stop:   ' -ForegroundColor DarkGray
    Write-Host 'Close the RouterChat window that just opened'
    Write-Host -NoNewline '  Later:  ' -ForegroundColor DarkGray
    Write-Host $startLater
    Write-Host "  Logs:   $(Get-ShortPath $logsDir)" -ForegroundColor DarkGray
    Write-Log $headline
}

function Write-Failure {
    param([string] $Prefix, [string] $Message)

    Complete-Step -Status 'failed' -Color Red
    Write-Host ''
    Write-Host -NoNewline "$crossMark ${Prefix}:" -ForegroundColor Red
    Write-Host " $Message"
    Write-Log "${Prefix}: $Message"

    if ($script:logFile) {
        Write-Host "  Log: $(Get-ShortPath $script:logFile)" -ForegroundColor DarkGray
    }
}

Write-Header

try {
    $platformName = Test-SupportedPlatform
    Test-InstallRoot
    New-InstallDirectories
    Repair-InterruptedInstallation

    $script:workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("routerchat-install-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:workDir -Force | Out-Null

    if ($script:fancy) {
        [Console]::CursorVisible = $false
    }

    Write-Note "Installing RouterChat for $platformName into $installRoot"

    $downloadLabel = 'Downloading RouterChat'
    if ($env:ROUTERCHAT_EXPECTED_VERSION) {
        $downloadLabel = "Downloading RouterChat $($env:ROUTERCHAT_EXPECTED_VERSION)"
    }

    Start-Step -Number 1 -Label $downloadLabel
    $newVersion = Get-RouterchatPackage
    $script:newVersion = $newVersion
    $zipSize = (Get-Item -LiteralPath (Join-Path $script:workDir 'routerchat-app.zip')).Length
    Set-StepLabel -Number 1 -Label "Downloading RouterChat $newVersion"
    Complete-Step -Status 'done' -BarText "$(Format-Megabytes $zipSize)  100%"

    Start-Step -Number 2 -Label 'Setting up Python'
    Install-PrivateRuntime
    if ($script:runtimeWasReady) {
        Complete-Step -Status 'already set up' -Color DarkGray
    }
    else {
        Complete-Step -Status 'done' -BarText "uv $uvVersion + Python $pythonVersion  100%"
    }

    Test-RunningInstance
    if ($script:wasRunning) {
        Start-Step -Number 3 -Label 'Stopping RouterChat and backing up data'
    }
    else {
        Start-Step -Number 3 -Label 'Backing up your data'
    }
    Stop-RunningInstance
    $script:transactionStarted = $true
    Backup-UserData
    if ($script:backupDir) {
        Complete-Step -Status 'done'
    }
    else {
        Complete-Step -Status 'nothing to back up' -Color DarkGray
    }

    Start-InstallTransaction

    Start-Step -Number 4 -Label 'Installing files'
    Install-Application -Version $newVersion
    Complete-Step -Status 'done'

    Start-Step -Number 5 -Label 'Installing dependencies'
    Sync-PrivateEnvironment
    Complete-Step -Status 'done' -BarText "$($script:packageTotal) packages  100%"

    Start-Step -Number 6 -Label 'Starting RouterChat'
    Write-Launchers
    New-StartMenuShortcuts
    Start-Routerchat -Version $newVersion -Platform $platformName
    Complete-InstallTransaction
    Write-InstallMetadata -Version $newVersion -Platform $platformName
    $script:transactionStarted = $false
    Complete-Step -Status 'done'

    try {
        Remove-PreviousApplication
    }
    catch {
        Write-Notice 'The old application cleanup will be retried during the next update.'
    }

    Write-Ending
    $script:installFailed = $false
}
catch {
    $script:installFailed = $true
    $failureMessage = $_.Exception.Message

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
            Write-Warn 'Automatic rollback could not finish. Rerun the installer to repair RouterChat.'
        }
    }

    $prefix = if ($script:startFailed) {
        'RouterChat was installed but could not be started'
    }
    else {
        'RouterChat installation failed'
    }

    Write-Failure -Prefix $prefix -Message $failureMessage
}
finally {
    if ($script:fancy) {
        [Console]::CursorVisible = $true
    }

    if ($script:workDir -and (Test-Path -LiteralPath $script:workDir)) {
        Remove-Item -LiteralPath $script:workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:installFailed) {
    exit 1
}

exit 0

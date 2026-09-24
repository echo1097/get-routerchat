param(
    [Parameter(Mandatory = $true)]
    [string] $InstallRoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$updaterVersion = '1.0.0'
$appRepo = 'echo1097/routerchat'
$releaseApiUrl = "https://api.github.com/repos/$appRepo/releases/latest"
$appZipUrl = "https://github.com/$appRepo/releases/latest/download/routerchat-app.zip"
$appChecksumUrl = "https://github.com/$appRepo/releases/latest/download/routerchat-app.zip.sha256"
$installerUrl = 'https://echo1097.github.io/get-routerchat/install.ps1'

$script:workDir = $null
$script:lockStream = $null
$script:ownsLock = $false
$script:validatedAppSum = $null
$lockPath = Join-Path $InstallRoot 'update.lock'

$script:fancy = -not [Console]::IsOutputRedirected
$script:checkOpen = $false
$script:spinTick = 0
$script:lastTick = [DateTime]::MinValue
$rightArrow = [string] [char] 0x2192

if ($env:WT_SESSION) {
    $crossMark = [string] [char] 0x2717
    $spinnerFrames = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F) | ForEach-Object { [string] [char] $_ }
}
else {
    $crossMark = 'X'
    $spinnerFrames = @('|', '/', '-', '\')
}

function Write-CheckPrefix {
    Write-Host -NoNewline "`rChecking for updates "
    Write-Host -NoNewline ('.' * 32) -ForegroundColor DarkGray
}

function Start-Check {
    $script:checkOpen = $true

    if ($script:fancy) {
        [Console]::CursorVisible = $false
        Write-CheckPrefix
    }
}

function Update-Check {
    if (-not $script:checkOpen -or -not $script:fancy) {
        return
    }

    if (((Get-Date) - $script:lastTick).TotalMilliseconds -lt 90) {
        return
    }

    $script:lastTick = Get-Date
    $script:spinTick += 1
    Write-CheckPrefix
    Write-Host -NoNewline " $($spinnerFrames[$script:spinTick % $spinnerFrames.Count])" -ForegroundColor DarkGray
}

function Complete-Check {
    param([string] $Status, [ConsoleColor] $Color)

    if (-not $script:checkOpen) {
        return
    }

    if ($script:fancy) {
        Write-CheckPrefix
    }
    else {
        Write-Host -NoNewline "Checking for updates $('.' * 32)"
    }

    Write-Host " $Status    " -ForegroundColor $Color
    $script:checkOpen = $false
}

function Get-NormalizedVersion {
    param([string] $Value)
    return $Value.Trim() -replace '^v', ''
}

function Get-VersionValue {
    param([string] $Value, [string] $Label)

    $normalizedValue = Get-NormalizedVersion $Value
    if ($normalizedValue -notmatch '^\d+\.\d+\.\d+$') {
        throw "$Label has an invalid version."
    }

    return [version] $normalizedValue
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
    param($Response, [string] $Destination)

    $responseStream = $Response.GetResponseStream()
    $fileStream = [System.IO.File]::Create($Destination)
    $buffer = New-Object byte[] 81920

    try {
        while (($readCount = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $readCount)
            Update-Check
        }
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

function Confirm-Checksum {
    param([string] $FilePath, [string] $ChecksumPath)

    $firstLine = (Get-Content -LiteralPath $ChecksumPath -TotalCount 1).Trim()
    $expectedSum = ($firstLine -split '\s+')[0]
    if ($expectedSum -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The published application checksum could not be read.'
    }

    $actualSum = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash
    if ($expectedSum -ne $actualSum) {
        throw 'The application package did not match its published checksum.'
    }
}

function Confirm-InstallRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'The Local AppData folder could not be found.'
    }

    $resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot)
    $expectedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'RouterChat'))
    if (-not $resolvedRoot.Equals($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installation location is not a supported RouterChat installation.'
    }
}

function New-UpdateLock {
    try {
        $script:lockStream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] {
        $staleLock = $false

        try {
            $recordedId = [int] (Get-Content -LiteralPath $lockPath -Raw).Trim()
            $recordedProcess = Get-Process -Id $recordedId -ErrorAction SilentlyContinue
            $staleLock = -not $recordedProcess
        }
        catch {
            throw 'Another RouterChat update is already running.'
        }

        if (-not $staleLock) {
            throw 'Another RouterChat update is already running.'
        }

        Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
        $script:lockStream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
    }

    $lockBytes = [System.Text.Encoding]::UTF8.GetBytes("$PID")
    $script:lockStream.Write($lockBytes, 0, $lockBytes.Length)
    $script:lockStream.Flush()
    $script:ownsLock = $true
}

function Get-InstalledVersion {
    $metadataPath = Join-Path $InstallRoot 'install.json'
    $versionPath = Join-Path $InstallRoot 'app\version.json'

    if (-not (Test-Path -LiteralPath $metadataPath) -or -not (Test-Path -LiteralPath $versionPath)) {
        throw 'Installation metadata is missing. Rerun the one-click installer to repair RouterChat.'
    }

    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $versionMetadata = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json

    if ($metadata.schemaVersion -ne 1) {
        throw 'This installation metadata version is not supported. Rerun the one-click installer.'
    }

    $installedVersion = Get-NormalizedVersion ([string] $versionMetadata.version)
    $metadataVersion = Get-NormalizedVersion ([string] $metadata.installedVersion)
    Get-VersionValue $installedVersion 'The installed application' | Out-Null

    if ($installedVersion -ne $metadataVersion) {
        throw 'Installed version metadata does not match. Rerun the one-click installer to repair RouterChat.'
    }

    return $installedVersion
}

function Get-LatestReleaseVersion {
    $releasePath = Join-Path $script:workDir 'release.json'
    Get-RemoteFile -Url $releaseApiUrl -Destination $releasePath
    $release = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
    $latestVersion = Get-NormalizedVersion ([string] $release.tag_name)
    Get-VersionValue $latestVersion 'The latest stable release' | Out-Null
    return $latestVersion
}

function Confirm-LatestPackage {
    param([string] $LatestVersion)

    $zipPath = Join-Path $script:workDir 'routerchat-app.zip'
    $checksumPath = "$zipPath.sha256"
    $stageDir = Join-Path $script:workDir 'app'

    Get-RemoteFile -Url $appZipUrl -Destination $zipPath
    Get-RemoteFile -Url $appChecksumUrl -Destination $checksumPath
    Confirm-Checksum -FilePath $zipPath -ChecksumPath $checksumPath
    $script:validatedAppSum = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    Expand-Archive -LiteralPath $zipPath -DestinationPath $stageDir -Force

    foreach ($requiredPath in @('backend\main.py', 'dist\index.html', 'requirements.lock', 'version.json', 'TOS.md', 'LICENSE')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stageDir $requiredPath))) {
            throw "The application package is missing $requiredPath"
        }
    }

    $metadata = Get-Content -LiteralPath (Join-Path $stageDir 'version.json') -Raw | ConvertFrom-Json
    $packageVersion = Get-NormalizedVersion ([string] $metadata.version)
    $releaseTag = Get-NormalizedVersion ([string] $metadata.releaseTag)
    $minimumUpdater = Get-VersionValue ([string] $metadata.minimumUpdaterVersion) 'The minimum updater version'

    if ($packageVersion -ne $LatestVersion -or $releaseTag -ne $LatestVersion) {
        throw 'The package version does not match the latest stable release.'
    }

    if ((Get-VersionValue $updaterVersion 'The updater') -lt $minimumUpdater) {
        throw "RouterChat $LatestVersion requires a newer updater. Rerun the one-click installer."
    }
}

function Invoke-Installer {
    param([string] $ExpectedVersion)

    $env:ROUTERCHAT_EXPECTED_VERSION = $ExpectedVersion
    $env:ROUTERCHAT_EXPECTED_APP_SHA256 = $script:validatedAppSum
    $installerPath = Join-Path $script:workDir 'install.ps1'

    Get-RemoteFile -Url $installerUrl -Destination $installerPath

    & powershell -NoProfile -ExecutionPolicy Bypass -File $installerPath
    if ($LASTEXITCODE -ne 0) {
        throw 'The installer could not complete the update; the rollback process was attempted.'
    }
}

Write-Host 'RouterChat updater'

try {
    Start-Check
    Confirm-InstallRoot

    New-UpdateLock

    $script:workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("routerchat-update-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:workDir -Force | Out-Null

    $installedVersion = Get-InstalledVersion
    $latestVersion = Get-LatestReleaseVersion
    $installedValue = Get-VersionValue $installedVersion 'The installed application'
    $latestValue = Get-VersionValue $latestVersion 'The latest stable release'

    if ($installedValue -eq $latestValue) {
        Complete-Check -Status 'up to date' -Color DarkGray
        Write-Host ''
        Write-Host "RouterChat $installedVersion is already the latest version."
        exit 0
    }

    if ($installedValue -gt $latestValue) {
        Complete-Check -Status 'up to date' -Color DarkGray
        Write-Host ''
        Write-Host "RouterChat $installedVersion is newer than the latest stable release, so no update was installed."
        exit 0
    }

    Confirm-LatestPackage -LatestVersion $latestVersion
    Complete-Check -Status "$latestVersion available" -Color Yellow
    Write-Host ''
    Write-Host "Updating RouterChat $installedVersion $rightArrow $latestVersion"
    Invoke-Installer -ExpectedVersion $latestVersion
}
catch {
    Complete-Check -Status 'failed' -Color Red
    Write-Host ''
    Write-Host -NoNewline "$crossMark RouterChat update failed:" -ForegroundColor Red
    Write-Host " $($_.Exception.Message)"
    exit 1
}
finally {
    if ($script:fancy) {
        [Console]::CursorVisible = $true
    }

    if ($script:lockStream) {
        $script:lockStream.Dispose()
    }
    if ($script:ownsLock) {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }

    if ($script:workDir -and (Test-Path -LiteralPath $script:workDir)) {
        Remove-Item -LiteralPath $script:workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit 0

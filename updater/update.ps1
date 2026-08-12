param(
    [Parameter(Mandatory = $true)]
    [string] $InstallRoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

try {
    Confirm-InstallRoot

    New-UpdateLock

    $script:workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("routerchat-update-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:workDir -Force | Out-Null

    $installedVersion = Get-InstalledVersion
    $latestVersion = Get-LatestReleaseVersion
    $installedValue = Get-VersionValue $installedVersion 'The installed application'
    $latestValue = Get-VersionValue $latestVersion 'The latest stable release'

    if ($installedValue -eq $latestValue) {
        Write-Host "RouterChat $installedVersion is already the latest version."
        exit 0
    }

    if ($installedValue -gt $latestValue) {
        Write-Host "RouterChat $installedVersion is newer than the latest stable release, so no update was installed."
        exit 0
    }

    Write-Host "Updating RouterChat from $installedVersion to $latestVersion."
    Confirm-LatestPackage -LatestVersion $latestVersion
    Invoke-Installer -ExpectedVersion $latestVersion
    Write-Host "RouterChat was updated to $latestVersion."
}
catch {
    Write-Host "RouterChat update failed: $($_.Exception.Message)"
    exit 1
}
finally {
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

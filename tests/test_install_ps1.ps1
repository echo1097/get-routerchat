$ErrorActionPreference = 'Stop'

$repoDir = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $repoDir 'install.ps1'
$updaterPath = Join-Path $repoDir 'updater/update.ps1'

foreach ($scriptPath in @($installerPath, $updaterPath)) {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref] $null,
        [ref] $parseErrors
    ) | Out-Null

    if ($parseErrors.Count -ne 0) {
        throw "$(Split-Path -Leaf $scriptPath) has PowerShell parse errors: $($parseErrors[0].Message)"
    }
}

$installer = Get-Content -LiteralPath $installerPath -Raw
$requiredPatterns = @(
    "backend\.local_access', 'serve",
    'backend\.local_access open-browser',
    'Initialize-SecureRunDirectory',
    'icacls\.exe.+/inheritance:r',
    'Get-OwnedProcess',
    'Remove-Item -LiteralPath \$apiSecretFile',
    "'pip', 'sync', '--require-hashes'",
    'Use of RouterChat is subject to the Terms of Service:',
    'https://github\.com/echo1097/routerchat/blob/main/TOS\.md',
    '\[Net\.ServicePointManager\]::SecurityProtocol',
    'function Confirm-HttpsUri',
    'function Get-RedirectLocation',
    'AllowAutoRedirect = \$false'
)

foreach ($pattern in $requiredPatterns) {
    if ($installer -notmatch $pattern) {
        throw "install.ps1 is missing required secure launcher behavior: $pattern"
    }
}

Write-Host 'install.ps1 secure launcher tests passed'

$updater = Get-Content -LiteralPath $updaterPath -Raw

foreach ($pattern in @('\[Net\.ServicePointManager\]::SecurityProtocol', 'function Confirm-HttpsUri', 'function Get-RedirectLocation', 'AllowAutoRedirect = \$false')) {
    if ($updater -notmatch $pattern) {
        throw "updater/update.ps1 is missing required download hardening: $pattern"
    }
}

foreach ($scriptName in @('install.ps1', 'updater/update.ps1')) {
    $body = if ($scriptName -eq 'install.ps1') { $installer } else { $updater }

    if ($body -match 'MaximumRedirection 5') {
        throw "$scriptName still follows redirects without checking the scheme"
    }
}

$installerAst = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref] $null, [ref] $null)

$updateScriptAssignments = $installerAst.FindAll(
    {
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$updateScript'
    },
    $true
)

if ($updateScriptAssignments.Count -ne 1) {
    throw "expected one generated update bootstrap, found $($updateScriptAssignments.Count)"
}

$bootstrapText = $updateScriptAssignments[0].Right.Extent.Text
$bootstrapText = $bootstrapText -replace "^@'\r?\n", '' -replace "\r?\n'@$", ''

$bootstrapErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($bootstrapText, [ref] $null, [ref] $bootstrapErrors) | Out-Null

if ($bootstrapErrors.Count -ne 0) {
    throw "the generated update bootstrap has parse errors: $($bootstrapErrors[0].Message)"
}

foreach ($pattern in @('\[Net\.ServicePointManager\]::SecurityProtocol', 'function Confirm-HttpsUri', 'Get-RemoteFile -Url \$updateUrl', 'Get-RemoteFile -Url \$checksumsUrl')) {
    if ($bootstrapText -notmatch $pattern) {
        throw "the generated update bootstrap is missing: $pattern"
    }
}

$downloadHelpers = @('Confirm-HttpsUri', 'Get-RedirectLocation', 'New-HttpRequest', 'Save-ResponseBody', 'Get-RemoteFile')
$definedHelpers = @{}

$helperDefinitions = $installerAst.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $true
) | Where-Object { $downloadHelpers -contains $_.Name }

foreach ($definition in $helperDefinitions) {
    if (-not $definedHelpers.ContainsKey($definition.Name)) {
        $definedHelpers[$definition.Name] = $true
        Invoke-Expression $definition.Extent.Text
    }
}

foreach ($helperName in $downloadHelpers) {
    if (-not $definedHelpers.ContainsKey($helperName)) {
        throw "install.ps1 is missing the $helperName download helper"
    }
}

$script:requestedUrls = @()
$script:redirects = @{}

function New-FakeResponse {
    param([int] $StatusCode, [string] $Location, [string] $Body)

    return [pscustomobject] @{
        StatusCode = $StatusCode
        Headers = @{ Location = $Location }
        Body = $Body
    } | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($this.Body)
        return [System.IO.MemoryStream]::new($bytes)
    } -PassThru | Add-Member -MemberType ScriptMethod -Name Dispose -Value { } -PassThru
}

function New-HttpRequest {
    param([string] $Url)

    $script:requestedUrls += $Url

    $response = if ($script:redirects.ContainsKey($Url)) {
        New-FakeResponse -StatusCode 302 -Location $script:redirects[$Url] -Body ''
    }
    else {
        New-FakeResponse -StatusCode 200 -Location $null -Body "body-from-$Url"
    }

    return [pscustomobject] @{ Url = $Url } |
        Add-Member -MemberType NoteProperty -Name PreparedResponse -Value $response -PassThru |
        Add-Member -MemberType ScriptMethod -Name GetResponse -Value { return $this.PreparedResponse } -PassThru
}

$destination = Join-Path ([System.IO.Path]::GetTempPath()) 'routerchat-download-test.bin'

try {
    Get-RemoteFile -Url 'http://example.test/start' -Destination $destination
    throw 'a plain http download URL was accepted'
}
catch {
    if ($_.Exception.Message -notmatch 'Refusing a download over an insecure connection') {
        throw "an insecure download URL gave an unexpected error: $($_.Exception.Message)"
    }
}

$script:requestedUrls = @()
$script:redirects = @{ 'https://example.test/start' = 'https://cdn.example.test/final' }
Get-RemoteFile -Url 'https://example.test/start' -Destination $destination

if ((Get-Content -LiteralPath $destination -Raw).Trim() -ne 'body-from-https://cdn.example.test/final') {
    throw 'an https redirect did not download the redirect target'
}

$script:requestedUrls = @()
$script:redirects = @{ 'https://example.test/start' = 'http://cdn.example.test/final' }

try {
    Get-RemoteFile -Url 'https://example.test/start' -Destination $destination
    throw 'a redirect to plain http was followed'
}
catch {
    if ($_.Exception.Message -notmatch 'Refusing a download over an insecure connection') {
        throw "a downgrade redirect gave an unexpected error: $($_.Exception.Message)"
    }
}

if ($script:requestedUrls -contains 'http://cdn.example.test/final') {
    throw 'the insecure redirect target was still requested'
}

$script:requestedUrls = @()
$script:redirects = @{ 'https://example.test/start' = '/moved' }
Get-RemoteFile -Url 'https://example.test/start' -Destination $destination

if ($script:requestedUrls[1] -ne 'https://example.test/moved') {
    throw "a relative redirect did not resolve, got '$($script:requestedUrls[1])'"
}

$script:requestedUrls = @()
$script:redirects = @{}
1..8 | ForEach-Object {
    $script:redirects["https://example.test/hop$_"] = "https://example.test/hop$($_ + 1)"
}

try {
    Get-RemoteFile -Url 'https://example.test/hop1' -Destination $destination
    throw 'an endless redirect chain was followed'
}
catch {
    if ($_.Exception.Message -notmatch 'Could not download') {
        throw "an endless redirect chain gave an unexpected error: $($_.Exception.Message)"
    }
}

if ($script:requestedUrls.Count -gt 6) {
    throw "the redirect limit was not enforced, made $($script:requestedUrls.Count) requests"
}

Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue

Write-Host 'install.ps1 secure download tests passed'

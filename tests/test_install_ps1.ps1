$ErrorActionPreference = 'Stop'

$repoDir = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $repoDir 'install.ps1'
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath,
    [ref] $tokens,
    [ref] $parseErrors
) | Out-Null

if ($parseErrors.Count -ne 0) {
    throw "install.ps1 has PowerShell parse errors: $($parseErrors[0].Message)"
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
    'https://github\.com/echo1097/routerchat/blob/main/TOS\.md'
)

foreach ($pattern in $requiredPatterns) {
    if ($installer -notmatch $pattern) {
        throw "install.ps1 is missing required secure launcher behavior: $pattern"
    }
}

Write-Host 'install.ps1 secure launcher tests passed'

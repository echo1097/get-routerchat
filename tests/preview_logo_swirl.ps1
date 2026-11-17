param([ValidateSet('auto', 'braille', 'blocks')] [string] $Glyphs = 'auto')

$ErrorActionPreference = 'Stop'

$repoDir = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $repoDir 'install.ps1'
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref] $null, [ref] $null)

$swirlFunctions = @('Get-LogoInk', 'New-LogoSwirl', 'Update-LogoCells', 'Format-LogoFrame', 'Show-LogoSwirl')

$logoData = $installerAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$logoSpanRows'
}, $true)

$functionNodes = $installerAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $swirlFunctions -contains $node.Name
}, $true)

if (-not $logoData -or $functionNodes.Count -ne $swirlFunctions.Count) {
    throw 'install.ps1 is missing part of the logo animation'
}

function Write-Log {
    param([string] $Message)

    Write-Host $Message
}

. ([scriptblock]::Create($logoData.Extent.Text))

foreach ($functionNode in $functionNodes) {
    . ([scriptblock]::Create($functionNode.Extent.Text))
}

$script:fancy = -not [Console]::IsOutputRedirected
$script:richGlyphs = [bool] $env:WT_SESSION

if ($Glyphs -eq 'braille') {
    $script:richGlyphs = $true
}

if ($Glyphs -eq 'blocks') {
    $script:richGlyphs = $false
}

Show-LogoSwirl
Write-Host 'RouterChat installer'

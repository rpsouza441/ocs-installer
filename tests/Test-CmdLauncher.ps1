#requires -Version 5.1
# Harness isolado do Install-OCS.cmd: argumentos, pastas com espaco e exit codes.
# Nao executa o instalador real e nao toca no OCS.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$sourceCmd = Join-Path $PSScriptRoot '..\Install-OCS.cmd'
$testRoot = Join-Path $env:TEMP ('OCS Cmd Space ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
Copy-Item -LiteralPath $sourceCmd -Destination (Join-Path $testRoot 'Install-OCS.cmd')

$stub = @'
#requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('ClientId')]
    [int]$ClientIndex,
    [string]$ClientTag,
    [switch]$DryRun,
    [string]$ClientsPath,
    [switch]$NoPause,
    [switch]$RunInventory
)
$out = Join-Path $PSScriptRoot 'received-args.txt'
@(
    "ClientTag=$ClientTag"
    "ClientIndex=$ClientIndex"
    "ClientIndexSpecified=$($PSBoundParameters.ContainsKey('ClientIndex'))"
    "DryRun=$($DryRun.IsPresent)"
    "NoPause=$($NoPause.IsPresent)"
    "RunInventory=$($RunInventory.IsPresent)"
    "ClientsPath=$ClientsPath"
) | Set-Content -LiteralPath $out -Encoding ASCII
$code = 0
if ($env:OCS_STUB_EXIT -match '^-?\d+$') { $code = [int]$env:OCS_STUB_EXIT }
exit $code
'@
Set-Content -LiteralPath (Join-Path $testRoot 'Install-OCS.ps1') -Value $stub -Encoding ASCII

$cmdPath = Join-Path $testRoot 'Install-OCS.cmd'
$argsFile = Join-Path $testRoot 'received-args.txt'
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Invoke-CmdLauncher {
    param([string]$ArgumentString, [int]$ExpectedExit)
    if (Test-Path -LiteralPath $argsFile) { Remove-Item -LiteralPath $argsFile -Force }
    cmd.exe /c "`"$cmdPath`" $ArgumentString"
    Assert-Equal $ExpectedExit $LASTEXITCODE ("CMD propaga exit $ExpectedExit")
}

try {
    Invoke-CmdLauncher '-ClientTag CLIENT-A -DryRun -NoPause' 0
    $received = Get-Content -LiteralPath $argsFile -Raw
    Assert ($received -match 'ClientTag=CLIENT-A') 'CMD entrega -ClientTag ao PowerShell'
    Assert ($received -match 'DryRun=True') 'CMD entrega -DryRun ao PowerShell'
    Assert ($received -match 'NoPause=True') 'CMD entrega -NoPause ao PowerShell'

    Invoke-CmdLauncher '-ClientTag CLIENT-A -RunInventory -NoPause' 0
    $received = Get-Content -LiteralPath $argsFile -Raw
    Assert ($received -match 'RunInventory=True') 'CMD entrega -RunInventory ao PowerShell'
    Assert ($received -match 'NoPause=True') 'CMD entrega -NoPause junto com -RunInventory'

    Invoke-CmdLauncher '-ClientTag "Acme Corp" -DryRun -NoPause' 0
    $received = Get-Content -LiteralPath $argsFile -Raw
    Assert ($received -match 'ClientTag=Acme Corp') 'CMD preserva ClientTag com espaco'

    $env:OCS_STUB_EXIT = '10'
    Invoke-CmdLauncher '-DryRun -NoPause' 10
    $env:OCS_STUB_EXIT = '255'
    Invoke-CmdLauncher '-DryRun -NoPause' 255
    $env:OCS_STUB_EXIT = '256'
    Invoke-CmdLauncher '-DryRun -NoPause' 256
    $env:OCS_STUB_EXIT = '3010'
    Invoke-CmdLauncher '-ClientTag CLIENT-A -DryRun -NoPause' 3010
    Remove-Item Env:OCS_STUB_EXIT -ErrorAction SilentlyContinue

    Set-Content -LiteralPath (Join-Path $testRoot 'Exit-3010.ps1') -Value 'exit 3010' -Encoding ASCII
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testRoot 'Exit-3010.ps1')
    Assert-Equal 3010 $LASTEXITCODE 'powershell.exe -File preserva 3010 (nao trunca para 198)'

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $testRoot 'Exit-3010.ps1')
        Assert-Equal 3010 $LASTEXITCODE 'pwsh -File preserva 3010'
    } else {
        & $ps51 -NoProfile -ExecutionPolicy Bypass -Command "exit 3010"
        Assert-Equal 3010 $LASTEXITCODE 'Windows PowerShell 5.1 exit 3010 preserva o codigo'
    }

    Write-TestTotal 'Test-CmdLauncher'
} finally {
    Remove-Item Env:OCS_STUB_EXIT -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

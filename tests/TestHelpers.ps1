#requires -Version 5.1
# Utilitarios comuns aos testes. Nenhuma funcao aqui toca no OCS real:
# todas produzem apenas objetos em memoria.

# Contadores sobrevivem a um novo dot-source do instalador feito para
# descartar mocks no meio de uma suite.
if ($null -eq $script:Passed) { $script:Passed = 0 }
if ($null -eq $script:Failed) { $script:Failed = 0 }

function Assert {
    param($Condition, [string]$Name)
    if ($Condition) { $script:Passed++; Write-Host "PASS: $Name" }
    else { $script:Failed++; Write-Host "FALHOU: $Name" -ForegroundColor Red; throw "FALHOU: $Name" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    Assert ("$Expected" -eq "$Actual") ("$Name (esperado '$Expected', obtido '$Actual')")
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Name)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert $threw $Name
}

function Write-TestTotal {
    param([string]$Suite)
    Write-Host ''
    Write-Host ("$Suite -> $script:Passed testes passaram. Nenhuma instalacao, servico ou processo real foi alterado.") -ForegroundColor Green
}

function Write-Utf8BomFile {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $true))
}

function Read-Utf8File {
    param([string]$Path)
    return [IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding $false))
}

# Fatos do servico equivalentes ao que Get-OCSServiceFacts leria do Windows.
function New-FakeServiceFacts {
    param(
        [bool]$ServiceObjectFound = $true,
        $Status = 'Running',
        $StartType = 'Automatic',
        [bool]$RegistryKeyFound = $true,
        $RegistryStart = 2,
        $DeleteFlag = $null,
        $ImagePath = '"C:\Program Files\OCS Inventory Agent\OcsService.exe"',
        $ImagePathExists = $true,
        $ProcessId = $null,
        [string[]]$PendingRebootReasons = @(),
        $QueryError = $null
    )
    return [pscustomobject]@{
        ServiceObjectFound = $ServiceObjectFound
        Status = $Status
        StartType = $StartType
        RegistryKeyFound = $RegistryKeyFound
        RegistryStart = $RegistryStart
        DeleteFlag = $DeleteFlag
        ImagePath = $ImagePath
        ImagePathExists = $ImagePathExists
        ProcessId = $ProcessId
        ProcessName = $(if ($ProcessId) { 'OcsService' } else { $null })
        PendingRebootReasons = $PendingRebootReasons
        QueryError = $QueryError
    }
}

# Fatos equivalentes a um servico em execucao com exclusao pendente
# (Start=Disabled, DeleteFlag=1 e processo ainda ativo).
function New-MarkedForDeletionFacts {
    return New-FakeServiceFacts -Status 'Running' -StartType 'Disabled' -RegistryStart 4 -DeleteFlag 1 -ProcessId 4242
}

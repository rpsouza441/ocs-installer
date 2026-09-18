#requires -Version 5.1
# Comparação de versão e avaliação do resultado do setup.
# Funções puras: nenhuma leitura ou alteração do OCS real.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Install-OCS.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

# --- Normalizacao de versao -----------------------------------------------
Assert-Equal '2.11.0.1' (ConvertTo-OCSVersion '2.11.0.1').ToString() 'Versao com pontos'
Assert-Equal '2.11.0.1' (ConvertTo-OCSVersion '2, 11, 0, 1').ToString() 'FileVersion com virgulas e espacos'
Assert-Equal '2.11' (ConvertTo-OCSVersion '2.11').ToString() 'Duas partes'
Assert-Equal '2.0' (ConvertTo-OCSVersion '2').ToString() 'Uma parte recebe menor zero'
Assert ($null -eq (ConvertTo-OCSVersion $null)) 'Nulo nao e versao'
Assert ($null -eq (ConvertTo-OCSVersion '')) 'Vazio nao e versao'
Assert ($null -eq (ConvertTo-OCSVersion '   ')) 'Espacos nao sao versao'
Assert ($null -eq (ConvertTo-OCSVersion '2.11.0.1-beta')) 'Sufixo textual nao e versao'
Assert ($null -eq (ConvertTo-OCSVersion 'desconhecida')) 'Texto livre nao e versao'

# A comparacao nao pode ser textual: '2.9.0.0' > '2.11.0.0' como string.
Assert ((ConvertTo-OCSVersion '2.9.0.0') -lt (ConvertTo-OCSVersion '2.11.0.0')) 'Comparacao numerica, nao textual'
Assert (('2.9.0.0' -gt '2.11.0.0')) 'Confirmado: a comparacao textual estaria errada'

# --- Estados de versao ----------------------------------------------------
Assert-Equal 'NotInstalled' (Get-OCSVersionState -Installed $false -InstalledVersion $null -TargetVersion '2.11.0.1') '1. Nao instalado => NotInstalled'
Assert-Equal 'Older' (Get-OCSVersionState -Installed $true -InstalledVersion '2.10.1.0' -TargetVersion '2.11.0.1') '2. 2.10.1.0 vs 2.11.0.1 => Older'
Assert-Equal 'Current' (Get-OCSVersionState -Installed $true -InstalledVersion '2.11.0.1' -TargetVersion '2.11.0.1') '3. 2.11.0.1 vs 2.11.0.1 => Current'
Assert-Equal 'Newer' (Get-OCSVersionState -Installed $true -InstalledVersion '2.12.0.0' -TargetVersion '2.11.0.1') '4. 2.12.0.0 vs 2.11.0.1 => Newer'
Assert-Equal 'Unknown' (Get-OCSVersionState -Installed $true -InstalledVersion $null -TargetVersion '2.11.0.1') '5. Versao instalada desconhecida => Unknown'
Assert-Equal 'Unknown' (Get-OCSVersionState -Installed $true -InstalledVersion 'desconhecida' -TargetVersion '2.11.0.1') '5. Versao instalada ilegivel => Unknown'
Assert-Equal 'Unknown' (Get-OCSVersionState -Installed $true -InstalledVersion '2.11.0.1' -TargetVersion $null) 'Versao alvo desconhecida => Unknown'
Assert-Equal 'Current' (Get-OCSVersionState -Installed $true -InstalledVersion '2, 11, 0, 1' -TargetVersion '2.11.0.1') 'Formatos diferentes da mesma versao => Current'
Assert-Equal 'Older' (Get-OCSVersionState -Installed $true -InstalledVersion '2.11.0.0' -TargetVersion '2.11.0.1') 'Diferenca apenas na revisao => Older'

# --- Resultado do setup ---------------------------------------------------
$outcome = Test-OCSUpdateOutcome 0 '2.11.0.1' '2.11.0.1'
Assert ($outcome.Applied) '11. Setup 0 com versao correta em disco => aplicado'
Assert (-not $outcome.RebootRequired) '11. Setup 0 nao pede reinicializacao'
Assert-Equal 'Current' $outcome.VersionState '11. Setup 0 ainda revalida a versao em disco'

$outcome = Test-OCSUpdateOutcome 3010 '2.11.0.1' '2.11.0.1'
Assert ($outcome.RebootRequired) '12. Setup 3010 => reinicializacao necessaria'
Assert ($outcome.Applied) '12. Setup 3010 com versao correta ainda conta como aplicado'

$outcome = Test-OCSUpdateOutcome 0 '2.10.1.0' '2.11.0.1'
Assert (-not $outcome.Applied) '13. Setup 0 mas versao continua antiga => nao aplicado'
Assert-Equal 'Older' $outcome.VersionState '13. Estado da versao apos setup permanece Older'
Assert ($outcome.Reason -match 'continua anterior') '13. Motivo tecnico registrado'

$outcome = Test-OCSUpdateOutcome 0 $null '2.11.0.1'
Assert (-not $outcome.Applied) 'Setup 0 sem versao legivel => nao declara sucesso'
Assert-Equal 'Unknown' $outcome.VersionState 'Versao ilegivel apos setup => Unknown'

$outcome = Test-OCSUpdateOutcome 0 '2.12.0.0' '2.11.0.1'
Assert ($outcome.Applied) 'Versao em disco mais recente que o pacote tambem e aceita'

# --- Versao alvo vem do FileVersion do pacote, nao do codigo --------------
$packagePath = Join-Path $PSScriptRoot '..\files\OCS-Windows-Agent-Setup-x64.exe'
$packageInfo = Get-OCSVersionFromInstaller $packagePath
$packageVersion = (Get-Item -LiteralPath $packagePath).VersionInfo.FileVersion
Select-OCSInstallerPackage
$resolved = Resolve-OCSTargetVersion
Assert-Equal (ConvertTo-OCSVersion $packageVersion).ToString() $resolved 'Versao alvo lida do FileVersion do EXE selecionado'
Assert-Equal $resolved $script:AgentVersion 'AgentVersion e preenchida pela resolucao, nao fixa no codigo'
Assert-Equal 'FileVersion' $packageInfo.Source 'Fonte primaria da versao e FileVersion do EXE'
Assert-Equal $resolved (Resolve-OCSTargetVersion -InstallerPath $packagePath) 'Caminho do EXE selecionado prevalece'

# Fallback configurado diferente do EXE nao pode vencer depois que o arquivo existe.
$savedFallback = $AgentVersionFallback
$AgentVersionFallback = '9.9.9.9'
$resolvedAgainstWrongFallback = Resolve-OCSTargetVersion -InstallerPath $packagePath
Assert-Equal (ConvertTo-OCSVersion $packageVersion).ToString() $resolvedAgainstWrongFallback 'EXE disponivel: FileVersion vence fallback 9.9.9.9'
Assert ($resolvedAgainstWrongFallback -ne $AgentVersionFallback) 'EXE disponivel: fallback nao e usado'
$AgentVersionFallback = $savedFallback

# EXE presente sem versao legivel: nao inventar a partir do fallback.
$versionProbeRoot = Join-Path $env:TEMP ('OCS-version-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $versionProbeRoot | Out-Null
try {
    $unreadable = Join-Path $versionProbeRoot 'no-version.exe'
    [IO.File]::WriteAllBytes($unreadable, [byte[]](0x4D, 0x5A, 0x90, 0x00))
    $fromUnreadable = Get-OCSVersionFromInstaller $unreadable
    Assert ($null -eq $fromUnreadable) 'EXE sem FileVersion/ProductVersion nao inventa versao'
    $resolvedUnreadable = Resolve-OCSTargetVersion -InstallerPath $unreadable
    Assert ($null -eq $resolvedUnreadable) 'Resolve com EXE ilegivel retorna nulo'
    Assert ($null -eq $script:AgentVersion) 'AgentVersion nao recebe fallback quando o EXE existe e e ilegivel'
    Assert ($resolvedUnreadable -ne $AgentVersionFallback) 'Fallback nao e usado com EXE presente'
} finally {
    Remove-Item -LiteralPath $versionProbeRoot -Recurse -Force
}

# Sem pacote em disco, cai no valor de referencia unico do script.
function Get-OCSInstallerLocalPath { return $null }
Assert-Equal $AgentVersionFallback (Resolve-OCSTargetVersion) 'Pacote ausente usa o valor de referencia unico'

Write-TestTotal 'Test-VersionDecisions'

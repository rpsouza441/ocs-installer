#requires -Version 5.1
# Executa todas as suítes em processos separados, para que os mocks de uma
# suíte não vazem para outra. Nenhuma suíte altera o OCS, o serviço ou
# processos reais.
[CmdletBinding()]
param([switch]$Quiet)

$suites = @(
    'Test-VersionDecisions.ps1'
    'Test-ServiceStateMachine.ps1'
    'Test-ServiceTransitions.ps1'
    'Test-Certificates.ps1'
    'Test-ClientSelection.ps1'
    'Test-ExistingInstallationFlow.ps1'
    'Test-Installer.ps1'
    'Test-CmdLauncher.ps1'
)
# As suites rodam no mesmo host do runner: executar por powershell.exe testa
# Windows PowerShell 5.1 e por pwsh testa PowerShell 7.
$hostPath = (Get-Process -Id $PID).Path
if (-not $hostPath) { $hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
Write-Host ("Host de teste: {0} ({1})" -f $hostPath, $PSVersionTable.PSVersion)

$failures = @()
foreach ($suite in $suites) {
    $path = Join-Path $PSScriptRoot $suite
    Write-Host ''
    Write-Host "########## $suite ##########" -ForegroundColor Cyan
    $output = & $hostPath -NoProfile -ExecutionPolicy Bypass -File $path 2>&1
    $code = $LASTEXITCODE
    $summary = @($output | Where-Object { "$_" -match '^(PASS|FALHOU)' -or "$_" -match 'testes passaram' })
    if ($Quiet) { $summary | Where-Object { "$_" -match 'testes passaram|FALHOU' } | ForEach-Object { Write-Host $_ } }
    else { $summary | ForEach-Object { Write-Host $_ } }
    $failed = @($output | Where-Object { "$_" -match '^FALHOU' })
    if ($code -ne 0 -or $failed.Count -gt 0) {
        $failures += $suite
        Write-Host "SUITE COM FALHA: $suite (exit $code)" -ForegroundColor Red
        $output | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
    }
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host ("TODAS AS {0} SUITES PASSARAM. Nenhuma instalacao, servico, processo ou registro real foi alterado." -f $suites.Count) -ForegroundColor Green
    exit 0
}
Write-Host ("SUITES COM FALHA: {0}" -f ($failures -join ', ')) -ForegroundColor Red
exit 1

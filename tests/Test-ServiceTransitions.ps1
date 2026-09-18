#requires -Version 5.1
# Transições do serviço e solicitação de inventário pelo controle privado 128.
# Get-OCSServiceFacts é substituído: nenhum serviço real é consultado ou alterado.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Install-OCS.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

function Start-Sleep { param($Milliseconds) }

function New-FakeService {
    param($InitialStatus, $AfterRefresh, $StartType = 'Automatic')
    return @{ Status = $InitialStatus; Next = $AfterRefresh; StartType = $StartType; Stops = 0; Starts = 0; StartTypeSets = 0 }
}

# O SCM so revela o novo estado na leitura seguinte, como no Windows real.
function Get-OCSServiceFacts {
    if ($script:Fake.Next) { $script:Fake.Status = $script:Fake.Next; $script:Fake.Next = $null }
    $start = if ($script:Fake.StartType -eq 'Automatic') { 2 } elseif ($script:Fake.StartType -eq 'Manual') { 3 } else { 4 }
    return New-FakeServiceFacts -Status $script:Fake.Status -StartType $script:Fake.StartType -RegistryStart $start
}
function Stop-Service { param($Name, [switch]$Force, $WarningAction, $ErrorAction); $script:Fake.Stops++; $script:Fake.Status = 'StopPending'; $script:Fake.Next = 'Stopped' }
function Start-Service { param($Name, $WarningAction, $ErrorAction); $script:Fake.Starts++; $script:Fake.Status = 'StartPending'; $script:Fake.Next = 'Running' }
function Set-Service { param($Name, $StartupType, $ErrorAction); $script:Fake.StartTypeSets++; $script:Fake.StartType = "$StartupType" }

# Parada esperando o fim de uma inicializacao em andamento.
$script:Fake = New-FakeService 'StartPending' 'Running'
Set-OCSServiceState Stopped
Assert-Equal 1 $script:Fake.Stops 'Parada solicitada uma unica vez'
Assert-Equal 'Stopped' $script:Fake.Status 'Servico parou depois de terminar a inicializacao'

Start-OCSService
Assert-Equal 1 $script:Fake.Starts 'Reinicio solicitado uma unica vez'
Assert-Equal 'Running' $script:Fake.Status 'Servico voltou a executar'

Start-OCSService
Assert-Equal 1 $script:Fake.Starts 'Servico ja em execucao nao recebe novo start (idempotente)'

# Running + Disabled: corrige somente o tipo de inicio, sem parar nem iniciar.
$script:Fake = New-FakeService 'Running' $null 'Disabled'
Start-OCSService
Assert-Equal 'Automatic' $script:Fake.StartType 'Inicio Disabled corrigido para Automatic'
Assert-Equal 'Running' $script:Fake.Status 'Servico permanece em execucao'
Assert-Equal 0 $script:Fake.Starts 'Nenhum start desnecessario'
Assert-Equal 0 $script:Fake.Stops 'Nenhuma parada desnecessaria'
Assert-Equal 1 $script:Fake.StartTypeSets 'Tipo de inicio ajustado uma unica vez'

# StopPending: esperar a parada antes de iniciar.
$script:Fake = New-FakeService 'StopPending' 'Stopped'
Start-OCSService
Assert-Equal 'Running' $script:Fake.Status 'Espera StopPending terminar antes de iniciar'

# Timeout preserva o diagnostico do estado real.
$script:Fake = New-FakeService 'StopPending' $null
$message = ''
try { Set-OCSServiceState Stopped -TimeoutSeconds 0 } catch { $message = "$($_.Exception.Message)" }
Assert ($message -match 'StopPending') 'Timeout informa o estado real do servico'
Assert ($message -match 'ServiceStopping') 'Timeout informa o estado classificado pela maquina de estados'

# Reparo completo a partir de Running + Disabled.
$script:Fake = New-FakeService 'Running' $null 'Disabled'
$state = Get-OCSServiceState
Assert-Equal 'RunningDisabled' $state.State 'Estado de origem do reparo'
$repaired = Repair-OCSService $state
Assert-Equal 'ServiceHealthy' $repaired.State 'Reparo devolve o servico saudavel'
Assert-Equal 0 $script:Fake.Stops 'Reparo nao para o servico'

# --- Inventario pelo controle privado do servico, sem parar o servico -----
function Set-OCSServiceState { param($Target, [int]$TimeoutSeconds = 120) }
function Get-Process { param($Name, $ErrorAction); return @() }
$AgentDataDirectory = Join-Path $env:TEMP ('OCS-service-log-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $AgentDataDirectory | Out-Null
$script:ControlRequested = $false
$script:ControlArguments = @()
$script:LogWritten = $false
function Invoke-ServiceControllerTool {
    param([string[]]$Arguments, [int[]]$SuccessCodes = @(0))
    $script:ControlRequested = $true
    $script:ControlArguments = $Arguments
}
function Start-Sleep {
    param($Milliseconds)
    if ($script:ControlRequested -and -not $script:LogWritten) {
        @'
Starting OCS Inventory Agent
AGENT => Prolog successfully sent
AGENT => Inventory successfully sent
AGENT => Execution duration: 00:00:01.
'@ | Set-Content -LiteralPath (Join-Path $AgentDataDirectory 'OCSInventory.log')
        $script:LogWritten = $true
    }
}
$client = [pscustomobject]@{ server = 'https://ocs.example/ocsinventory'; tag = 'TEST' }
try {
    Invoke-OCSInventory ([pscustomobject]@{ Exe = 'fake.exe' }) $client
    Assert $script:ControlRequested 'Inventario solicitado ao proprio servico'
    Assert-Equal '128' $script:ControlArguments[2] 'Controle privado 128 (Run Inventory Now) utilizado'
    Assert-Equal 'control' $script:ControlArguments[0] 'Comando sc.exe control, sem parar o servico'
    Assert-Equal 'Inventario enviado' $script:InventoryResult 'Resultado do inventario lido do log do agente'

    # Erro no log do agente nao e reportado como sucesso.
    $script:ControlRequested = $false; $script:LogWritten = $false
    $script:InventoryResult = 'Nao executado'
    function Start-Sleep {
        param($Milliseconds)
        if ($script:ControlRequested -and -not $script:LogWritten) {
            @'
Starting OCS Inventory Agent
ERROR *** AGENT => Cannot write TAG
AGENT => Execution duration: 00:00:01.
'@ | Set-Content -LiteralPath (Join-Path $AgentDataDirectory 'OCSInventory.log')
            $script:LogWritten = $true
        }
    }
    Assert-Throws { Invoke-OCSInventory ([pscustomobject]@{ Exe = 'fake.exe' }) $client } 'Erro no log do agente nao e tratado como sucesso'
    Assert-Equal 'Nao executado' $script:InventoryResult 'Resultado do inventario nao e falsificado apos erro'

    Write-TestTotal 'Test-ServiceTransitions'
} finally {
    Remove-Item -LiteralPath $AgentDataDirectory -Recurse -Force
}

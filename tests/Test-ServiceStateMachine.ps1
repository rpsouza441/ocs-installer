#requires -Version 5.1
# Máquina de estados do serviço: classificação pura + tratamento do erro 1072.
# Nenhum serviço real é consultado ou alterado: Get-OCSServiceFacts é substituído.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Install-OCS.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

# --- Classificacao dos estados --------------------------------------------
Assert-Equal 'ServiceHealthy' (Resolve-OCSServiceState (New-FakeServiceFacts -Status 'Running' -StartType 'Automatic')).State 'Running + Automatic => ServiceHealthy'
Assert (Resolve-OCSServiceState (New-FakeServiceFacts)).Healthy 'ServiceHealthy marca Healthy'
Assert (-not (Resolve-OCSServiceState (New-FakeServiceFacts)).NeedsRepair) 'ServiceHealthy nao pede reparo'
Assert-Equal 'ServiceHealthy' (Resolve-OCSServiceState (New-FakeServiceFacts -StartType 'AutomaticDelayedStart')).State 'Automatico com atraso tambem e saudavel'

$runningDisabled = Resolve-OCSServiceState (New-FakeServiceFacts -Status 'Running' -StartType 'Disabled' -RegistryStart 4)
Assert-Equal 'RunningDisabled' $runningDisabled.State 'Running + Disabled => RunningDisabled'
Assert ($runningDisabled.NeedsRepair -and -not $runningDisabled.Healthy) 'RunningDisabled precisa correcao'
Assert ($runningDisabled.SafeToModify) 'RunningDisabled pode ser corrigido'

$stoppedAutomatic = Resolve-OCSServiceState (New-FakeServiceFacts -Status 'Stopped' -StartType 'Automatic')
Assert-Equal 'StoppedAutomatic' $stoppedAutomatic.State 'Stopped + Automatic => StoppedAutomatic'
Assert ($stoppedAutomatic.NeedsRepair) 'StoppedAutomatic precisa ser iniciado'

Assert-Equal 'StoppedDisabled' (Resolve-OCSServiceState (New-FakeServiceFacts -Status 'Stopped' -StartType 'Disabled' -RegistryStart 4)).State 'Stopped + Disabled => StoppedDisabled'
Assert-Equal 'StoppedDisabled' (Resolve-OCSServiceState (New-FakeServiceFacts -Status 'Stopped' -StartType 'Manual' -RegistryStart 3)).State 'Manual nao volta no boot: tratado como inicio incorreto'

$missing = Resolve-OCSServiceState (New-FakeServiceFacts -ServiceObjectFound $false -RegistryKeyFound $false -Status $null -StartType $null -RegistryStart $null -ImagePath $null -ImagePathExists $null)
Assert-Equal 'ServiceMissing' $missing.State 'Sem servico e sem chave => ServiceMissing'
Assert (-not $missing.Exists) 'ServiceMissing nao existe'
Assert (-not $missing.RebootRequired) 'ServiceMissing nao exige reinicializacao'

Assert-Equal 'CorruptOrIncomplete' (Resolve-OCSServiceState (New-FakeServiceFacts -ServiceObjectFound $false -Status $null -StartType $null)).State 'Chave sem servico => CorruptOrIncomplete'
Assert-Equal 'CorruptOrIncomplete' (Resolve-OCSServiceState (New-FakeServiceFacts -ImagePathExists $false)).State 'Binario ausente => CorruptOrIncomplete'
Assert-Equal 'ProcessStillRunning' (Resolve-OCSServiceState (New-FakeServiceFacts -Status 'Stopped' -ProcessId 4242)).State 'Servico parado com processo vivo => ProcessStillRunning'
Assert-Equal 'RebootRequired' (Resolve-OCSServiceState (New-FakeServiceFacts -Status 'Stopped' -ProcessId 4242 -PendingRebootReasons @('PendingFileRenameOperations(OCS)'))).State 'Processo vivo + alteracao pendente => RebootRequired'
Assert-Equal 'ServiceStarting' (Resolve-OCSServiceState (New-FakeServiceFacts -Status 'StartPending')).State 'StartPending => ServiceStarting'
Assert-Equal 'ServiceStopping' (Resolve-OCSServiceState (New-FakeServiceFacts -Status 'StopPending')).State 'StopPending => ServiceStopping'
Assert (-not (Resolve-OCSServiceState (New-FakeServiceFacts -Status 'StartPending')).SafeToModify) 'ServiceStarting nao e seguro de alterar'
Assert ((Format-OCSServiceStateForUser (Resolve-OCSServiceState (New-FakeServiceFacts -Status 'StartPending'))) -match 'iniciando') 'StartPending tem mensagem amigavel, nao "nao foi possivel classificar"'
Assert-Equal 'Unknown' (Resolve-OCSServiceState (New-FakeServiceFacts -Status 'Paused')).State 'Paused => Unknown'

# --- MarkedForDeletion / 1072 ---------------------------------------------
$marked = Resolve-OCSServiceState (New-MarkedForDeletionFacts)
Assert-Equal 'MarkedForDeletion' $marked.State 'DeleteFlag=1 => MarkedForDeletion'
Assert $marked.MarkedForDeletion 'MarkedForDeletion sinalizado'
Assert $marked.RebootRequired 'MarkedForDeletion exige reinicializacao'
Assert (-not $marked.Healthy) 'MarkedForDeletion nao e saudavel'
Assert (-not $marked.NeedsRepair) 'MarkedForDeletion nao entra no caminho de reparo'
Assert (-not $marked.SafeToModify) 'MarkedForDeletion bloqueia alteracoes no servico'
Assert-Equal 4242 $marked.ProcessId 'PID do processo que mantem a exclusao pendente e registrado'
Assert ($marked.TechnicalDetails -match 'DeleteFlag=1' -and $marked.TechnicalDetails -match 'ProcessId=4242') 'Detalhes tecnicos do 1072 disponiveis para o log'

# Um erro de consulta contendo 1072 tambem classifica como MarkedForDeletion.
Assert-Equal 'MarkedForDeletion' (Resolve-OCSServiceState (New-FakeServiceFacts -QueryError 'ChangeServiceConfig FALHA 1072')).State 'Mensagem 1072 na consulta => MarkedForDeletion'
Assert-Equal 'MarkedForDeletion' (Resolve-OCSServiceState (New-FakeServiceFacts -QueryError 'The specified service has been marked for delete.')).State 'Texto em ingles do 1072 => MarkedForDeletion'

# --- Nenhuma operacao de servico e tentada quando ha exclusao pendente ----
$script:FakeFacts = New-MarkedForDeletionFacts
function Get-OCSServiceFacts { return $script:FakeFacts }
$script:SetServiceCalls = 0
$script:ScCalls = @()
function Set-Service { param($Name, $StartupType, $ErrorAction); $script:SetServiceCalls++ }
function Stop-Service { param($Name, [switch]$Force, $WarningAction, $ErrorAction); $script:SetServiceCalls++ }
function Start-Service { param($Name, $WarningAction, $ErrorAction); $script:SetServiceCalls++ }
function Invoke-ServiceControllerTool { param([string[]]$Arguments, [int[]]$SuccessCodes = @(0)); $script:ScCalls += ($Arguments -join ' ') }

$state = Get-OCSServiceState
Assert-Equal 'MarkedForDeletion' $state.State 'Get-OCSServiceState usa os fatos injetados'

$rebootSignalled = $false
try { Set-OCSServiceState -Target Running } catch { $rebootSignalled = Test-OCSRebootRequiredError $_ }
Assert $rebootSignalled 'Set-OCSServiceState sinaliza reinicializacao em vez de insistir'
Assert-Equal 0 $script:SetServiceCalls 'Nenhum comando de servico enviado com exclusao pendente'
Assert-Equal 0 $script:ScCalls.Count 'Nenhuma chamada sc.exe com exclusao pendente'
Assert $script:RebootRequired 'Sinalizador global de reinicializacao ativado'

$rebootSignalled = $false
try { Repair-OCSService $state } catch { $rebootSignalled = Test-OCSRebootRequiredError $_ }
Assert $rebootSignalled 'Repair-OCSService recusa reparar servico marcado para exclusao'
Assert-Equal 0 $script:SetServiceCalls 'Reparo nao emitiu comandos de servico'

$rebootSignalled = $false
try { Assert-OCSSafeToRunSetup $state $true } catch { $rebootSignalled = Test-OCSRebootRequiredError $_ }
Assert $rebootSignalled 'Setup e bloqueado antes de iniciar quando ha exclusao pendente'

# Servico corrompido nao e "reparado" silenciosamente: exige reinstalacao autorizada.
$corrupt = Resolve-OCSServiceState (New-FakeServiceFacts -ImagePathExists $false)
$message = ''
try { Repair-OCSService $corrupt } catch { $message = "$($_.Exception.Message)" }
Assert ($message -match 'incompleto') 'CorruptOrIncomplete exige reinstalacao autorizada, nao reparo'

# --- sc.exe 1072 vira reinicializacao necessaria, sem repeticao -----------
. (Join-Path $PSScriptRoot '..\Install-OCS.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$script:ScRuns = 0
function Get-OCSServiceFacts { return (New-FakeServiceFacts -Status 'Running' -StartType 'Disabled' -RegistryStart 4) }
function Set-Service { param($Name, $StartupType, $ErrorAction); throw 'Service OCS Inventory Service cannot be configured: 1072' }
$rebootSignalled = $false
try { Set-OCSServiceStartType Automatic } catch { $rebootSignalled = Test-OCSRebootRequiredError $_ }
Assert $rebootSignalled 'Set-Service com 1072 vira reinicializacao necessaria'

function Set-Service { param($Name, $StartupType, $ErrorAction); throw 'acesso negado' }
function Invoke-ServiceControllerTool {
    param([string[]]$Arguments, [int[]]$SuccessCodes = @(0))
    $script:ScRuns++
    throw (New-OCSRebootRequiredError 'sc.exe config => Win32 1072 ERROR_SERVICE_MARKED_FOR_DELETE')
}
$rebootSignalled = $false
try { Set-OCSServiceStartType Automatic } catch { $rebootSignalled = Test-OCSRebootRequiredError $_ }
Assert $rebootSignalled 'Fallback sc.exe com 1072 vira reinicializacao necessaria'
Assert-Equal 1 $script:ScRuns 'sc.exe config e tentado uma unica vez (sem loop)'

# --- Wait-OCSProcessExit nunca encerra processos --------------------------
. (Join-Path $PSScriptRoot '..\Install-OCS.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
function Start-Sleep { param($Milliseconds) }
$script:ProcessQueries = 0
function Get-Process {
    param($Name, $ErrorAction)
    $script:ProcessQueries++
    if ($script:ProcessQueries -lt 3) { return @([pscustomobject]@{ Name = 'OcsService'; Id = 4242 }) }
    return @()
}
Assert (Wait-OCSProcessExit -Names @('OcsService') -TimeoutSeconds 60) 'Espera o processo sair por conta propria'
$script:ProcessQueries = 0
function Get-Process { param($Name, $ErrorAction); return @([pscustomobject]@{ Name = 'OcsService'; Id = 4242 }) }
Assert (-not (Wait-OCSProcessExit -Names @('OcsService') -TimeoutSeconds 0)) 'Processo persistente resulta em falha, nunca em encerramento forcado'

Write-TestTotal 'Test-ServiceStateMachine'

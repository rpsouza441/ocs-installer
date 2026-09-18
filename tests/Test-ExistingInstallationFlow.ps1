#requires -Version 5.1
# Fluxo completo de decisão sobre uma instalação existente.
# Todas as fronteiras mutáveis (setup, serviço, processos, inventário, registro)
# são substituídas por sentinelas. Nada do OCS real é lido ou alterado.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Install-OCS.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$savedProgramData = $env:ProgramData
$env:ProgramData = Join-Path $env:TEMP ('OCS-flow-' + [guid]::NewGuid().ToString('N'))
$NoPause = $true
$RunInventory = $false
$DryRun = $false
$ClientIndex = 1
$ClientTag = $null
$script:ClientIndexSpecified = $true
$ClientsPath = Join-Path $PSScriptRoot 'fixtures\clients.json'
$SharedServer = 'https://ocs.example.com/ocsinventory'
$ServiceSettleWaitSeconds = 0
$PostSetupSettleWaitSeconds = 0

# --- Sentinelas -------------------------------------------------------------
function Read-Host { param($Prompt); $script:Prompts += $Prompt; return $script:Answers.Dequeue() }
function Test-Administrator { return $true }
function Initialize-OCSCertificateBundle {
    param($Client)
    $script:BundleInitCalls++
    if ($script:InitializeBundleThrows) { throw 'Falha simulada ao gerar bundle CA.' }
    $script:SimulatedCaBundleExists = $true
    $script:SimulatedCaBundleValid = $true
}
function Test-OCSCaBundleFileExists { param([string]$Path); return [bool]$script:SimulatedCaBundleExists }
function Test-OCSCaBundleContent { param([string]$Path); return [bool]$script:SimulatedCaBundleValid }
function Assert-OCSCaBundleReady {
    if (-not (Test-OCSCaBundleFileExists (Get-OCSExpectedCaBundlePath))) { throw 'O bundle CA esperado nao foi gerado.' }
    if (-not (Test-OCSCaBundleContent (Get-OCSExpectedCaBundlePath))) { throw 'O bundle CA gerado nao contem certificados X509 validos.' }
}
function Get-OCSInstaller { param([switch]$Preview); return (Join-Path $PSScriptRoot '..\files\OCS-Windows-Agent-Setup-x64.exe') }
function Resolve-OCSTargetVersion { param([string]$InstallerPath); $script:AgentVersion = $script:TargetVersion; return $script:TargetVersion }
function Wait-OCSProcessExit {
    param([string[]]$Names, [int]$TimeoutSeconds = 120)
    # Distinguir os dois processos: OCSInventory travado significa "agente
    # ocupado" (42), enquanto OcsService travado e o risco real de 1072 (3010).
    foreach ($name in $Names) { if (-not $script:ProcessRelease[$name]) { return $false } }
    return $true
}
function Confirm-OCSInventoryWait { return $script:UserWaitsForInventory }
function Start-Sleep { param($Milliseconds) }

function Install-OCSAgent {
    param([string]$Installer, $Client)
    $script:SetupCalls++
    $script:SetupDone = $true
    $script:SetupPerformed = $true
    # Um setup real reregistra o servico: refletir isso nos fatos simulados.
    $script:Facts = $script:FactsAfterSetup
    return $script:SetupExitCode
}
function Set-OCSConfiguration { param([string]$Installer, $Client); return (Install-OCSAgent $Installer $Client) }
function Invoke-OCSInventory { param($Agent, $Client); $script:InventoryCalls++; $script:InventoryResult = 'Enviado com sucesso' }
function Set-OCSServiceState {
    param([ValidateSet('Running', 'Stopped')][string]$Target, [int]$TimeoutSeconds = 120)
    $script:ServiceCommands += $Target
    if ($script:ServiceControlThrows) { throw 'O Windows recusou o comando do servico (simulado).' }
    if ($Target -eq 'Running') { $script:Facts = New-FakeServiceFacts -Status 'Running' -StartType 'Automatic' }
}
function Get-OCSServiceFacts { return $script:Facts }
function Get-InstalledOCSAgent {
    $found = if ($script:SetupDone) { $true } else { $script:AgentFound }
    $version = if ($script:SetupDone) { $script:VersionAfterSetup } else { $script:InstalledVersion }
    return [pscustomobject]@{
        Found = $found
        Exe = $(if ($found) { 'C:\fake\OCSInventory.exe' } else { $null })
        Version = $version
        Service = $null
        ServiceStatus = $script:Facts.Status
        ServiceStartType = $script:Facts.StartType
    }
}
function Get-ExistingOCSConfiguration {
    param([string]$Directory = $AgentDataDirectory)
    if (-not $script:SetupDone) {
        return [pscustomobject]@{ Server = $script:ExistingServer; Tag = $script:ExistingTag; Ssl = $script:ExistingSsl; CaBundle = $script:ExistingCaBundle; HasCredentials = $false }
    }
    $script:PostSetupConfigReads++
    $tag = $script:TagAfterSetup
    if ($script:TagRaceReads -gt 0 -and $script:PostSetupConfigReads -le $script:TagRaceReads) {
        $tag = $script:ExistingTag
    }
    return [pscustomobject]@{ Server = $script:ServerAfterSetup; Tag = $tag; Ssl = $script:SslAfterSetup; CaBundle = $script:CaBundleAfterSetup; HasCredentials = $false }
}

function Invoke-Scenario {
    param(
        [string]$Name,
        [string[]]$Answers,
        [bool]$AgentFound = $true,
        $InstalledVersion = '2.11.0.1',
        $TargetVersion = '2.11.0.1',
        $ExistingServer = $SharedServer,
        $ExistingTag = 'CLIENT-A',
        $Facts = $null,
        $FactsAfterSetup = $null,
        [int]$SetupExitCode = 0,
        $VersionAfterSetup = $null,
        $TagAfterSetup = 'CLIENT-A',
        $ServerAfterSetup = $SharedServer,
        [bool]$ProcessesRelease = $true,
        [bool]$InventoryProcessReleases = $true,
        [bool]$ServiceProcessReleases = $true,
        [bool]$UserWaitsForInventory = $false,
        [bool]$ServiceControlThrows = $false,
        [int]$TagRaceReads = 0,
        $ExistingSsl = '1',
        $SslAfterSetup = '1',
        $ExistingCaBundle = $null,
        $CaBundleAfterSetup = $null,
        $SimulatedCaBundleExists = $true,
        $SimulatedCaBundleValid = $true,
        [bool]$InitializeBundleThrows = $false,
        [bool]$Interactive = $false
    )
    $savedNoPause = $NoPause
    if ($Interactive) { $script:NoPause = $false }
    $script:AgentFound = $AgentFound
    $script:InstalledVersion = $InstalledVersion
    $script:TargetVersion = $TargetVersion
    $script:ExistingServer = $ExistingServer
    $script:ExistingTag = $ExistingTag
    $script:ExistingSsl = $ExistingSsl
    $script:SslAfterSetup = $SslAfterSetup
    $expectedCa = Get-OCSExpectedCaBundlePath
    $script:ExistingCaBundle = $(if ($null -ne $ExistingCaBundle) { $ExistingCaBundle } else { $expectedCa })
    $script:CaBundleAfterSetup = $(if ($null -ne $CaBundleAfterSetup) { $CaBundleAfterSetup } else { $expectedCa })
    $script:SimulatedCaBundleExists = $SimulatedCaBundleExists
    $script:SimulatedCaBundleValid = $SimulatedCaBundleValid
    $script:InitializeBundleThrows = $InitializeBundleThrows
    $script:BundleInitCalls = 0
    $script:Facts = if ($Facts) { $Facts } else { New-FakeServiceFacts }
    $script:FactsAfterSetup = if ($FactsAfterSetup) { $FactsAfterSetup } else { New-FakeServiceFacts }
    $script:SetupExitCode = $SetupExitCode
    $script:VersionAfterSetup = if ($VersionAfterSetup) { $VersionAfterSetup } else { $TargetVersion }
    $script:TagAfterSetup = $TagAfterSetup
    $script:ServerAfterSetup = $ServerAfterSetup
    $script:ProcessRelease = @{
        OCSInventory = ($ProcessesRelease -and $InventoryProcessReleases)
        OcsService   = ($ProcessesRelease -and $ServiceProcessReleases)
    }
    $script:UserWaitsForInventory = $UserWaitsForInventory
    $script:ServiceControlThrows = $ServiceControlThrows
    $script:TagRaceReads = $TagRaceReads
    $script:PostSetupConfigReads = 0
    $script:SetupDone = $false
    $script:SetupCalls = 0
    $script:InventoryCalls = 0
    $script:ServiceCommands = @()
    $script:Prompts = @()
    $script:Answers = [Collections.Generic.Queue[string]]::new()
    foreach ($answer in $Answers) { $script:Answers.Enqueue($answer) }
    if ($Interactive) { $script:Answers.Enqueue('') }
    $exitCode = $null
    $output = $null
    try {
        $output = (& { $exitCode = Invoke-InstallerMain; $exitCode } *>&1 | Out-String)
    } finally {
        $script:NoPause = $savedNoPause
    }
    $lines = @($output -split "`r?`n")
    $code = $null
    foreach ($line in $lines) { if ($line.Trim() -match '^-?\d+$') { $code = [int]$line.Trim() } }
    Write-Host ''
    Write-Host ("--- $Name (exit $code, setup $script:SetupCalls, inventario $script:InventoryCalls) ---") -ForegroundColor Cyan
    return [pscustomobject]@{
        ExitCode = $code
        Output = $output
        SetupCalls = $script:SetupCalls
        InventoryCalls = $script:InventoryCalls
        ServiceCommands = @($script:ServiceCommands)
        Prompts = @($script:Prompts)
        BundleInitCalls = $script:BundleInitCalls
        LogText = $(if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath)) { Read-Utf8File $script:LogPath } else { '' })
    }
}

try {
    # =====================================================================
    # 10. MarkedForDeletion / 1072 => RebootRequired, exit 3010, nada alterado
    # =====================================================================
    $r = Invoke-Scenario -Name '10. Servico marcado para exclusao (1072)' -Answers @('S') -Facts (New-MarkedForDeletionFacts)
    Assert-Equal 3010 $r.ExitCode '10. Exclusao pendente retorna 3010'
    Assert-Equal 0 $r.SetupCalls '10. Nenhuma instalacao, reinstalacao ou atualizacao'
    Assert-Equal 0 $r.InventoryCalls '10. Nenhum inventario solicitado'
    Assert-Equal 0 $r.ServiceCommands.Count '10. Nenhum comando enviado ao servico'
    Assert ($r.Output -match 'NECESS.RIO REINICIAR') '10. Tela amigavel de reinicializacao'
    Assert ($r.Output -match 'Nenhuma reinstala') '10. Informa que nada foi reinstalado'
    Assert ($r.Output -match 'Sua configura') '10. Informa que a configuracao foi preservada'
    Assert ($r.Output -match 'suporte: 3010') '10. Codigo de suporte visivel'
    Assert ($r.Output -notmatch 'AGENTE FOI INSTALADO') '10. Nao afirma falsamente que o agente foi instalado'
    Assert ($r.Output -notmatch '1072' -and $r.Output -notmatch 'ChangeServiceConfig') '10. Detalhes tecnicos ficam fora da tela'
    Assert ($r.LogText -match 'DeleteFlag=1') '10. DeleteFlag registrado no log'
    Assert ($r.LogText -match 'ProcessId=4242') '10. PID registrado no log'
    Assert ($r.LogText -match 'Resultado final=3010') '10. Resultado final registrado no log'

    # =====================================================================
    # 1 + 9. NotInstalled e ServiceMissing => instalacao limpa
    # =====================================================================
    $missingFacts = New-FakeServiceFacts -ServiceObjectFound $false -RegistryKeyFound $false -Status $null -StartType $null -RegistryStart $null -ImagePath $null -ImagePathExists $null
    $r = Invoke-Scenario -Name '1+9. Nao instalado, servico ausente' -Answers @('S') -AgentFound $false -InstalledVersion $null -Facts $missingFacts
    Assert-Equal 0 $r.ExitCode '1. Instalacao nova conclui com 0'
    Assert-Equal 1 $r.SetupCalls '1. Setup executado uma vez'
    Assert-Equal 1 $r.InventoryCalls '9. Inventario executado depois da instalacao'
    Assert ($r.Output -match 'ainda n.o est. instalado') '1. Informa que o OCS nao estava instalado'
    Assert ($r.Prompts.Count -eq 1) '1. Instalacao nova nao pede confirmacoes extras'
    Assert-Equal 0 $r.ServiceCommands.Count '9. Servico ausente nao recebe comando de parada antes do setup'

    # =====================================================================
    # 2 + 16. Older com atualizacao recusada => nao e erro
    # =====================================================================
    $r = Invoke-Scenario -Name '2+16. Atualizacao disponivel e recusada' -Answers @('S', 'N', 'S') -InstalledVersion '2.10.1.0'
    Assert-Equal 0 $r.ExitCode '16. Recusar atualizacao nao e erro'
    Assert-Equal 0 $r.SetupCalls '16. Nada foi instalado'
    Assert-Equal 0 $r.InventoryCalls '16. Recusar atualizacao nao dispara inventario opcional'
    Assert ($r.Output -match 'ATUALIZA' -and $r.Output -match 'DISPON') '2. Tela de atualizacao disponivel'
    Assert ($r.Output -match '2\.10\.1\.0' -and $r.Output -match '2\.11\.0\.1') '2. Mostra versao instalada e disponivel'
    Assert ($r.Prompts -contains 'Deseja atualizar o OCS Inventory Agent? [S/N]') '2. Pergunta exatamente como especificado'
    Assert ($r.LogText -match 'EstadoVersao=Older') '2. Estado Older registrado no log'
    Assert ($r.LogText -match 'recusada pelo usuario') '16. Recusa registrada no log'

    # Older aceito => atualiza e valida
    $r = Invoke-Scenario -Name '2. Atualizacao aceita' -Answers @('S', 'S') -InstalledVersion '2.10.1.0'
    Assert-Equal 0 $r.ExitCode '2. Atualizacao aceita conclui com 0'
    Assert-Equal 1 $r.SetupCalls '2. Setup executado uma vez'
    Assert ($r.ServiceCommands -contains 'Stopped') '2. Servico e parado antes do setup (evita DeleteService com processo ativo)'
    Assert ($r.LogText -match 'Aplicado=True') '2. Resultado do setup validado pela versao em disco'

    # =====================================================================
    # 3 + 17. Mesma versao e tudo correto => nenhuma reinstalacao
    # CASO A: maquina pronta + NoPause => exit 0, sem inventario
    # =====================================================================
    $r = Invoke-Scenario -Name '3+17. Mesma versao, tudo correto, NoPause' -Answers @('S')
    Assert-Equal 0 $r.ExitCode '17. Conclui com 0'
    Assert-Equal 0 $r.SetupCalls '17. Nenhuma reinstalacao'
    Assert-Equal 0 $r.InventoryCalls 'A. Maquina pronta + NoPause nao chama Invoke-OCSInventory'
    Assert ($r.Output -match 'OCS EST. PRONTO') '17. Tela "OCS esta pronto" tambem com NoPause'
    Assert ($r.LogText -match 'NoPause: maquina pronta') 'A. NoPause registra que inventario opcional nao sera solicitado'
    Assert ($r.Output -match 'Nenhuma instala..o ou atualiza..o . necess') '17. Declara que nada e necessario'
    Assert ($r.Prompts -notcontains 'Deseja executar o agente OCS e consultar o servidor agora? [S/N]') 'A. NoPause nao pergunta inventario opcional'
    Assert ($r.Output -match 'Servidor correto' -and $r.Output -match 'TAG correta') '17. Conferencia de configuracao exibida'
    Assert ($r.LogText -match 'MutationRequired=False') 'A. MutationRequired=False em maquina pronta'
    Assert ($r.LogText -match 'InventoryRequested=False') 'A. InventoryRequested=False sem -RunInventory'
    Assert ($r.LogText -match 'InventoryStarted=False') 'A. InventoryStarted=False'
    Assert ($r.LogText -match 'ConfiguracaoPronta=True|Pronta=True') 'A. ConfigurationReady=True'
    Assert ($r.LogText -match 'Resultado final=0') 'A. Exit 0 em maquina pronta'

    # Idempotencia: segunda execucao NoPause continua sem alterar
    $r = Invoke-Scenario -Name '17. Segunda execucao NoPause' -Answers @('S')
    Assert-Equal 0 $r.ExitCode '17. Segunda execucao segura conclui com 0'
    Assert-Equal 0 $r.SetupCalls '17. Segunda execucao nao reinstala'
    Assert-Equal 0 $r.InventoryCalls '17. Segunda execucao NoPause nao inventaria'
    Assert-Equal 0 $r.ServiceCommands.Count '17. Servico saudavel nao recebe comandos'

    # =====================================================================
    # 4. Newer => sem downgrade
    # =====================================================================
    $r = Invoke-Scenario -Name '4. Versao instalada mais nova' -Answers @('S', 'S') -InstalledVersion '2.12.0.0'
    Assert-Equal 0 $r.ExitCode '4. Versao mais nova nao e erro'
    Assert-Equal 0 $r.SetupCalls '4. Nenhum downgrade executado'
    Assert-Equal 0 $r.InventoryCalls '4. Versao mais nova nao dispara inventario opcional'
    Assert ($r.Output -match 'vers.o mais recente') '4. Informa que a versao instalada e mais recente'
    Assert ($r.Output -match 'Nenhum downgrade ser. realizado') '4. Declara que nao havera downgrade'
    Assert ($r.Output -match '2\.12\.0\.0') '4. Mostra a versao instalada'
    Assert ($r.LogText -match 'Downgrade bloqueado') '4. Bloqueio registrado no log'

    # =====================================================================
    # 5. Versao desconhecida => nao reinstalar cegamente
    # =====================================================================
    $r = Invoke-Scenario -Name '5. Versao instalada desconhecida' -Answers @('S', 'N', 'S') -InstalledVersion $null
    Assert-Equal 0 $r.ExitCode '5. Versao desconhecida nao e erro'
    Assert-Equal 0 $r.SetupCalls '5. Nao reinstala sem autorizacao explicita'
    Assert ($r.Prompts -contains 'Deseja reinstalar o agente com o pacote deste instalador? [S/N]') '5. Exige confirmacao explicita'
    Assert ($r.Output -match 'n.o p.de ser identificada|n.o foi poss.vel identificar a vers') '5. Informa que a versao e desconhecida'
    Assert ($r.LogText -match 'EstadoVersao=Unknown') '5. Estado Unknown registrado no log'

    # =====================================================================
    # 7 + 18. Mesma versao com servico incorreto => corrigir somente o servico
    # =====================================================================
    $disabled = New-FakeServiceFacts -Status 'Running' -StartType 'Disabled' -RegistryStart 4
    $r = Invoke-Scenario -Name '7+18. Running + Disabled' -Answers @('S', 'S') -Facts $disabled
    Assert-Equal 0 $r.ExitCode '18. Correcao do servico conclui com 0'
    Assert-Equal 0 $r.SetupCalls '18. Servico incorreto NAO provoca reinstalacao'
    Assert ($r.ServiceCommands -contains 'Running') '18. Servico foi colocado em execucao com inicio automatico'
    Assert-Equal 1 $r.InventoryCalls '18. Inventario executado depois da correcao'
    Assert ($r.Output -match 'n.o voltaria no pr.ximo boot') '7. Explica o risco do inicio Disabled'
    Assert ($r.Prompts -contains 'Deseja corrigir o servico e consultar o servidor agora? [S/N]') '18. Pergunta especifica de correcao do servico'
    Assert ($r.LogText -match 'Estado=RunningDisabled') '7. Estado do servico registrado no log'

    # Correcao recusada: nada e alterado
    $r = Invoke-Scenario -Name '18. Correcao do servico recusada' -Answers @('S', 'N') -Facts $disabled
    Assert-Equal 0 $r.ExitCode '18. Recusa nao e erro'
    Assert-Equal 0 $r.SetupCalls '18. Recusa nao reinstala'
    Assert-Equal 0 $r.ServiceCommands.Count '18. Recusa nao envia comandos ao servico'
    Assert-Equal 0 $r.InventoryCalls '18. Recusa nao inventaria'

    # =====================================================================
    # 8. Stopped + Automatic => iniciar somente o servico
    # =====================================================================
    $stopped = New-FakeServiceFacts -Status 'Stopped' -StartType 'Automatic'
    $r = Invoke-Scenario -Name '8. Stopped + Automatic' -Answers @('S', 'S') -Facts $stopped
    Assert-Equal 0 $r.ExitCode '8. Conclui com 0'
    Assert-Equal 0 $r.SetupCalls '8. Servico parado nao provoca reinstalacao'
    Assert ($r.ServiceCommands -contains 'Running') '8. Servico foi iniciado'
    Assert ($r.LogText -match 'Estado=StoppedAutomatic') '8. Estado StoppedAutomatic registrado no log'

    # =====================================================================
    # 14. TAG diferente => exige confirmacao
    # =====================================================================
    $r = Invoke-Scenario -Name '14. TAG diferente, recusada' -Answers @('S', 'N') -ExistingTag 'OTHER'
    Assert-Equal 2 $r.ExitCode '14. Recusa cancela sem alterar'
    Assert-Equal 0 $r.SetupCalls '14. TAG nunca muda sem confirmacao'
    Assert-Equal 0 $r.InventoryCalls '14. Nao inventaria para o cliente errado'
    Assert ($r.Output -match 'ATEN..O . CONFIGURA..O') '14. Tela de atencao a configuracao'
    Assert ($r.Output -match 'TAG: OTHER' -and $r.Output -match 'TAG: CLIENT-A') '14. Mostra TAG atual e selecionada'
    Assert ($r.Prompts -contains 'Deseja realmente alterar este computador para CLIENT-A? [S/N]') '14. Pergunta exatamente como especificado'
    Assert ($r.LogText -match 'Troca de TAG recusada') '14. Recusa registrada no log'

    $r = Invoke-Scenario -Name '14. TAG diferente, autorizada' -Answers @('S', 'S') -ExistingTag 'OTHER'
    Assert-Equal 0 $r.ExitCode '14. Autorizacao explicita conclui com 0'
    Assert-Equal 1 $r.SetupCalls '14. TAG e reaplicada pelo instalador oficial'
    Assert ($r.LogText -match 'Troca de TAG autorizada') '14. Autorizacao registrada no log'

    # =====================================================================
    # 15. SERVER diferente => exige confirmacao
    # =====================================================================
    $r = Invoke-Scenario -Name '15. Servidor diferente, recusado' -Answers @('S', 'N') -ExistingServer 'https://outro.example/ocsinventory'
    Assert-Equal 2 $r.ExitCode '15. Recusa cancela sem alterar'
    Assert-Equal 0 $r.SetupCalls '15. Servidor nunca muda sem confirmacao'
    Assert ($r.Prompts -contains 'Deseja realmente alterar o servidor deste computador? [S/N]') '15. Pergunta especifica de servidor'
    Assert ($r.Output -match 'Servidor diferente do selecionado') '15. Informa divergencia de servidor'

    # Configuracao atual ilegivel tambem exige confirmacao
    $r = Invoke-Scenario -Name '15. Configuracao atual ilegivel' -Answers @('S', 'N') -ExistingTag $null -ExistingServer $null
    Assert-Equal 2 $r.ExitCode '15. Configuracao desconhecida exige confirmacao'
    Assert-Equal 0 $r.SetupCalls '15. Nada e alterado sem confirmacao'
    Assert ($r.Output -match 'n.o p.de ser determinad') '15. Informa que nao conseguiu ler a configuracao'

    # =====================================================================
    # 12. Setup exit 3010 => reboot required
    # =====================================================================
    $r = Invoke-Scenario -Name '12. Setup retornou 3010' -Answers @('S', 'S') -InstalledVersion '2.10.1.0' -SetupExitCode 3010
    Assert-Equal 3010 $r.ExitCode '12. Setup 3010 propaga 3010'
    Assert-Equal 1 $r.SetupCalls '12. Setup executado'
    Assert-Equal 0 $r.InventoryCalls '12. Setup 3010 nao dispara consulta ao servidor'
    Assert ($r.Output -match 'Reinicializa..o necess') '12. Resume deixa claro que falta reiniciar'
    Assert ($r.LogText -match 'Setup retornou 3010') '12. Registrado no log'
    Assert ($r.LogText -match 'RebootRequired=True') '12. RebootRequired permanece no log'
    Assert ($r.LogText -match 'Resultado final=3010') '12. Codigo 3010 e o resultado externo do PS1'

    # =====================================================================
    # 13. Setup exit 0 mas versao continua antiga => nao declarar sucesso
    # =====================================================================
    $r = Invoke-Scenario -Name '13. Setup 0 sem efeito' -Answers @('S', 'S') -InstalledVersion '2.10.1.0' -VersionAfterSetup '2.10.1.0'
    Assert-Equal 31 $r.ExitCode '13. Codigo dedicado para atualizacao nao aplicada'
    Assert-Equal 0 $r.InventoryCalls '13. Nao inventaria declarando sucesso'
    Assert ($r.Output -notmatch 'OPERA..O CONCLU') '13. Nao exibe resumo de sucesso'
    Assert ($r.LogText -match 'Aplicado=False') '13. Resultado real registrado no log'

    # Configuracao nao persistida recebe codigo proprio
    $r = Invoke-Scenario -Name '32. TAG nao persistida' -Answers @('S', 'S') -ExistingTag 'OTHER' -TagAfterSetup 'OTHER'
    Assert-Equal 32 $r.ExitCode 'Configuracao nao persistida usa codigo proprio (32)'
    Assert-Equal 2 $r.SetupCalls '32. Uma reaplicacao e tentada antes de declarar falha'

    # Inventario automatico reescreveu a TAG antiga; uma reaplicacao corrige.
    $r = Invoke-Scenario -Name 'Corrida da TAG apos inventario automatico' -Answers @('S', 'S') -ExistingTag 'OTHER' -TagAfterSetup 'CLIENT-A' -TagRaceReads 1
    Assert-Equal 0 $r.ExitCode 'Corrida da TAG e corrigida pela reaplicacao'
    Assert-Equal 2 $r.SetupCalls 'Corrida da TAG provoca exatamente uma reaplicacao'
    Assert ($r.LogText -match 'Reaplicando uma vez a configuracao autorizada') 'Corrida da TAG registrada no log'

    # =====================================================================
    # 41. Registro do servico incompleto => exige reinstalacao autorizada
    # =====================================================================
    $corrupt = New-FakeServiceFacts -ImagePathExists $false
    $r = Invoke-Scenario -Name '41. Servico corrompido, reinstalacao recusada' -Answers @('S', 'N') -Facts $corrupt
    Assert-Equal 41 $r.ExitCode '41. Servico incompleto usa codigo proprio'
    Assert-Equal 0 $r.SetupCalls '41. Recusa nao reinstala'
    Assert-Equal 0 $r.InventoryCalls '41. Recusa nao inventaria'
    Assert ($r.Output -match 'SERVI.O PRECISA SER RECRIADO') '41. Tela explicando que o servico precisa ser recriado'
    Assert ($r.Output -match '(?s)registro do\s+servi.o do Windows est. incompleto') '41. Explica o registro incompleto'
    Assert ($r.Prompts -contains 'Deseja reinstalar o agente para recriar o servico? [S/N]') '41. Exige autorizacao explicita'
    Assert ($r.Output -notmatch 'AGENTE FOI INSTALADO') '41. Nao afirma que o agente foi instalado'
    Assert ($r.LogText -match 'Estado=CorruptOrIncomplete') '41. Estado registrado no log'
    Assert ($r.LogText -match 'RecriacaoNecessaria=True') '41. Decisao de recriacao registrada no log'

    $r = Invoke-Scenario -Name '41. Servico corrompido, reinstalacao autorizada' -Answers @('S', 'S') -Facts $corrupt
    Assert-Equal 0 $r.ExitCode '41. Reinstalacao autorizada recria o servico e conclui com 0'
    Assert-Equal 1 $r.SetupCalls '41. Setup executado para recriar o servico'
    Assert ($r.LogText -match 'recriar o servico. Estado de origem: CorruptOrIncomplete') '41. Autorizacao registrada no log'

    # Servico corrompido com versao mais nova: nao ha como recriar sem downgrade
    $r = Invoke-Scenario -Name '41. Servico corrompido com versao mais nova' -Answers @('S') -Facts $corrupt -InstalledVersion '2.12.0.0'
    Assert-Equal 41 $r.ExitCode '41. Downgrade nao e usado para recriar o servico'
    Assert-Equal 0 $r.SetupCalls '41. Nenhum downgrade executado'
    Assert ($r.LogText -match 'exigiria downgrade') '41. Motivo registrado no log'

    # =====================================================================
    # Estado real apos o reboot que concluiu a exclusao pendente:
    # agente instalado, versao correta, configuracao correta, SERVICO AUSENTE.
    # =====================================================================
    $agentWithoutService = New-FakeServiceFacts -ServiceObjectFound $false -RegistryKeyFound $false -Status $null -StartType $null -RegistryStart $null -ImagePath $null -ImagePathExists $null
    $r = Invoke-Scenario -Name 'Pos-reboot: agente instalado sem servico, recusado' -Answers @('S', 'N') -Facts $agentWithoutService
    Assert-Equal 41 $r.ExitCode 'Pos-reboot: servico ausente com agente instalado usa codigo 41'
    Assert-Equal 0 $r.SetupCalls 'Pos-reboot: recusa nao reinstala'
    Assert-Equal 0 $r.InventoryCalls 'Pos-reboot: nao tenta inventariar sem servico'
    Assert-Equal 0 $r.ServiceCommands.Count 'Pos-reboot: nenhum comando enviado a um servico inexistente'
    Assert ($r.Output -match 'SERVI.O PRECISA SER RECRIADO') 'Pos-reboot: tela dedicada em vez de erro generico'
    Assert ($r.Output -match 'remo..o pendente do servi.o') 'Pos-reboot: explica a origem do problema'
    Assert ($r.Output -match 'ser.o preservada') 'Pos-reboot: garante preservacao da configuracao e identidade'
    Assert ($r.Output -notmatch 'n.o est. registrado no Windows\.$') 'Pos-reboot: nao termina com erro tecnico de servico'
    Assert ($r.LogText -match 'Estado=ServiceMissing') 'Pos-reboot: estado registrado no log'

    $r = Invoke-Scenario -Name 'Pos-reboot: agente instalado sem servico, autorizado' -Answers @('S', 'S') -Facts $agentWithoutService
    Assert-Equal 0 $r.ExitCode 'Pos-reboot: reinstalacao autorizada conclui com 0'
    Assert-Equal 1 $r.SetupCalls 'Pos-reboot: setup executado para recriar o servico'
    Assert-Equal 1 $r.InventoryCalls 'Pos-reboot: inventario enviado depois de recriar o servico'
    Assert ($r.LogText -match 'recriar o servico. Estado de origem: ServiceMissing') 'Pos-reboot: origem da decisao registrada no log'

    # =====================================================================
    # Mensagem final honesta quando nada foi instalado
    # =====================================================================
    $r = Invoke-Scenario -Name 'Falha de servico sem instalacao' -Answers @('S', 'S') -Facts $disabled -ServiceControlThrows $true
    Assert-Equal 40 $r.ExitCode 'Falha de servico retorna 40'
    Assert-Equal 0 $r.SetupCalls 'Nenhuma instalacao foi tentada'
    Assert ($r.Output -notmatch 'AGENTE FOI INSTALADO') 'Nao afirma que o agente foi instalado quando nao foi'
    Assert ($r.Output -match 'Nenhuma instala..o foi realizada nesta execu') 'Informa explicitamente que nada foi instalado'
    Assert ($r.LogText -match 'SetupExecutado=False') 'Log registra que o setup nao rodou'

    # =====================================================================
    # 42. Inventario em andamento => "agente ocupado", NUNCA "reinicie"
    # =====================================================================
    $r = Invoke-Scenario -Name '42. Inventario em andamento, usuario nao aguarda' -Answers @('S', 'S') -InstalledVersion '2.10.1.0' -InventoryProcessReleases $false
    Assert-Equal 42 $r.ExitCode '42. Inventario em andamento usa codigo proprio, nao 3010'
    Assert-Equal 0 $r.SetupCalls '42. Setup nao roda com os arquivos em uso'
    Assert-Equal 0 $r.InventoryCalls '42. Nenhum inventario adicional e disparado'
    Assert ($r.Output -match 'AGENTE EST. OCUPADO') '42. Tela dedicada de agente ocupado'
    Assert ($r.Output -match 'N.O . necess.rio reiniciar') '42. Diz explicitamente que nao precisa reiniciar'
    Assert ($r.Output -notmatch 'NECESS.RIO REINICIAR\s*$') '42. Nao usa a tela de reinicializacao'
    Assert ($r.Output -match 'Nada foi alterado') '42. Garante que nada foi alterado'
    Assert ($r.Output -match 'IpDiscover') '42. Explica por que o inventario demora'
    Assert ($r.LogText -match 'Nenhuma alteracao pendente do Windows') '42. Log separa "ocupado" de "alteracao pendente"'
    Assert ($r.LogText -match 'ExitCode=42 Reason=') '42. Motivo objetivo registrado no log'
    Assert ($r.LogText -notmatch 'Reinicializacao necessaria') '42. Log nao registra reinicializacao necessaria'

    # Se o usuario aceita aguardar e o inventario termina, o fluxo continua.
    $r = Invoke-Scenario -Name '42. Inventario termina durante a espera autorizada' -Answers @('S', 'S') -InstalledVersion '2.10.1.0' -InventoryProcessReleases $false -UserWaitsForInventory $true
    Assert-Equal 0 $r.ExitCode '42. Espera autorizada permite concluir normalmente'
    Assert-Equal 1 $r.SetupCalls '42. Setup roda depois que o inventario termina'

    # =====================================================================
    # OcsService preso apos a parada => risco real de 1072 => 3010
    # =====================================================================
    $r = Invoke-Scenario -Name 'OcsService nao saiu depois da parada' -Answers @('S', 'S') -InstalledVersion '2.10.1.0' -ServiceProcessReleases $false
    Assert-Equal 3010 $r.ExitCode 'Processo do servico preso resulta em 3010'
    Assert-Equal 0 $r.SetupCalls 'Setup nunca roda antes do DeleteService com processo ativo'
    Assert ($r.Output -match 'NECESS.RIO REINICIAR') 'Usuario recebe orientacao de reinicializacao'
    Assert ($r.LogText -match 'ERROR_SERVICE_MARKED_FOR_DELETE|permaneceu ativo') 'Motivo tecnico registrado no log'

    # =====================================================================
    # Servico em transicao (StartPending) => aguardar, nunca instalar em cima
    # =====================================================================
    $ServiceSettleWaitSeconds = 0
    $pending = New-FakeServiceFacts -Status 'StartPending'
    $r = Invoke-Scenario -Name 'Servico em StartPending sem mutacao obrigatoria' -Answers @('S') -Facts $pending
    Assert-Equal 0 $r.ExitCode 'StartPending sem mutacao nao retorna 42'
    Assert-Equal 0 $r.SetupCalls 'Nenhum setup sobre servico em transicao sem mutacao'
    Assert-Equal 0 $r.InventoryCalls 'Nenhum inventario sobre servico em transicao sem pedido explicito'
    Assert ($r.Output -match 'iniciando|em transi..o') 'Informa que o servico esta em transicao'
    Assert ($r.Output -notmatch 'AGENTE EST. OCUPADO') 'Nao trata transicao sem mutacao como agente ocupado'
    Assert ($r.LogText -match 'EmTransicao=True') 'Transicao registrada no log'
    Assert ($r.LogText -match 'codigo 42 nao se aplica') '42 nao e usado sem mutacao obrigatoria'
    Assert ($r.LogText -match 'MutationRequired=False') 'StartPending saudavel de configuracao => MutationRequired=False'

    # Troca de TAG autorizada mas nao aplicada precisa ser dita na tela.
    $r = Invoke-Scenario -Name 'Servico em transicao com troca de TAG autorizada' -Answers @('S', 'S') -Facts $pending -ExistingTag 'OTHER'
    Assert-Equal 42 $r.ExitCode 'Troca autorizada nao aplicada retorna 42'
    Assert ($r.LogText -match 'ExitCode=42 Reason=') '42. Troca bloqueada registra Reason'
    Assert ($r.Output -match 'NÃO foi aplicada|N.O foi aplicada') 'Diz que a troca autorizada nao foi aplicada'
    Assert ($r.Output -match 'continua OTHER') 'Mostra a TAG que permaneceu'

    # =====================================================================
    # TESTE 13. Config de outro cliente nao aplicada => sem inventario falso
    # =====================================================================
    $r = Invoke-Scenario -Name '13. TAG de outro cliente, troca recusada' -Answers @('S', 'N') -ExistingTag 'OTHER'
    Assert-Equal 2 $r.ExitCode '13. Recusa nao troca o cliente'
    Assert-Equal 0 $r.SetupCalls '13. Nenhuma reconfiguracao'
    Assert-Equal 0 $r.InventoryCalls '13. Nao inventaria para o cliente do menu'
    Assert ($r.Output -notmatch 'OPERA..O CONCLU') '13. Nao mostra sucesso da configuracao selecionada'
    Assert ($r.LogText -match 'Pronta=False') '13. ConfigurationReady=False no log'
    Assert ($r.Output -notmatch 'foi configurado') '13. Nao afirma que o cliente do menu foi configurado'

    $savedIndex = $ClientIndex
    $ClientIndex = 2
    $r = Invoke-Scenario -Name '13. Selecionado B, efetivo A' -Answers @('S', 'N') -ExistingTag 'CLIENT-A'
    Assert-Equal 2 $r.ExitCode '13. Selecionado B e efetivo A: recusa cancela'
    Assert-Equal 0 $r.SetupCalls '13. Selecionado B nao reconfigura A'
    Assert-Equal 0 $r.InventoryCalls '13. Selecionado B nao executa o agente'
    Assert ($r.LogText -match 'Pronta=False') '13. Selecionado B / efetivo A => ConfigurationReady=False'
    Assert ($r.LogText -match 'ClientTag=CLIENT-B') '13. Log registra o cliente selecionado B'
    Assert ($r.LogText -match 'TagAtual=CLIENT-A') '13. Log registra a TAG efetiva A'
    $ClientIndex = $savedIndex

    $r = Invoke-Scenario -Name '13. Troca autorizada mas bloqueada por versao mais nova' -Answers @('S', 'S') -InstalledVersion '2.12.0.0' -ExistingTag 'OTHER'
    Assert-Equal 0 $r.ExitCode '13. Nao e erro recusar downgrade'
    Assert-Equal 0 $r.SetupCalls '13. Nenhum downgrade para aplicar a TAG'
    Assert-Equal 0 $r.InventoryCalls '13. Sem inventario para o cliente selecionado'
    Assert ($r.Output -match 'N.O foi aplicada|nao foi aplicada') '13. Diz que a configuracao selecionada nao foi aplicada'
    Assert ($r.Output -match 'TAG efetiva' -and $r.Output -match 'OTHER') '13. Resume mostra a TAG real da maquina'

    # =====================================================================
    # TESTE 14. SERVER e TAG corretos, SSL=0 => configuracao nao pronta
    # =====================================================================
    $r = Invoke-Scenario -Name '14. SSL desabilitado, correcao recusada' -Answers @('S', 'N') -ExistingSsl '0'
    Assert-Equal 2 $r.ExitCode '14. Recusar correcao de SSL cancela'
    Assert-Equal 0 $r.SetupCalls '14. SSL incorreto nao e ignorado'
    Assert-Equal 0 $r.InventoryCalls '14. Nao inventaria com SSL=0'
    Assert ($r.Output -match 'SSL atual . 0') '14. Informa o SSL efetivo'
    Assert ($r.LogText -match 'Pronta=False') '14. SERVER+TAG corretos com SSL=0 => ConfigurationReady=False'

    $r = Invoke-Scenario -Name '14. SSL desabilitado, correcao autorizada' -Answers @('S', 'S') -ExistingSsl '0'
    Assert-Equal 0 $r.ExitCode '14. Correcao de SSL conclui com 0'
    Assert-Equal 1 $r.SetupCalls '14. Setup reaplica a configuracao com TLS'
    Assert-Equal 1 $r.InventoryCalls '14. Inventario so depois de SSL efetivo=1'
    Assert ($r.LogText -match 'Correcao de SSL autorizada') '14. Autorizacao de SSL no log'

    # SERVER equivalente (case + barra) nao dispara reconfiguracao
    $r = Invoke-Scenario -Name '16. SERVER equivalente case/barra' -Answers @('S', 'N') -ExistingServer 'https://OCS.EXAMPLE.COM/ocsinventory/'
    Assert-Equal 0 $r.ExitCode '16. SERVER equivalente nao e tratado como troca'
    Assert-Equal 0 $r.SetupCalls '16. Nenhuma reconfiguracao por case ou barra final'
    Assert-Equal 0 $r.InventoryCalls '16. Inventario recusado permanece 0'
    Assert ($r.LogText -match 'Pronta=True') '16. ConfigurationReady=True com SERVER equivalente'

    $expectedCa = Get-OCSExpectedCaBundlePath
    $legacyCa = Join-Path $AgentDataDirectory 'legacy-cacert.pem'

    $r = Invoke-Scenario -Name '17. SERVER/TAG/SSL corretos com legacy-cacert.pem' -Answers @('S', 'S') -ExistingCaBundle $legacyCa -SimulatedCaBundleExists $false
    Assert-Equal 0 $r.ExitCode '17. Migracao de CA conclui com 0'
    Assert-Equal 1 $r.SetupCalls '17. Reaplica configuracao pelo instalador oficial'
    Assert-Equal 1 $r.BundleInitCalls '17. Gera o novo bundle'
    Assert-Equal 1 $r.InventoryCalls '17. Inventario so depois da migracao'
    Assert ($r.Output -match 'migracao necessaria') '17. Informa migracao tecnica, nao troca de cliente'
    Assert ($r.Output -notmatch 'alterar este computador') '17. Nao pergunta troca de cliente'
    Assert ($r.LogText -match 'CaMigrationRequired=True') '17. Antes da migracao, CA exige atualizacao'
    Assert ($r.LogText -match 'Pronta=True') '17. Depois da migracao, Pronta=True'
    Assert ($r.LogText -match 'legacy-cacert\.pem') '17. Log registra o bundle legado'
    Assert ($r.LogText -match 'ocs-cacert\.pem') '17. Log registra o bundle esperado'

    $savedDryRun = $DryRun
    $DryRun = $true
    $r = Invoke-Scenario -Name '17. DryRun com legacy-cacert.pem' -Answers @() -ExistingCaBundle $legacyCa -SimulatedCaBundleExists $false
    $DryRun = $savedDryRun
    Assert-Equal 0 $r.ExitCode '17. DryRun com CA legada retorna 0'
    Assert-Equal 0 $r.SetupCalls '17. DryRun nao executa setup'
    Assert-Equal 0 $r.BundleInitCalls '17. DryRun nao gera ocs-cacert.pem'
    Assert-Equal 0 $r.InventoryCalls '17. DryRun nao inventaria'
    Assert ($r.LogText -match 'Pronta=False') '17. DryRun: ConfigurationReady=False'
    Assert ($r.LogText -match 'CaMigrationRequired=True') '17. DryRun registra migracao necessaria'
    Assert ($r.LogText -match 'seria necessario gerar o novo bundle CA') '17. DryRun descreve a migracao'
    Assert ($r.LogText -notmatch 'exigiria confirmacao explicita antes de alterar TAG') '17. DryRun nao trata CA como troca de cliente'

    $r = Invoke-Scenario -Name '17. Falha ao gerar bundle CA' -Answers @('S') -ExistingCaBundle $legacyCa -SimulatedCaBundleExists $false -InitializeBundleThrows $true
    Assert-Equal 30 $r.ExitCode '17. Falha na geracao do bundle nao inventaria'
    Assert-Equal 0 $r.SetupCalls '17. Setup nao corre se o bundle nao foi gerado'
    Assert-Equal 0 $r.InventoryCalls '17. Sem inventario apos falha do bundle'
    Assert ($r.LogText -match 'Pronta=False|Falha simulada ao gerar bundle CA') '17. Falha de bundle registrada'

    $r = Invoke-Scenario -Name '17. Falha ao aplicar CaBundle no INI' -Answers @('S') -ExistingCaBundle $legacyCa -CaBundleAfterSetup $legacyCa -SimulatedCaBundleExists $false
    Assert-Equal 32 $r.ExitCode '17. INI nao atualizado => configuracao nao persistida'
    Assert-Equal 0 $r.InventoryCalls '17. Sem inventario se CaBundle nao foi aplicado'
    Assert ($r.LogText -match 'Pronta=False|nao correspondem') '17. Pronta permanece False se o INI ficou legado'

    $r = Invoke-Scenario -Name '17. CaBundle ausente no INI' -Answers @('S', 'S') -ExistingCaBundle ''
    Assert-Equal 0 $r.ExitCode '17. CaBundle ausente e migrado'
    Assert-Equal 1 $r.SetupCalls '17. CaBundle ausente dispara reaplicacao'
    Assert ($r.LogText -match 'CaMigrationRequired=True') '17. Ausencia de CaBundle exige migracao'

    $r = Invoke-Scenario -Name '17. CaBundle esperado mas arquivo ausente' -Answers @('S', 'S') -SimulatedCaBundleExists $false
    Assert-Equal 0 $r.ExitCode '17. Arquivo ausente e gerado'
    Assert-Equal 1 $r.SetupCalls '17. Caminho correto sem arquivo ainda migra'
    Assert-Equal 1 $r.BundleInitCalls '17. Gera o arquivo ausente'

    $r = Invoke-Scenario -Name '17. CaBundle correto e arquivo valido' -Answers @('S', 'N')
    Assert-Equal 0 $r.ExitCode '17. Bundle ja correto nao e erro'
    Assert-Equal 0 $r.SetupCalls '17. Nenhuma migracao quando CA ja esta pronta'
    Assert-Equal 0 $r.BundleInitCalls '17. Nao regenera bundle correto'
    Assert ($r.LogText -match 'Pronta=True') '17. CaBundle esperado + arquivo valido => Pronta=True'
    Assert ($r.LogText -match 'CaMigrationRequired=False') '17. Sem migracao quando o bundle ja confere'

    $mixedCaseCa = $expectedCa.ToLowerInvariant()
    $r = Invoke-Scenario -Name '17. CaBundle equivalente so no case' -Answers @('S', 'N') -ExistingCaBundle $mixedCaseCa
    Assert-Equal 0 $r.ExitCode '17. Case do path Windows nao e divergencia'
    Assert-Equal 0 $r.SetupCalls '17. Case diferente nao dispara migracao'
    Assert ($r.LogText -match 'Pronta=True') '17. Path equivalente em case => Pronta=True'

    # =====================================================================
    # Idempotencia / inventario explicito / codigo 42
    # =====================================================================
    $savedRunInventory = $RunInventory
    $RunInventory = $true
    $r = Invoke-Scenario -Name 'C. Maquina pronta + RunInventory' -Answers @('S')
    $RunInventory = $savedRunInventory
    Assert-Equal 0 $r.ExitCode 'C. RunInventory em maquina pronta conclui com 0'
    Assert-Equal 0 $r.SetupCalls 'C. RunInventory nao reinstala'
    Assert-Equal 1 $r.InventoryCalls 'C. RunInventory solicita inventario'
    Assert ($r.LogText -match 'InventoryRequested=True') 'C. InventoryRequested=True'
    Assert ($r.LogText -match 'MutationRequired=False') 'C. Mutacao continua desnecessaria'

    $savedRunInventory = $RunInventory
    $RunInventory = $true
    $r = Invoke-Scenario -Name 'D. RunInventory com inventario ja ativo' -Answers @('S') -InventoryProcessReleases $false
    $RunInventory = $savedRunInventory
    Assert-Equal 0 $r.ExitCode 'D. Inventario ja ativo nao e falha da configuracao'
    Assert-Equal 0 $r.SetupCalls 'D. Nenhuma reinstalacao'
    Assert-Equal 0 $r.InventoryCalls 'D. Nao dispara segundo inventario'
    Assert ($r.Output -match 'j. existe um invent') 'D. Informa inventario ja em execucao'
    Assert ($r.LogText -match 'InventoryAlreadyRunning=True') 'D. InventoryAlreadyRunning=True'
    Assert ($r.LogText -match 'InventoryStarted=False') 'D. InventoryStarted=False'
    Assert ($r.LogText -notmatch 'ExitCode=42 Reason=') 'D. Nao usa 42 so porque o inventario ja corre'
    Assert ($r.Output -notmatch 'AGENTE EST. OCUPADO') 'D. Nao trata inventario ativo como bloqueio'

    $savedNoPause = $NoPause
    $NoPause = $false
    $r = Invoke-Scenario -Name 'B. Interativo recusa inventario' -Answers @('S', 'N') -Interactive $true
    $NoPause = $savedNoPause
    Assert-Equal 0 $r.ExitCode 'B. Recusar inventario interativo e sucesso'
    Assert-Equal 0 $r.SetupCalls 'B. Recusa nao reinstala'
    Assert-Equal 0 $r.InventoryCalls 'B. Recusa nao chama Invoke-OCSInventory'
    Assert ($r.Prompts -contains 'Deseja executar o agente OCS e consultar o servidor agora? [S/N]') 'B. Pergunta inventario no modo interativo'
    Assert ($r.LogText -match 'InventoryRequested=False') 'B. InventoryRequested=False apos recusa'
    Assert ($r.LogText -match 'Resultado final=0') 'B. Exit 0'

    $r = Invoke-Scenario -Name 'E. Atualizacao bloqueada por inventario ativo' -Answers @('S', 'S') -InstalledVersion '2.10.1.0' -InventoryProcessReleases $false
    Assert-Equal 42 $r.ExitCode 'E. Mutacao obrigatoria bloqueada permanece 42'
    Assert-Equal 0 $r.SetupCalls 'E. Setup nao corre com inventario ativo'
    Assert-Equal 0 $r.InventoryCalls 'E. Nenhum inventario adicional'
    Assert ($r.LogText -match 'ExitCode=42 Reason=') 'E. Reason objetivo no log'
    Assert ($r.LogText -match 'MutationRequired=True') 'E. MutationRequired=True'

    $r = Invoke-Scenario -Name 'F. Instalacao nova com inventario automatico ja ativo' -Answers @('S') -AgentFound $false -InstalledVersion $null -Facts $missingFacts -InventoryProcessReleases $false
    Assert-Equal 0 $r.ExitCode 'F. Instalacao nova conclui com 0 mesmo com inventario automatico'
    Assert-Equal 1 $r.SetupCalls 'F. Setup da instalacao nova executou'
    Assert-Equal 0 $r.InventoryCalls 'F. Nao inicia segundo inventario'
    Assert ($r.LogText -match 'InventoryAlreadyRunning=True') 'F. Inventario automatico registrado'
    Assert ($r.LogText -match 'InventoryStarted=False') 'F. InventoryStarted=False'
    Assert ($r.LogText -notmatch 'ExitCode=42 Reason=') 'F. Inventario automatico nao vira 42'

    $savedDryRun = $DryRun
    $DryRun = $true
    $r = Invoke-Scenario -Name '9. DryRun maquina pronta' -Answers @()
    $DryRun = $savedDryRun
    Assert-Equal 0 $r.ExitCode '9. DryRun de maquina pronta retorna 0'
    Assert-Equal 0 $r.SetupCalls '9. DryRun nao muta'
    Assert-Equal 0 $r.InventoryCalls '9. DryRun nao inventaria'
    Assert-Equal 0 $r.BundleInitCalls '9. DryRun nao gera bundle'
    Assert ($r.LogText -match 'MutationRequired=False') '9. DryRun MutationRequired=False'
    Assert ($r.LogText -match 'InventoryStarted=False') '9. DryRun InventoryStarted=False'
    Assert ($r.LogText -match 'Pronta=True') '9. DryRun Pronta=True'
    Assert ($r.LogText -match 'DryRun: nenhum arquivo OCS') '9. DryRun declara ausencia de mutacao'

    Write-TestTotal 'Test-ExistingInstallationFlow'
} finally {
    $env:ProgramData = $savedProgramData
}

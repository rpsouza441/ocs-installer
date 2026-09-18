#requires -Version 5.1
[CmdletBinding()]
param(
    # Indice temporario do menu nesta execucao. NAO e identificador persistente.
    # Alias ClientId mantido so para nao quebrar chamadas antigas.
    [Alias('ClientId')]
    [int]$ClientIndex,
    # Identificador estavel para automacao: TAG unica do cliente.
    [string]$ClientTag,
    [switch]$DryRun,
    [string]$ClientsPath,
    [switch]$NoPause,
    # Solicita inventario ao final. Independente de -NoPause.
    [switch]$RunInventory
)

$script:ClientIndexSpecified = $PSBoundParameters.ContainsKey('ClientIndex')

if (-not $ClientsPath) { $ClientsPath = Join-Path $PSScriptRoot 'clients.json' }

# ---------------------------------------------------------------------------
# Pacotes do agente.
# A versao alvo NAO fica fixa no codigo: e lida do FileVersion do EXE
# selecionado por Resolve-OCSTargetVersion. O fallback abaixo existe apenas
# para o cenario de download, quando o arquivo ainda nao esta em disco.
# ---------------------------------------------------------------------------
$AgentVersionFallback = '2.11.0.1'
$AgentVersion = $null
$InstallerPackages = @{
    x64 = @{ FileName = 'OCS-Windows-Agent-Setup-x64.exe'; Url = ''; SHA256 = ''; Publisher = '' }
    x86 = @{ FileName = 'OCS-Windows-Agent-Setup-x86.exe'; Url = ''; SHA256 = ''; Publisher = '' }
}
$InstallerUrl = ''
$InstallerFileName = 'OCS-Windows-Agent-Setup.exe'
$UniversalInstallerFileName = 'OCS-Windows-Agent-Setup.exe'
$InstallerSHA256 = ''
$InstallerPublisher = ''
$InstallerArchitecture = 'universal' # universal, x64 ou x86
$ProcessTimeoutSeconds = 1800
# Um inventario com IpDiscover leva vários minutos. A primeira espera e curta e
# silenciosa; depois dela o tecnico decide, em rodadas, se continua aguardando.
$InventoryQuietWaitSeconds = 30
$InventoryWaitRoundSeconds = 120
$InventoryMaxWaitSeconds = 900
# Um servico em StartPending/StopPending esta em transicao: aguardar antes de
# classificar, em vez de decidir sobre um estado instantaneo. Depois do setup
# o servico pode permanecer em StartPending por alguns minutos enquanto o
# agente executa o inventario automatico (IpDiscover).
$ServiceSettleWaitSeconds = 60
$PostSetupSettleWaitSeconds = 180
$ServiceName = 'OCS Inventory Service'
$AgentDataDirectory = Join-Path $env:ProgramData 'OCS Inventory NG\Agent'
# Bundle de CAs publicas da Windows Store. Nao e certificado do servidor
# nem CA privada da organizacao.
$CaBundleFileName = 'ocs-cacert.pem'

# ---------------------------------------------------------------------------
# Codigos Win32 e sinalizacao interna.
# ---------------------------------------------------------------------------
$ErrorServiceMarkedForDelete = 1072   # ERROR_SERVICE_MARKED_FOR_DELETE
$OCSRebootRequiredTag = 'OCS_REBOOT_REQUIRED'
$OCSAgentBusyTag = 'OCS_AGENT_BUSY'

# ---------------------------------------------------------------------------
# Codigos de saida. Cada codigo tem um significado unico (ver README).
# ---------------------------------------------------------------------------
$ExitSuccess = 0
$ExitInitialization = 1
$ExitUserCancel = 2
$ExitElevation = 5
$ExitClientConfig = 10
$ExitPackage = 20
$ExitSetupFailed = 30
$ExitUpdateNotApplied = 31
$ExitConfigNotPersisted = 32
$ExitServiceFailed = 40
$ExitServiceCorrupt = 41
$ExitAgentBusy = 42
$ExitInventoryFailed = 50
$ExitRebootRequired = 3010

$script:LogPath = $null
$script:Stage = 'Inicializacao'
$script:ResultCode = $ExitInitialization
$script:RebootRequired = $false
$script:RebootTechnicalDetails = $null
$script:AgentBusyDetails = $null
$script:InventoryResult = 'Nao executado'
$script:InventoryAgentExecution = 'Nao executado'
$script:InventoryServerContact = 'Nao confirmado'
$script:InventorySent = 'Nao foi possivel confirmar'
$script:InventoryRequested = $false
$script:InventoryAlreadyRunning = $false
$script:InventoryStarted = $false
$script:MutationRequired = $false
$script:SetupPerformed = $false
$script:AutoInventoryCompleted = $false
$script:ConfigurationReady = $false
$script:StepIndex = 0
$script:StepTotal = 5

function Get-OCSPackageArchitecture {
    param(
        [bool]$Is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem,
        [string]$NativeArchitecture = $(if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE })
    )
    if ($NativeArchitecture -match 'ARM') { throw 'Windows ARM nao suportado por estes pacotes x86/x64.' }
    if ($Is64BitOperatingSystem) { return 'x64' }
    return 'x86'
}

function Find-OCSInstallerFile {
    param([string]$FileName)
    if ([string]::IsNullOrWhiteSpace($FileName)) { return $null }
    foreach ($directory in @((Join-Path $PSScriptRoot 'files'), $PSScriptRoot)) {
        $candidate = Join-Path $directory $FileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-OCSExecutableArchitecture {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = New-Object IO.BinaryReader $stream
        if ($reader.ReadUInt16() -ne 0x5A4D) { return 'Unknown' }
        $null = $stream.Seek(0x3C, [IO.SeekOrigin]::Begin)
        $peOffset = $reader.ReadInt32()
        $null = $stream.Seek($peOffset, [IO.SeekOrigin]::Begin)
        if ($reader.ReadUInt32() -ne 0x00004550) { return 'Unknown' }
        $machine = $reader.ReadUInt16()
        if ($machine -eq 0x8664) { return 'x64' }
        if ($machine -eq 0x14C) { return 'x86' }
        return 'Unknown'
    } finally { $stream.Dispose() }
}

function Select-OCSInstallerPackage {
    $architecture = Get-OCSPackageArchitecture
    $package = $InstallerPackages[$architecture]
    if (-not $package) { throw "Pacote nao configurado para $architecture." }
    $script:InstallerArchitecture = $architecture
    $script:InstallerFileName = $package.FileName
    $script:InstallerUrl = $package.Url
    $script:InstallerSHA256 = [string]$package.SHA256
    $script:InstallerPublisher = [string]$package.Publisher
    $specific = Find-OCSInstallerFile $package.FileName
    if ($specific) {
        Write-InstallerLog "Windows=$architecture Pacote=$InstallerFileName"
        return
    }
    $generic = Find-OCSInstallerFile $UniversalInstallerFileName
    if ($generic) {
        $peArch = Get-OCSExecutableArchitecture $generic
        if ($peArch -ne 'Unknown' -and $peArch -ne $architecture) {
            throw "O fallback $UniversalInstallerFileName e $peArch, incompativel com Windows $architecture."
        }
        $script:InstallerFileName = $UniversalInstallerFileName
        Write-InstallerLog "Windows=$architecture Pacote especifico ausente; usando fallback $InstallerFileName"
        return
    }
    Write-InstallerLog "Windows=$architecture Pacote=$InstallerFileName (ausente em disco)"
}

function Write-InstallerLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($DryRun) { Write-Host $line }
    elseif ($Level -eq 'AVISO') { Write-Host "Aviso: $Message" -ForegroundColor Yellow }
    if ($script:LogPath) {
        $newline = $line + [Environment]::NewLine
        if (-not (Test-Path -LiteralPath $script:LogPath -PathType Leaf)) {
            [IO.File]::WriteAllText($script:LogPath, $newline, (New-Object System.Text.UTF8Encoding $true))
        } else {
            [IO.File]::AppendAllText($script:LogPath, $newline, (New-Object System.Text.UTF8Encoding $false))
        }
    }
}

# Acentos so sao enviados ao console quando a pagina de codigo atual os
# representa. Em CP437 as letras acentuadas maiusculas sao substituidas pela
# forma sem acento, em vez de virarem "?".
function Format-ConsoleText {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    try {
        $encoding = [Console]::OutputEncoding
        if ($encoding.GetString($encoding.GetBytes($Text)) -eq $Text) { return $Text }
    } catch { }
    $decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $decomposed.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function Write-Friendly {
    param([AllowEmptyString()][string]$Message = '', [string]$ForegroundColor)
    $text = Format-ConsoleText $Message
    if ($ForegroundColor) { Write-Host $text -ForegroundColor $ForegroundColor } else { Write-Host $text }
}

function Write-InstallerStep {
    param([string]$Title)
    $script:StepIndex++
    Write-Friendly ''
    Write-Friendly ('[{0}/{1}] {2}' -f $script:StepIndex, $script:StepTotal, $Title)
    Write-InstallerLog "Etapa $script:StepIndex/$script:StepTotal - $Title"
}

function Write-InstallerDetail {
    param([string]$Message, [string]$ForegroundColor)
    Write-Friendly ('      ' + $Message) -ForegroundColor $ForegroundColor
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Sinalizacao de "reinicializacao necessaria" (3010).
# Nenhum caminho de codigo reinicia o computador; apenas recomenda.
# ---------------------------------------------------------------------------
function New-OCSRebootRequiredError {
    param([string]$TechnicalDetails)
    $script:RebootRequired = $true
    if ($TechnicalDetails) {
        $script:RebootTechnicalDetails = $TechnicalDetails
        Write-InstallerLog "Reinicializacao necessaria: $TechnicalDetails" 'ERRO'
    }
    return [InvalidOperationException]::new($OCSRebootRequiredTag)
}

function Test-OCSRebootRequiredError {
    param($ErrorRecord)
    if (-not $ErrorRecord) { return $false }
    return ("$($ErrorRecord.Exception.Message)" -eq $OCSRebootRequiredTag)
}

# ---------------------------------------------------------------------------
# Sinalizacao de "agente ocupado" (42).
#
# Distinta de 3010 de proposito: um inventario em andamento mantem os binarios
# do agente em uso, mas nao existe nenhuma alteracao pendente do Windows.
# Recomendar reinicializacao nesse caso seria incorreto e desnecessario.
# ---------------------------------------------------------------------------
function New-OCSAgentBusyError {
    param([string]$TechnicalDetails)
    if ($TechnicalDetails) {
        $script:AgentBusyDetails = $TechnicalDetails
        Write-InstallerLog "Agente ocupado: $TechnicalDetails" 'ERRO'
    }
    return [InvalidOperationException]::new($OCSAgentBusyTag)
}

function Test-OCSAgentBusyError {
    param($ErrorRecord)
    if (-not $ErrorRecord) { return $false }
    return ("$($ErrorRecord.Exception.Message)" -eq $OCSAgentBusyTag)
}

function Initialize-OCSCertificateBundle {
    param($Client)
    New-Item -ItemType Directory -Force -Path $AgentDataDirectory -ErrorAction Stop | Out-Null
    $destination = Join-Path $AgentDataDirectory $CaBundleFileName
    if (Get-OptionalValue $Client 'caFile') {
        if ([IO.Path]::GetFullPath($Client.caFile) -ne [IO.Path]::GetFullPath($destination)) {
            Copy-Item -LiteralPath $Client.caFile -Destination $destination -Force -ErrorAction Stop
        }
    } else {
        # Somente certificados publicos ja confiaveis para esta maquina. Nenhuma chave privada.
        $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
        try {
            $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            $pem = [Text.StringBuilder]::new()
            foreach ($certificate in $store.Certificates) {
                [void]$pem.AppendLine('-----BEGIN CERTIFICATE-----')
                [void]$pem.AppendLine([Convert]::ToBase64String($certificate.RawData, [Base64FormattingOptions]::InsertLineBreaks))
                [void]$pem.AppendLine('-----END CERTIFICATE-----')
            }
            if ($pem.Length -eq 0) { throw 'O Windows nao possui certificados raiz disponiveis. Configure caFile no JSON.' }
            [IO.File]::WriteAllText($destination, $pem.ToString(), [Text.Encoding]::ASCII)
        } finally { $store.Close() }
    }
    if ((Get-Item -LiteralPath $destination -ErrorAction Stop).Length -le 0) { throw 'O arquivo de certificados esta vazio. Verifique caFile.' }
    Write-InstallerLog 'Arquivo CA preparado. Validacao SSL permanece habilitada.'
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value -match '[\x00\r\n"]') { throw 'Argumento contem caracteres nao permitidos.' }
    # Windows CommandLineToArgvW: duplicar barras finais antes de fechar aspas.
    return '"' + [regex]::Replace($Value, '(\\+)$', '$1$1') + '"'
}

function Restart-AsAdministrator {
    $hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-NativeArgument $PSCommandPath),
        '-ClientsPath', (ConvertTo-NativeArgument ([IO.Path]::GetFullPath($ClientsPath))))
    if ($ClientTag) { $arguments += @('-ClientTag', (ConvertTo-NativeArgument $ClientTag)) }
    elseif ($script:ClientIndexSpecified) { $arguments += @('-ClientIndex', "$ClientIndex") }
    if ($NoPause) { $arguments += '-NoPause' }
    if ($RunInventory) { $arguments += '-RunInventory' }
    try {
        $child = Start-Process -FilePath $hostPath -ArgumentList ($arguments -join ' ') -Verb RunAs -Wait -PassThru -ErrorAction Stop
        return $child.ExitCode
    } catch { Write-Friendly 'Elevacao cancelada ou indisponivel. Execute como Administrador.'; return $ExitElevation }
}

function Get-OptionalValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function Test-SafeText {
    param($Value)
    return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value) -and $Value -notmatch '[\x00-\x1f"\x7f]')
}

function ConvertTo-OCSAgentServerUrl {
    param([string]$Value)
    $uri = $null
    if (-not (Test-SafeText $Value) -or -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        throw 'server global deve ser HTTPS, sem credenciais, query ou fragmento.'
    }
    if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'server global deve ser HTTPS, sem credenciais, query ou fragmento.'
    }
    $path = ([Uri]::UnescapeDataString($uri.AbsolutePath)).TrimEnd('/')
    if ($path -match '(?i)ocsreports') {
        throw 'O servidor do agente OCS deve apontar para o endpoint /ocsinventory, e nao para /ocsreports.'
    }
    if ($path -ne '/ocsinventory') {
        throw 'O servidor do agente OCS deve apontar para o endpoint /ocsinventory, e nao para /ocsreports.'
    }
    $hostName = $uri.Host.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        throw 'server global deve ser HTTPS, sem credenciais, query ou fragmento.'
    }
    if ($uri.IsDefaultPort) {
        return ('https://{0}/ocsinventory' -f $hostName)
    }
    return ('https://{0}:{1}/ocsinventory' -f $hostName, $uri.Port)
}

function ConvertTo-OCSComparableServerUrl {
    param([string]$Value)
    try { return (ConvertTo-OCSAgentServerUrl $Value) } catch { return $null }
}

function Test-OCSServerUrlEquals {
    param([string]$Expected, [string]$Actual)
    $left = ConvertTo-OCSComparableServerUrl $Expected
    $right = ConvertTo-OCSComparableServerUrl $Actual
    return [bool]($left -and $right -and ($left -ceq $right))
}

function Read-ClientConfiguration {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'clients.json nao encontrado.' }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $document = [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw 'Nao foi possivel ler clients.json: JSON invalido ou acesso negado.' }
    $sharedServer = ConvertTo-OCSAgentServerUrl (Get-OptionalValue $document 'server')
    # ConvertFrom-Json no Windows PowerShell 5.1 devolve um unico objeto quando
    # o JSON tem um array de um elemento. @() forca colecao nos dois hosts.
    $clients = @(Get-OptionalValue $document 'clients')
    if ($clients.Count -eq 0 -or $null -eq $clients[0]) { throw 'A lista clients esta vazia.' }
    $tags = @{}
    for ($i = 0; $i -lt $clients.Count; $i++) {
        $client = $clients[$i]
        $label = "Cliente $($i + 1)"
        if ($client.PSObject.Properties.Name -contains 'server' -and $client.server -cne $sharedServer) {
            throw 'Remova server dos clientes: todos devem usar o servidor definido na raiz do JSON.'
        }
        $client | Add-Member -NotePropertyName server -NotePropertyValue $sharedServer -Force
        if ($client.PSObject.Properties.Name -contains 'id') { [void]$client.PSObject.Properties.Remove('id') }
        foreach ($field in @('name', 'tag')) {
            if (-not (Test-SafeText (Get-OptionalValue $client $field))) { throw "$label`: campo $field invalido." }
        }
        $label = "Cliente '$($client.name)'"
        $tagKey = $client.tag.ToUpperInvariant()
        if ($tags.ContainsKey($tagKey)) {
            throw ("TAG duplicada '{0}':{1}- {2}{1}- {3}" -f $client.tag, [Environment]::NewLine, $tags[$tagKey], $client.name)
        }
        $tags[$tagKey] = $client.name
        foreach ($reserved in @('user', 'password', 'proxy', 'additionalArguments')) {
            $value = Get-OptionalValue $client $reserved
            if ($null -ne $value -and "$value" -ne '' -and @($value).Count -gt 0) {
                throw "$label`: $reserved reservado; suporte seguro ainda nao habilitado."
            }
        }
        $ssl = Get-OptionalValue $client 'ssl' 1
        if ("$ssl" -notin @('1', 'True')) { throw "$label`: verificacao SSL nao pode ser desabilitada." }
        $debugValue = Get-OptionalValue $client 'debug' 0
        if ("$debugValue" -notmatch '^[012]$') { throw "$label`: debug deve ser 0, 1 ou 2." }
        $ca = Get-OptionalValue $client 'caFile'
        if ($ca) {
            if (-not (Test-SafeText $ca)) { throw "$label`: caFile invalido." }
            if (-not [IO.Path]::IsPathRooted($ca)) { $ca = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($Path))) $ca }
            if (-not (Test-Path -LiteralPath $ca -PathType Leaf)) { throw "$label`: certificado CA nao encontrado." }
            $client | Add-Member -NotePropertyName caFile -NotePropertyValue ([IO.Path]::GetFullPath($ca)) -Force
        }
    }
    return @($clients)
}

function Show-ClientMenu {
    param($Clients)
    $Clients = @($Clients)
    Write-Friendly ''
    Write-Friendly '========================================'
    Write-Friendly '        INSTALADOR OCS INVENTORY'
    Write-Friendly '========================================'
    Write-Friendly ''
    Write-Friendly 'Selecione o cliente:'
    Write-Friendly ''
    for ($i = 0; $i -lt $Clients.Count; $i++) {
        Write-Friendly ('[{0}] {1}' -f ($i + 1), $Clients[$i].name)
    }
    Write-Friendly ''
    Write-Friendly '[0] Sair'
    Write-Friendly ''
}

function Select-Client {
    param($Clients, $RequestedIndex, [string]$RequestedTag)
    $Clients = @($Clients)
    if ($RequestedTag -and $null -ne $RequestedIndex) {
        throw 'Use ClientTag ou ClientIndex, nao os dois.'
    }
    if ($RequestedTag) {
        $match = @($Clients | Where-Object { $_.tag -ieq $RequestedTag })
        if ($match.Count -eq 0) { throw "Cliente com TAG '$RequestedTag' nao encontrado." }
        if ($match.Count -gt 1) { throw "Existem multiplos clientes com TAG '$RequestedTag'. As TAGs devem ser unicas." }
        return $match[0]
    }
    if ($null -ne $RequestedIndex) {
        $index = 0
        if ("$RequestedIndex" -notmatch '^[0-9]+$' -or -not [int]::TryParse("$RequestedIndex", [ref]$index)) {
            throw "ClientIndex '$RequestedIndex' e invalido. Use um numero entre 1 e $($Clients.Count), ou 0 para sair."
        }
        if ($index -eq 0) { return $null }
        if ($index -lt 1 -or $index -gt $Clients.Count) {
            throw ("ClientIndex {0} esta fora do intervalo. Use um numero entre 1 e {1}, ou 0 para sair." -f $index, $Clients.Count)
        }
        return $Clients[$index - 1]
    }
    while ($true) {
        Show-ClientMenu $Clients
        $answer = Read-Host 'Digite a opcao'
        if ($answer -eq '0') { return $null }
        $parsed = 0
        if (-not [int]::TryParse("$answer", [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt $Clients.Count) {
            Write-Friendly 'Opcao invalida. Tente novamente.'
            continue
        }
        return $Clients[$parsed - 1]
    }
}

function Confirm-ClientSelection {
    param($Client)
    Write-Friendly ''
    Write-Friendly "Cliente : $($Client.name)"
    Write-Friendly "Servidor: $($Client.server)"
    Write-Friendly "TAG     : $($Client.tag)"
    return ((Read-Host 'Podemos preparar o agente para este cliente? [S/N]') -match '^[sS]$')
}

function Confirm-Yes {
    param([string]$Question)
    return ((Read-Host $Question) -match '^[sS]$')
}

function Confirm-OCSOptionalAction {
    param([string]$Question)
    if ($NoPause) {
        Write-InstallerLog "NoPause: acao opcional nao confirmada automaticamente. $Question"
        return $false
    }
    return (Confirm-Yes $Question)
}

function Test-OCSInventoryProcessRunning {
    return -not (Wait-OCSProcessExit -Names @('OCSInventory') -TimeoutSeconds 0)
}

# ---------------------------------------------------------------------------
# Versao: comparacao sempre por [System.Version], nunca textual.
# ---------------------------------------------------------------------------
function ConvertTo-OCSVersion {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $normalized = ($Value -replace '[,\s]+', '.').Trim('.')
    if ($normalized -notmatch '^\d+(\.\d+){0,3}$') { return $null }
    if ($normalized -notmatch '\.') { $normalized += '.0' }
    $parsed = $null
    if ([version]::TryParse($normalized, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-OCSVersionState {
    param(
        [bool]$Installed,
        [AllowNull()][AllowEmptyString()][string]$InstalledVersion,
        [AllowNull()][AllowEmptyString()][string]$TargetVersion
    )
    if (-not $Installed) { return 'NotInstalled' }
    $current = ConvertTo-OCSVersion $InstalledVersion
    $target = ConvertTo-OCSVersion $TargetVersion
    if (-not $current -or -not $target) { return 'Unknown' }
    if ($current -lt $target) { return 'Older' }
    if ($current -gt $target) { return 'Newer' }
    return 'Current'
}

# Setup exit 0 nao prova que a atualizacao foi aplicada: os arquivos podem
# estar travados. A prova e a versao em disco depois do setup.
function Test-OCSUpdateOutcome {
    param(
        [int]$SetupExitCode,
        [AllowNull()][AllowEmptyString()][string]$InstalledVersionAfter,
        [AllowNull()][AllowEmptyString()][string]$TargetVersion
    )
    $state = Get-OCSVersionState -Installed $true -InstalledVersion $InstalledVersionAfter -TargetVersion $TargetVersion
    $applied = $state -in @('Current', 'Newer')
    $reason = switch ($state) {
        'Current' { 'Versao em disco corresponde ao pacote.' }
        'Newer' { 'Versao em disco e mais recente que o pacote.' }
        'Older' { 'Setup terminou, mas a versao em disco continua anterior ao pacote.' }
        default { 'Nao foi possivel confirmar a versao em disco depois do setup.' }
    }
    return [pscustomobject]@{
        Applied = $applied
        VersionState = $state
        RebootRequired = ($SetupExitCode -eq $ExitRebootRequired)
        SetupExitCode = $SetupExitCode
        Reason = $reason
    }
}

function Get-OCSInstalledVersionFromExe {
    param([string]$ExePath)
    $fromExe = Get-OCSVersionFromInstaller $ExePath
    if ($fromExe) { return $fromExe.Raw }
    return $null
}

function Get-OCSVersionFromInstaller {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $info = (Get-Item -LiteralPath $Path).VersionInfo
    foreach ($entry in @(
        @{ Source = 'FileVersion'; Raw = $info.FileVersion }
        @{ Source = 'ProductVersion'; Raw = $info.ProductVersion }
    )) {
        $parsed = ConvertTo-OCSVersion $entry.Raw
        if ($parsed) {
            return [pscustomobject]@{
                Raw = $entry.Raw
                Source = $entry.Source
                Normalized = $parsed.ToString()
            }
        }
    }
    return $null
}

function Resolve-OCSTargetVersion {
    param([string]$InstallerPath)
    if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
        $fromExe = Get-OCSVersionFromInstaller $InstallerPath
        if ($fromExe) {
            $script:AgentVersion = $fromExe.Normalized
            Write-InstallerLog "Versao-alvo do pacote: $($fromExe.Source)=$($fromExe.Raw) Normalizada=$script:AgentVersion Arquivo=$InstallerPath"
            return $script:AgentVersion
        }
        $script:AgentVersion = $null
        Write-InstallerLog "O instalador selecionado esta disponivel, mas FileVersion/ProductVersion nao puderam ser interpretadas ($InstallerPath). Nenhuma versao sera inventada." 'AVISO'
        return $null
    }
    $localPath = Get-OCSInstallerLocalPath
    if ($localPath) {
        $fromExe = Get-OCSVersionFromInstaller $localPath
        if ($fromExe) {
            $script:AgentVersion = $fromExe.Normalized
            Write-InstallerLog "Versao-alvo do pacote: $($fromExe.Source)=$($fromExe.Raw) Normalizada=$script:AgentVersion Arquivo=$localPath"
            return $script:AgentVersion
        }
        $script:AgentVersion = $null
        Write-InstallerLog "O pacote local esta disponivel, mas FileVersion/ProductVersion nao puderam ser interpretadas ($localPath). Nenhuma versao sera inventada." 'AVISO'
        return $null
    }
    $script:AgentVersion = $AgentVersionFallback
    Write-InstallerLog "Versao-alvo provisoria (pacote ainda ausente em disco): $script:AgentVersion. Sera substituida pela versao do EXE quando o arquivo estiver disponivel."
    return $script:AgentVersion
}

function Get-InstalledOCSAgent {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $paths = @()
    if ($service) {
        $serviceKey = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -ErrorAction Stop
        $imagePath = [Environment]::ExpandEnvironmentVariables($serviceKey.ImagePath)
        if ($imagePath -match '(?i)/(work_dir|server|local)') { throw 'Servico usa configuracao personalizada; homologue a deteccao do diretorio antes de continuar.' }
        if ($imagePath -match '^"([^"]+\.exe)"|^(.+?\.exe)(?:\s|$)') {
            $exe = $Matches[1]; if (-not $exe) { $exe = $Matches[2] }
            $paths += Split-Path -Parent $exe
        }
    }
    $entries = @()
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (Test-Path $root) {
            $entries += @(Get-ChildItem $root | Get-ItemProperty | Where-Object { $_.DisplayName -match '^OCS Inventory.*Agent' })
        }
    }
    foreach ($entry in $entries) { if ($entry.InstallLocation) { $paths += $entry.InstallLocation } }
    foreach ($base in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $paths += Join-Path $base 'OCS Inventory Agent' }
    }
    $executables = @($paths | Select-Object -Unique | ForEach-Object { Join-Path $_ 'OCSInventory.exe' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -Unique)
    if ($executables.Count -gt 1) { throw 'Multiplas instalacoes OCS detectadas; resolva a ambiguidade antes de continuar.' }
    $exePath = $null; $version = $null
    if ($executables.Count -eq 1) { $exePath = $executables[0]; $version = Get-OCSInstalledVersionFromExe $exePath }
    return [pscustomobject]@{
        Found = [bool]($service -or $entries.Count -or $exePath)
        Exe = $exePath
        Version = $version
        Service = $service
        ServiceStatus = $(if ($service) { "$($service.Status)" } else { $null })
        ServiceStartType = $(if ($service) { "$($service.StartType)" } else { $null })
    }
}

function Get-ExistingOCSConfiguration {
    param([string]$Directory = $AgentDataDirectory)
    $server = $null; $tag = $null; $ssl = $null; $caBundle = $null; $section = ''; $hasCredentials = $false
    $ini = Join-Path $Directory 'ocsinventory.ini'
    if (Test-Path -LiteralPath $ini) {
        foreach ($line in (Get-Content -LiteralPath $ini -ErrorAction Stop)) {
            if ($line -match '^\s*\[([^\]]+)\]') { $section = $Matches[1] }
            elseif ($section -eq 'HTTP' -and $line -match '^\s*Server\s*=(.*)$') { $server = $Matches[1].Trim() }
            elseif ($section -eq 'HTTP' -and $line -match '^\s*SSL\s*=(.*)$') { $ssl = $Matches[1].Trim() }
            elseif ($section -eq 'HTTP' -and $line -match '^\s*(CaBundle|CaFile|CA)\s*=(.*)$') { $caBundle = $Matches[2].Trim().Trim('"') }
            elseif ($section -eq 'HTTP' -and $line -match '^\s*(User|Pwd|ProxyUser|ProxyPwd)\s*=\s*\S+') { $hasCredentials = $true }
        }
    }
    # A TAG do OCS 2.11 fica em admininfo.conf; o DAT guarda a identidade do computador.
    $account = Join-Path $Directory 'admininfo.conf'
    if (Test-Path -LiteralPath $account) {
        try {
            $settings = [Xml.XmlReaderSettings]::new(); $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver = $null
            $reader = [Xml.XmlReader]::Create($account, $settings)
            try {
                $xml = [Xml.XmlDocument]::new(); $xml.XmlResolver = $null; $xml.Load($reader)
                $node = $xml.SelectSingleNode('//ACCOUNTINFO[KEYNAME="TAG"]/KEYVALUE')
                if ($node) { $tag = $node.InnerText }
            } finally { $reader.Dispose() }
        } catch { $tag = $null }
    }
    # Nunca registrar conteudo de configuracao bruta, URLs antigas podem ter segredos.
    return [pscustomobject]@{
        Server = $server
        Tag = $tag
        Ssl = $ssl
        CaBundle = $caBundle
        HasCredentials = $hasCredentials
    }
}

function Get-OCSExpectedCaBundlePath {
    return [IO.Path]::GetFullPath((Join-Path $AgentDataDirectory $CaBundleFileName))
}

function Test-OCSCaBundlePathEquals {
    param([string]$Expected, [string]$Actual)
    if ([string]::IsNullOrWhiteSpace($Expected) -or [string]::IsNullOrWhiteSpace($Actual)) { return $false }
    try {
        $left = [IO.Path]::GetFullPath($Expected.Trim().Trim('"'))
        $right = [IO.Path]::GetFullPath($Actual.Trim().Trim('"'))
    } catch { return $false }
    return $left.Equals($right, [StringComparison]::OrdinalIgnoreCase)
}

function Test-OCSCaBundleFileExists {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return [bool](Test-Path -LiteralPath $Path.Trim().Trim('"') -PathType Leaf) } catch { return $false }
}

function Test-OCSCaBundleContent {
    param([string]$Path)
    if (-not (Test-OCSCaBundleFileExists $Path)) { return $false }
    try {
        $pem = [IO.File]::ReadAllText($Path)
        $blocks = [regex]::Matches($pem, '(?s)-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----')
        if ($blocks.Count -eq 0) { return $false }
        foreach ($block in $blocks) {
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String(($block.Groups[1].Value -replace '\s', '')))
            try { if (-not $certificate.Thumbprint) { return $false } }
            finally { $certificate.Dispose() }
        }
        return $true
    } catch { return $false }
}

function Assert-OCSCaBundleReady {
    $path = Get-OCSExpectedCaBundlePath
    if (-not (Test-OCSCaBundleFileExists $path)) { throw 'O bundle CA esperado nao foi gerado.' }
    if (-not (Test-OCSCaBundleContent $path)) { throw 'O bundle CA gerado nao contem certificados X509 validos.' }
}

function Test-OCSEffectiveConfiguration {
    param($Existing, $Client)
    $serverMatches = [bool]($Existing.Server -and (Test-OCSServerUrlEquals $Client.server $Existing.Server))
    $tagMatches = [bool]($Existing.Tag -and ($Existing.Tag -ceq $Client.tag))
    $sslMatches = [bool]("$($Existing.Ssl)" -in @('1', 'True'))
    $identityMatches = [bool]($serverMatches -and $tagMatches -and $sslMatches)
    $expectedCa = Get-OCSExpectedCaBundlePath
    $caPathMatches = Test-OCSCaBundlePathEquals $expectedCa $Existing.CaBundle
    $caFileExists = Test-OCSCaBundleFileExists $expectedCa
    $caValid = [bool]($caFileExists -and (Test-OCSCaBundleContent $expectedCa))
    $caBundleReady = [bool]($caPathMatches -and $caValid)
    return [pscustomobject]@{
        Ready = [bool]($identityMatches -and $caBundleReady)
        IdentityMatches = $identityMatches
        ServerMatches = $serverMatches
        TagMatches = $tagMatches
        SslMatches = $sslMatches
        CaBundlePathMatches = $caPathMatches
        CaBundleFileExists = $caFileExists
        CaBundleReady = $caBundleReady
        CaMigrationRequired = [bool]($identityMatches -and -not $caBundleReady)
        ExpectedCaBundle = $expectedCa
    }
}

function Format-ExistingValue {
    param([string]$Value, [switch]$Url)
    if (-not $Value) { return '(nao foi possivel determinar)' }
    if ($Url) {
        $uri = $null
        if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { return '(valor omitido: URL pode conter segredos)' }
    }
    return ($Value -replace '[\x00-\x1f\x7f]', '?')
}

# Adaptador OCS 2.x: switches documentados; validar com o pacote selecionado.
function Get-OCSArguments {
    param($Client, [ValidateSet('Setup', 'Inventory')][string]$Mode)
    $argsList = @()
    if ($Mode -eq 'Setup') { $argsList += @('/S', '/NOSPLASH') }
    else { $argsList += '/FORCE' }
    $argsList += @('/SERVER=' + (ConvertTo-NativeArgument $Client.server), '/TAG=' + (ConvertTo-NativeArgument $Client.tag), '/SSL=1', '/NOTAG')
    $argsList += '/DEBUG=' + (Get-OptionalValue $Client 'debug' 0)
    # Caminho permanente; CA informada pelo cliente ou raizes confiaveis do Windows.
    $argsList += '/CA=' + (ConvertTo-NativeArgument (Join-Path $AgentDataDirectory $CaBundleFileName))
    return ($argsList -join ' ')
}

function Get-OCSInstallerLocalPath {
    $localPath = Find-OCSInstallerFile $InstallerFileName
    if ($localPath) { return $localPath }
    if ($InstallerFileName -ne $UniversalInstallerFileName) {
        return (Find-OCSInstallerFile $UniversalInstallerFileName)
    }
    return $null
}

function Get-OCSInstallerSignature {
    param([string]$Path)
    return (Get-AuthenticodeSignature -LiteralPath $Path)
}

function Assert-OCSInstallerTrust {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Instalador nao encontrado.' }
    if ((Get-Item -LiteralPath $Path).Length -le 0) { throw 'Instalador local vazio.' }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $signature = Get-OCSInstallerSignature $Path
    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '(sem certificado)' }
    Write-InstallerLog "Assinatura Authenticode: Caminho=$Path Status=$($signature.Status) Subject=$subject SHA256=$hash"
    if ($InstallerSHA256) {
        if ($hash.ToUpperInvariant() -ne $InstallerSHA256.ToUpperInvariant()) { throw 'SHA256 do instalador divergente.' }
        Write-InstallerLog "SHA256 conferido com o valor esperado."
    } else {
        Write-InstallerLog "SHA256 esperado nao configurado; hash real do instalador registrado."
    }
    if ("$($signature.Status)" -ne 'Valid') {
        throw "Assinatura Authenticode invalida (Status=$($signature.Status)). O instalador nao sera executado."
    }
    if ($InstallerPublisher) {
        $matchesPublisher = $signature.SignerCertificate -and $subject.IndexOf($InstallerPublisher, [StringComparison]::OrdinalIgnoreCase) -ge 0
        if (-not $matchesPublisher) {
            throw "Publisher Authenticode divergente (esperado '$InstallerPublisher', obtido '$subject')."
        }
        Write-InstallerLog "Publisher conferido: $InstallerPublisher"
    }
}

function Get-OCSInstaller {
    param([switch]$Preview)
    $localPath = Get-OCSInstallerLocalPath
    if ($localPath) {
        Assert-OCSInstallerTrust $localPath
        $null = Resolve-OCSTargetVersion -InstallerPath $localPath
        Write-InstallerLog "Instalador local encontrado. Versao do arquivo: $script:AgentVersion"
        return $localPath
    }
    if (-not $InstallerUrl) { throw 'Instalador ausente. Coloque o EXE em files ou configure InstallerUrl HTTPS.' }
    $uri = $null
    if (-not [Uri]::TryCreate($InstallerUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'InstallerUrl deve ser HTTPS sem credenciais, query ou fragmento.' }
    if ($Preview) { Write-InstallerLog 'DryRun: baixaria instalador HTTPS e validaria status, tamanho, SHA256 e assinatura Authenticode.'; return '(download pendente)' }
    $cache = Join-Path (Split-Path -Parent (Split-Path -Parent $script:LogPath)) 'Cache'
    New-Item -ItemType Directory -Path $cache -Force -ErrorAction Stop | Out-Null
    $target = Join-Path $cache (([guid]::NewGuid().ToString()) + '.exe')
    $oldTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        # Sem redirecionamentos: impede downgrade HTTPS -> HTTP.
        $response = Invoke-WebRequest -Uri $InstallerUrl -OutFile $target -PassThru -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop
        if ([int]$response.StatusCode -ne 200 -or -not (Test-Path -LiteralPath $target) -or (Get-Item -LiteralPath $target).Length -le 0) { throw 'Download incompleto.' }
        Assert-OCSInstallerTrust $target
        $fromExe = Resolve-OCSTargetVersion -InstallerPath $target
        if (-not $fromExe) { throw 'O instalador baixado esta disponivel, mas FileVersion/ProductVersion nao puderam ser lidas. Nenhuma decisao de atualizacao ou downgrade sera tomada.' }
        return $target
    } catch {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        if ("$($_.Exception.Message)" -match 'Authenticode|SHA256') { throw }
        throw 'Download falhou: verifique HTTPS, status 200, certificado, tamanho e SHA256. Redirecionamentos nao sao aceitos.'
    } finally { [Net.ServicePointManager]::SecurityProtocol = $oldTls }
}

function Invoke-OCSProcess {
    param([string]$FilePath, [string]$Arguments, [int[]]$SuccessCodes = @(0))
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw 'Executavel nao encontrado.' }
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory (Split-Path -Parent $FilePath) -PassThru -ErrorAction Stop
    $null = $process.Handle # Manter handle para ExitCode no Windows PowerShell 5.1.
    if (-not $process.WaitForExit($ProcessTimeoutSeconds * 1000)) { throw 'Tempo limite excedido; o processo pode continuar ativo. Verifique-o antes de repetir.' }
    $process.Refresh()
    $code = $process.ExitCode
    Write-InstallerLog "Processo finalizado. Exit code: $code"
    if ($code -notin $SuccessCodes) {
        if ($script:Stage -eq 'Inventario' -and $code -eq 4) {
            throw 'Nao foi possivel conversar com o servidor OCS (codigo 4). Verifique a conexao, o certificado CA e o log OCSInventory.log.'
        }
        throw "Processo OCS falhou. Exit code nativo: $code"
    }
    if ($code -eq $ExitRebootRequired) { $script:RebootRequired = $true }
    return $code
}

function Install-OCSAgent {
    param([string]$Installer, $Client)
    $code = Invoke-OCSProcess $Installer (Get-OCSArguments $Client Setup) @(0, $ExitRebootRequired)
    $script:SetupPerformed = $true
    return $code
}

function Set-OCSConfiguration {
    param([string]$Installer, $Client)
    # Reaplicar pelo instalador oficial preserva formatos privados e identidade do agente.
    Write-InstallerLog 'Reaplicando configuracao pelo instalador oficial (sem editar DAT/INI manualmente).'
    return (Install-OCSAgent $Installer $Client)
}

function Invoke-ServiceControllerTool {
    param([string[]]$Arguments, [int[]]$SuccessCodes = @(0))
    $scPath = Join-Path $env:SystemRoot 'System32\sc.exe'
    if (-not (Test-Path -LiteralPath $scPath -PathType Leaf)) { throw 'sc.exe nao encontrado no Windows.' }
    $output = (& $scPath @Arguments 2>&1 | Out-String).Trim()
    $code = $LASTEXITCODE
    Write-InstallerLog "sc.exe $($Arguments[0]) finalizado. Exit code: $code"
    if ($code -notin $SuccessCodes) {
        $safeOutput = ($output -replace '[\x00-\x1f\x7f]+', ' ').Trim()
        if ($code -eq $ErrorServiceMarkedForDelete) {
            throw (New-OCSRebootRequiredError ("sc.exe {0} => Win32 {1} ERROR_SERVICE_MARKED_FOR_DELETE. {2}" -f ($Arguments -join ' '), $code, $safeOutput))
        }
        throw "O Windows recusou o comando do servico (sc.exe codigo $code). $safeOutput"
    }
    return $output
}

# ---------------------------------------------------------------------------
# MAQUINA DE ESTADOS DO SERVICO
#
# Get-OCSServiceFacts  : le o sistema (somente leitura).
# Resolve-OCSServiceState : funcao pura que classifica os fatos.
# Get-OCSServiceState  : combina as duas. Unico ponto de decisao do script.
#
# Estados: ServiceMissing, ServiceHealthy, RunningDisabled, StoppedAutomatic,
#          StoppedDisabled, MarkedForDeletion, ProcessStillRunning,
#          RebootRequired, CorruptOrIncomplete, Unknown.
# ---------------------------------------------------------------------------
function Get-OCSPendingRebootReasons {
    $reasons = @()
    try {
        $pending = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations
        # Somente entradas do OCS: PendingFileRenameOperations existe em quase toda maquina.
        if (@($pending | Where-Object { "$_" -match '(?i)ocs' }).Count -gt 0) { $reasons += 'PendingFileRenameOperations(OCS)' }
    } catch { }
    foreach ($key in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path -LiteralPath $key) { $reasons += (Split-Path -Leaf $key) }
    }
    return $reasons
}

function Get-OCSServiceFacts {
    $facts = [ordered]@{
        ServiceObjectFound = $false
        Status = $null
        StartType = $null
        RegistryKeyFound = $false
        RegistryStart = $null
        DeleteFlag = $null
        ImagePath = $null
        ImagePathExists = $null
        ProcessId = $null
        ProcessName = $null
        PendingRebootReasons = @()
        QueryError = $null
    }
    try {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($service) {
            $facts.ServiceObjectFound = $true
            $facts.Status = "$($service.Status)"
            $facts.StartType = "$($service.StartType)"
        }
    } catch { $facts.QueryError = ($_.Exception.Message -replace '[\x00-\x1f\x7f]+', ' ').Trim() }

    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (Test-Path -LiteralPath $key) {
        $facts.RegistryKeyFound = $true
        try {
            $properties = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            if ($null -ne $properties.Start) { $facts.RegistryStart = [int]$properties.Start }
            # DeleteFlag=1 e como o SCM registra ERROR_SERVICE_MARKED_FOR_DELETE.
            if ($null -ne $properties.DeleteFlag) { $facts.DeleteFlag = [int]$properties.DeleteFlag }
            if ($properties.ImagePath) {
                $facts.ImagePath = [Environment]::ExpandEnvironmentVariables("$($properties.ImagePath)")
                $binary = $facts.ImagePath
                if ($binary -match '^"([^"]+)"') { $binary = $Matches[1] } elseif ($binary -match '^(\S+\.exe)') { $binary = $Matches[1] }
                $facts.ImagePathExists = [bool](Test-Path -LiteralPath $binary -PathType Leaf)
            }
        } catch { $facts.QueryError = ($_.Exception.Message -replace '[\x00-\x1f\x7f]+', ' ').Trim() }
    }

    $process = @(Get-Process -Name 'OcsService' -ErrorAction SilentlyContinue)
    if ($process.Count -gt 0) { $facts.ProcessId = $process[0].Id; $facts.ProcessName = 'OcsService' }
    $facts.PendingRebootReasons = @(Get-OCSPendingRebootReasons)
    return [pscustomobject]$facts
}

function Resolve-OCSServiceState {
    param([Parameter(Mandatory)]$Facts)

    $exists = [bool]($Facts.ServiceObjectFound -or $Facts.RegistryKeyFound)
    $markedForDeletion = ($Facts.DeleteFlag -eq 1) -or ("$($Facts.QueryError)" -match '1072|marked for delete|marcado para ser excl')
    $pendingReboot = (@($Facts.PendingRebootReasons).Count -gt 0)
    $startTypeOk = ("$($Facts.StartType)" -in @('Automatic', 'AutomaticDelayedStart'))

    if ($markedForDeletion) {
        $state = 'MarkedForDeletion'
    } elseif (-not $exists) {
        $state = 'ServiceMissing'
    } elseif ($Facts.RegistryKeyFound -and -not $Facts.ServiceObjectFound) {
        $state = 'CorruptOrIncomplete'
    } elseif ($Facts.ImagePathExists -eq $false) {
        $state = 'CorruptOrIncomplete'
    } elseif ("$($Facts.Status)" -eq 'StartPending') {
        $state = 'ServiceStarting'
    } elseif ("$($Facts.Status)" -eq 'StopPending') {
        $state = 'ServiceStopping'
    } elseif ("$($Facts.Status)" -eq 'Paused' -or "$($Facts.Status)" -match 'Pending$') {
        $state = 'Unknown'
    } elseif ("$($Facts.Status)" -eq 'Running') {
        # StartType diferente de Automatic significa que o servico nao volta no proximo boot.
        $state = if ($startTypeOk) { 'ServiceHealthy' } else { 'RunningDisabled' }
    } elseif ("$($Facts.Status)" -eq 'Stopped') {
        if ($null -ne $Facts.ProcessId) { $state = 'ProcessStillRunning' }
        elseif ($startTypeOk) { $state = 'StoppedAutomatic' }
        else { $state = 'StoppedDisabled' }
    } else {
        $state = 'Unknown'
    }

    # Uma alteracao do Windows ainda pendente explica um servico inconsistente.
    if ($pendingReboot -and $state -in @('CorruptOrIncomplete', 'ProcessStillRunning')) { $state = 'RebootRequired' }

    $rebootRequired = $state -in @('MarkedForDeletion', 'RebootRequired')
    $healthy = ($state -eq 'ServiceHealthy')
    $needsRepair = $state -in @('RunningDisabled', 'StoppedAutomatic', 'StoppedDisabled')
    $safeToModify = -not $rebootRequired -and $exists -and $state -notin @('CorruptOrIncomplete', 'ServiceStarting', 'ServiceStopping')

    $details = @(
        "State=$state"
        "ServiceObjectFound=$($Facts.ServiceObjectFound)"
        "Status=$($Facts.Status)"
        "StartType=$($Facts.StartType)"
        "RegistryKeyFound=$($Facts.RegistryKeyFound)"
        "RegistryStart=$($Facts.RegistryStart)"
        "DeleteFlag=$($Facts.DeleteFlag)"
        "ImagePathExists=$($Facts.ImagePathExists)"
        "ProcessId=$($Facts.ProcessId)"
        "PendingReboot=$(@($Facts.PendingRebootReasons) -join '|')"
        "QueryError=$($Facts.QueryError)"
    ) -join ' '

    return [pscustomobject]@{
        State = $state
        Exists = $exists
        Status = $Facts.Status
        StartType = $Facts.StartType
        MarkedForDeletion = $markedForDeletion
        ProcessId = $Facts.ProcessId
        RebootRequired = $rebootRequired
        Healthy = $healthy
        NeedsRepair = $needsRepair
        SafeToModify = $safeToModify
        PendingRebootReasons = @($Facts.PendingRebootReasons)
        TechnicalDetails = $details
    }
}

function Get-OCSServiceState {
    return (Resolve-OCSServiceState (Get-OCSServiceFacts))
}

# ---------------------------------------------------------------------------
# Um servico em StartPending/StopPending esta em transicao. Decidir sobre esse
# instantaneo levaria o script a agir sobre um estado que vai mudar sozinho.
# Aqui a transicao e aguardada; se nao terminar, o estado continua
# ServiceStarting/ServiceStopping e nenhuma decisao destrutiva e tomada.
# ---------------------------------------------------------------------------
function Test-OCSServiceInTransition {
    param($ServiceState)
    return [bool]($ServiceState.State -in @('ServiceStarting', 'ServiceStopping') -or "$($ServiceState.Status)" -match 'Pending$')
}

function Wait-OCSServiceSettled {
    param($ServiceState, [int]$TimeoutSeconds = $ServiceSettleWaitSeconds)
    if (-not (Test-OCSServiceInTransition $ServiceState)) { return $ServiceState }
    Write-InstallerLog "Servico em transicao ($($ServiceState.State)/$($ServiceState.Status)). Aguardando ate $TimeoutSeconds s antes de decidir."
    Write-InstallerDetail 'Serviço iniciando. Aguardando estabilizar...'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $current = $ServiceState
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 1000
        $current = Get-OCSServiceState
        if (-not (Test-OCSServiceInTransition $current)) {
            Write-InstallerLog "Servico estabilizou: $($current.TechnicalDetails)"
            return $current
        }
    }
    Write-InstallerLog "Servico continuou em transicao apos $TimeoutSeconds s: $($current.TechnicalDetails)" 'AVISO'
    return $current
}

function Format-OCSServiceStateForUser {
    param($ServiceState)
    switch ($ServiceState.State) {
        'ServiceHealthy' { 'Serviço em execução com início automático.' }
        'RunningDisabled' { "Serviço em execução, mas o início está $($ServiceState.StartType): não voltaria no próximo boot." }
        'StoppedAutomatic' { 'Serviço parado, com início automático configurado.' }
        'StoppedDisabled' { "Serviço parado e com início $($ServiceState.StartType)." }
        'ServiceMissing' { 'Serviço do OCS não está instalado.' }
        'MarkedForDeletion' { 'O Windows ainda está finalizando uma alteração anterior no serviço.' }
        'ProcessStillRunning' { 'Serviço parado, porém um processo do agente continua ativo.' }
        'RebootRequired' { 'O Windows precisa concluir uma alteração pendente no serviço.' }
        'CorruptOrIncomplete' { 'Registro do serviço está incompleto ou aponta para um arquivo ausente.' }
        'ServiceStarting' { 'Serviço iniciando. Isso pode levar alguns minutos após uma instalação.' }
        'ServiceStopping' { 'Serviço parando.' }
        default { "Não foi possível classificar o serviço (estado informado: $($ServiceState.Status))." }
    }
}

function Set-OCSServiceStartType {
    param([ValidateSet('Automatic', 'Manual', 'Disabled')][string]$StartupType)
    try {
        Set-Service -Name $ServiceName -StartupType $StartupType -ErrorAction Stop
        Write-InstallerLog "StartType ajustado para $StartupType via Set-Service."
        return
    } catch {
        $message = ("$($_.Exception.Message)" -replace '[\x00-\x1f\x7f]+', ' ').Trim()
        Write-InstallerLog "Set-Service StartupType=$StartupType falhou: $message" 'AVISO'
        if ($message -match '1072|marked for delete|marcado para ser excl') {
            throw (New-OCSRebootRequiredError "Set-Service StartupType=$StartupType => ERROR_SERVICE_MARKED_FOR_DELETE ($ErrorServiceMarkedForDelete). $message")
        }
    }
    $map = @{ Automatic = 'auto'; Manual = 'demand'; Disabled = 'disabled' }
    # Uma unica tentativa de fallback. sc.exe 1072 vira reinicializacao necessaria, nunca um loop.
    $null = Invoke-ServiceControllerTool @('config', $ServiceName, 'start=', $map[$StartupType])
    Write-InstallerLog "StartType ajustado para $StartupType via sc.exe config."
}

function Set-OCSServiceState {
    param([ValidateSet('Running', 'Stopped')][string]$Target, [int]$TimeoutSeconds = 120)
    $state = Get-OCSServiceState
    if ($state.MarkedForDeletion) { throw (New-OCSRebootRequiredError $state.TechnicalDetails) }
    if (-not $state.Exists) { throw 'O servico do OCS nao esta registrado no Windows.' }
    $startTypeAttempted = $false
    $requested = $false
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    try {
        while ($true) {
            $state = Get-OCSServiceState
            if ($state.MarkedForDeletion) { throw (New-OCSRebootRequiredError $state.TechnicalDetails) }
            if ($Target -eq 'Running' -and -not $startTypeAttempted -and "$($state.StartType)" -notin @('Automatic', 'AutomaticDelayedStart')) {
                $startTypeAttempted = $true
                Set-OCSServiceStartType Automatic
                continue
            }
            if ("$($state.Status)" -eq $Target) { break }
            if ([DateTime]::UtcNow -ge $deadline) { throw [TimeoutException]::new('Service transition timeout') }
            # O setup pode retornar enquanto o servico ainda inicia ou para.
            # Esperar a transicao antes de enviar outro comando ao SCM.
            if (-not $requested -and "$($state.Status)" -notmatch 'Pending$') {
                if ($Target -eq 'Stopped') {
                    try { Stop-Service -Name $ServiceName -Force -WarningAction SilentlyContinue -ErrorAction Stop }
                    catch { $null = Invoke-ServiceControllerTool @('stop', $ServiceName) }
                } else {
                    try { Start-Service -Name $ServiceName -WarningAction SilentlyContinue -ErrorAction Stop }
                    catch { $null = Invoke-ServiceControllerTool @('start', $ServiceName) }
                }
                $requested = $true
            }
            Start-Sleep -Milliseconds 250
        }
        Write-InstallerLog "Servico: $Target"
    } catch {
        if (Test-OCSRebootRequiredError $_) { throw }
        $currentState = if ($state) { "$($state.State)/$($state.Status)" } else { 'indisponivel' }
        $errorType = $_.Exception.GetType().Name
        $reason = ($_.Exception.Message -replace '[\x00-\x1f\x7f]+', ' ').Trim()
        Write-InstallerLog "Controle do servico falhou: destino=$Target estado=$currentState tipo=$errorType motivo=$reason" 'ERRO'
        throw "Nao foi possivel colocar o servico OCS em $Target. Estado atual: $currentState. Motivo: $reason"
    }
}

function Start-OCSService { Set-OCSServiceState -Target Running }

# Corrige somente o servico, sem tocar em arquivos, registro de desinstalacao
# ou identidade do agente. Nunca chamado quando ha exclusao pendente.
function Repair-OCSService {
    param($ServiceState)
    if ($ServiceState.MarkedForDeletion -or $ServiceState.RebootRequired) {
        throw (New-OCSRebootRequiredError $ServiceState.TechnicalDetails)
    }
    if (-not $ServiceState.Exists) { throw 'O servico do OCS nao esta registrado no Windows.' }
    if ($ServiceState.State -eq 'CorruptOrIncomplete') {
        throw 'O registro do servico esta incompleto. Uma reinstalacao autorizada do agente e necessaria.'
    }
    Write-InstallerLog "Reparo do servico iniciado. Estado de origem: $($ServiceState.TechnicalDetails)"
    Set-OCSServiceState -Target Running
    return (Get-OCSServiceState)
}

# Espera processos terminarem. NUNCA encerra processo algum.
# Espera interativa pelo fim de um inventario em andamento. Nunca encerra o
# processo: apenas informa, aguarda em rodadas e deixa o tecnico decidir.
function Confirm-OCSInventoryWait {
    $running = @(Get-Process -Name OCSInventory -ErrorAction SilentlyContinue)
    if ($NoPause) {
        Write-InstallerLog "NoPause: espera finita de inventario ($InventoryQuietWaitSeconds s), sem perguntas."
        return (Wait-OCSProcessExit -Names @('OCSInventory') -TimeoutSeconds $InventoryQuietWaitSeconds)
    }
    Write-Friendly ''
    Write-Friendly 'Um inventário do OCS está em andamento neste momento.'
    if ($running.Count -gt 0 -and $running[0].StartTime) {
        $minutes = [int]([DateTime]::Now - $running[0].StartTime).TotalMinutes
        Write-Friendly ("Ele começou há cerca de {0} minuto(s)." -f $minutes)
    }
    Write-Friendly 'Isso pode levar vários minutos, porque inclui a varredura'
    Write-Friendly 'da rede (IpDiscover). Nada será alterado enquanto isso.'
    Write-Friendly ''
    $rounds = [Math]::Max(1, [int]([Math]::Ceiling($InventoryMaxWaitSeconds / $InventoryWaitRoundSeconds)))
    for ($round = 1; $round -le $rounds; $round++) {
        if (-not (Confirm-Yes ("Deseja aguardar mais {0} minuto(s)? [S/N]" -f [int]($InventoryWaitRoundSeconds / 60)))) {
            Write-InstallerLog "Usuario optou por nao aguardar o inventario em andamento (rodada $round)." 'AVISO'
            return $false
        }
        Write-InstallerDetail 'Aguardando o inventário terminar...'
        if (Wait-OCSProcessExit -Names @('OCSInventory') -TimeoutSeconds $InventoryWaitRoundSeconds) {
            Write-InstallerLog "Inventario em andamento terminou apos espera autorizada (rodada $round)."
            return $true
        }
    }
    Write-InstallerLog "Inventario continuou ativo apos o limite de espera de $InventoryMaxWaitSeconds s." 'AVISO'
    return $false
}

function Wait-OCSProcessExit {
    param([string[]]$Names, [int]$TimeoutSeconds = 120)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $running = @(Get-Process -Name $Names -ErrorAction SilentlyContinue | Where-Object { $_ })
        if ($running.Count -eq 0) { return $true }
        if ([DateTime]::UtcNow -ge $deadline) {
            $list = ($running | ForEach-Object { "$($_.Name)#$($_.Id)" }) -join ', '
            Write-InstallerLog "Processos do agente ainda ativos apos $TimeoutSeconds s: $list" 'AVISO'
            return $false
        }
        Start-Sleep -Milliseconds 500
    }
}

# ---------------------------------------------------------------------------
# Guarda de seguranca antes de qualquer setup.
#
# Esta e a correcao central do erro 1072: o setup oficial executa DeleteService
# quando o servico ja existe. Se OcsService.exe continuar ativo, o Windows
# marca o servico para exclusao e desabilita o inicio. Portanto o setup so
# roda depois que o servico parou E o processo saiu de verdade.
# ---------------------------------------------------------------------------
function Assert-OCSSafeToRunSetup {
    param($ServiceState, [bool]$AgentInstalled)
    if ($ServiceState.MarkedForDeletion -or $ServiceState.RebootRequired) {
        throw (New-OCSRebootRequiredError $ServiceState.TechnicalDetails)
    }
    if (-not $AgentInstalled) { return }
    Write-InstallerDetail 'Aguardando o agente liberar os arquivos...'
    # Um inventario em andamento pode levar vários minutos, porque inclui
    # varredura de rede (IpDiscover). Esperar pouco e culpar o Windows seria
    # incorreto: o agente apenas está trabalhando. Por isso a espera e
    # informativa e o usuário decide continuar aguardando.
    if (-not (Wait-OCSProcessExit -Names @('OCSInventory') -TimeoutSeconds $InventoryQuietWaitSeconds)) {
        if (-not (Confirm-OCSInventoryWait)) {
            throw (New-OCSAgentBusyError 'OCSInventory.exe ativo (inventario em andamento); setup nao executado para evitar disputa de arquivos. Nenhuma alteracao pendente do Windows.')
        }
    }
    if ($ServiceState.Exists) {
        Set-OCSServiceState -Target Stopped
        if (-not (Wait-OCSProcessExit -Names @('OcsService') -TimeoutSeconds 120)) {
            throw (New-OCSRebootRequiredError 'OcsService.exe permaneceu ativo depois da parada do servico; setup nao executado para evitar ERROR_SERVICE_MARKED_FOR_DELETE (1072).')
        }
    }
    Write-InstallerDetail 'Arquivos do agente liberados.'
}

function Invoke-OCSInventory {
    param($Agent, $Client)
    if (-not $Agent.Exe) { throw 'OCSInventory.exe nao encontrado apos instalacao.' }
    $script:Stage = 'Preparacao do servico'; $script:ResultCode = $ExitServiceFailed
    $serviceState = Wait-OCSServiceSettled (Get-OCSServiceState) $PostSetupSettleWaitSeconds
    if ((Test-OCSServiceInTransition $serviceState) -and (Wait-OCSProcessExit -Names @('OCSInventory') -TimeoutSeconds 0)) {
        # Servico preso em transicao sem inventario em andamento: nao ha o que
        # aguardar alem do SCM. Nao tratar como 3010 (nao ha exclusao pendente).
        $script:ResultCode = $ExitAgentBusy
        throw (New-OCSAgentBusyError "Servico em $($serviceState.Status) apos a espera de estabilizacao; inventario nao solicitado.")
    }
    if (-not (Test-OCSServiceInTransition $serviceState)) {
        Start-OCSService
    }

    $agentLog = Join-Path $AgentDataDirectory 'OCSInventory.log'
    $baseline = if (Test-Path -LiteralPath $agentLog) { Get-Content -LiteralPath $agentLog -Raw -ErrorAction SilentlyContinue } else { '' }
    if ($null -eq $baseline) { $baseline = '' }

    # Inventario automatico do servico (comum logo apos o setup) ou um
    # inventario anterior ainda rodando: esperar, nao disparar outro.
    $alreadyRunning = -not (Wait-OCSProcessExit -Names @('OCSInventory') -TimeoutSeconds 0)
    if ($script:AutoInventoryCompleted -or $alreadyRunning) {
        if ($alreadyRunning) {
            $script:InventoryAlreadyRunning = $true
            $script:InventoryStarted = $false
            Write-InstallerDetail 'Já existe um inventário em andamento. Nenhuma nova solicitação será enviada.'
            Write-InstallerLog 'InventoryAlreadyRunning=True InventoryStarted=False'
            $script:InventoryAgentExecution = 'Ja em execucao'
            $script:InventoryServerContact = 'Nao confirmado nesta sessao'
            $script:InventorySent = 'Ja em andamento'
            $script:InventoryResult = 'Inventario ja em execucao; nova solicitacao nao enviada'
            return
        }
        if (Read-OCSInventoryLogResult $agentLog $baseline) { return }
        if ($script:AutoInventoryCompleted) {
            $script:InventoryAgentExecution = 'Executado'
            $script:InventoryServerContact = 'Nao foi possivel confirmar'
            $script:InventorySent = 'Nao foi possivel confirmar'
            $script:InventoryResult = 'Agente executado; envio nao confirmado'
            Write-InstallerLog "Consulta automatica do servico: $script:InventoryResult"
            return
        }
    }

    $script:Stage = 'Inventario'; $script:ResultCode = $ExitInventoryFailed
    # O codigo 128 e o primeiro controle privado do servico OCS: Run Inventory Now.
    # O proprio servico libera os arquivos e executa o agente, sem disputa entre
    # OcsService.exe e OCSInventory.exe.
    $script:InventoryStarted = $true
    $null = Invoke-ServiceControllerTool @('control', $ServiceName, '128')

    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 1000
        if (Read-OCSInventoryLogResult $agentLog $baseline) { return }
    }
    if (-not (Wait-OCSProcessExit -Names @('OCSInventory') -TimeoutSeconds 0)) {
        Write-InstallerDetail 'O inventário ainda está em andamento (varredura de rede).'
        if ($NoPause) {
            $script:InventoryAgentExecution = 'Executado'
            $script:InventoryServerContact = 'Nao foi possivel confirmar'
            $script:InventorySent = 'Nao foi possivel confirmar'
            $script:InventoryResult = 'Agente executado; envio nao confirmado nesta sessao'
            Write-InstallerLog "NoPause: inventario solicitado ainda em andamento. InventoryStarted=True ExitCode=0"
            return
        }
        if (Confirm-OCSInventoryWait) {
            if (Read-OCSInventoryLogResult $agentLog $baseline) { return }
        }
        $script:InventoryAgentExecution = 'Executado'
        $script:InventoryServerContact = 'Nao foi possivel confirmar'
        $script:InventorySent = 'Nao foi possivel confirmar'
        $script:InventoryResult = 'Agente executado; envio nao confirmado nesta sessao'
        Write-InstallerLog "Inventario solicitado ainda em andamento; confirmacao adiada. InventoryStarted=True ExitCode=0"
        return
    }
    throw 'O servico recebeu a solicitacao, mas o resultado nao apareceu no log em ate 180 segundos.'
}

function Read-OCSInventoryLogResult {
    param([string]$AgentLog, [string]$Baseline)
    if (-not (Test-Path -LiteralPath $AgentLog -PathType Leaf)) { return $false }
    $current = Get-Content -LiteralPath $AgentLog -Raw -ErrorAction SilentlyContinue
    if ($null -eq $current -or $current -eq $Baseline) { return $false }
    $delta = if ($current.StartsWith($Baseline)) { $current.Substring($Baseline.Length) } else { $current }
    if ($delta -notmatch 'Execution duration:') { return $false }
    if ($delta -match 'ERROR \*\*\*') {
        throw 'O servico executou o agente, mas o log registrou erro. Consulte OCSInventory.log.'
    }
    $script:InventoryAgentExecution = 'Executado'
    if ($delta -match 'Inventory successfully sent') {
        $script:InventoryServerContact = 'Confirmado'
        $script:InventorySent = 'Confirmado'
        $script:InventoryResult = 'Inventario enviado'
    } elseif ($delta -match 'Prolog successfully sent') {
        $script:InventoryServerContact = 'Confirmado'
        $script:InventorySent = 'Nao solicitado'
        $script:InventoryResult = 'Servidor contatado; inventario nao solicitado'
    } else {
        $script:InventoryServerContact = 'Nao foi possivel confirmar'
        $script:InventorySent = 'Nao foi possivel confirmar'
        $script:InventoryResult = 'Agente executado; envio nao confirmado'
    }
    Write-InstallerLog "Consulta ao servidor: AgentExecution=$($script:InventoryAgentExecution) ServerContact=$($script:InventoryServerContact) InventorySent=$($script:InventorySent)"
    return $true
}

function Complete-OCSPostSetup {
    # Depois do setup o servico inicia sozinho e dispara um inventario. Esse
    # inventario pode levar varios minutos (IpDiscover) e, ao terminar, o
    # agente reescreve admininfo.conf com a TAG que carregou na memoria. A
    # TAG so pode ser considerada persistida DEPOIS que esse processo sair.
    $inventoryRunning = -not (Wait-OCSProcessExit -Names @('OCSInventory') -TimeoutSeconds 0)
    if ($inventoryRunning) {
        Write-InstallerDetail 'O serviço já iniciou um inventário. Aguardando terminar...'
        Write-InstallerLog 'Inventario automatico detectado apos o setup. TAG sera revalidada so depois que o processo sair.'
        if (-not (Wait-OCSProcessExit -Names @('OCSInventory') -TimeoutSeconds $InventoryQuietWaitSeconds)) {
            if (-not $NoPause) { [void](Confirm-OCSInventoryWait) }
            if (Test-OCSInventoryProcessRunning) {
                $script:InventoryAlreadyRunning = $true
                Write-InstallerLog 'Inventario automatico ainda ativo apos espera finita; configuracao sera relida mesmo assim. InventoryAlreadyRunning=True'
            } else {
                $script:AutoInventoryCompleted = $true
                Write-InstallerLog 'Inventario automatico pos-setup terminou.'
            }
        } else {
            $script:AutoInventoryCompleted = $true
            Write-InstallerLog 'Inventario automatico pos-setup terminou.'
        }
    }
    $serviceState = Wait-OCSServiceSettled (Get-OCSServiceState) $PostSetupSettleWaitSeconds
    Write-InstallerLog ('Servico apos espera pos-setup: ' + $serviceState.TechnicalDetails)
    return $serviceState
}

# ---------------------------------------------------------------------------
# Telas amigaveis. Detalhes tecnicos ficam no log.
# ---------------------------------------------------------------------------
function Show-OCSRebootRequiredNotice {
    param($Client, [string]$InstalledVersion, [string]$Tag)
    Write-Friendly ''
    Write-Friendly '========================================'
    Write-Friendly '       É NECESSÁRIO REINICIAR'
    Write-Friendly '========================================'
    Write-Friendly ''
    Write-Friendly 'O OCS Inventory já está instalado e configurado.'
    Write-Friendly ''
    Write-Friendly 'O Windows ainda está finalizando uma alteração'
    Write-Friendly 'anterior no serviço do OCS.'
    Write-Friendly ''
    Write-Friendly 'Nenhuma reinstalação foi realizada.'
    Write-Friendly ''
    Write-Friendly ("Cliente : {0}" -f $(if ($Client) { $Client.name } else { '(nao informado)' }))
    Write-Friendly ("Versão  : {0}" -f $(if ($InstalledVersion) { $InstalledVersion } else { '(nao identificada)' }))
    Write-Friendly ("TAG     : {0}" -f $(if ($Tag) { $Tag } else { '(nao identificada)' }))
    Write-Friendly ''
    Write-Friendly 'Reinicie o computador quando for conveniente e'
    Write-Friendly 'execute este instalador novamente.'
    Write-Friendly ''
    Write-Friendly 'Sua configuração foi preservada.'
    Write-Friendly ''
    Write-Friendly 'Código para suporte: 3010'
    Write-Friendly ''
    Write-InstallerLog "Resultado final=3010 RebootRequired=True Detalhes=$script:RebootTechnicalDetails"
}

function Show-OCSAgentBusyNotice {
    param($Client, [string]$InstalledVersion, [string]$Tag, [bool]$ConfigChangeAuthorized)
    Write-Friendly ''
    Write-Friendly '========================================'
    Write-Friendly '      O AGENTE ESTÁ OCUPADO AGORA'
    Write-Friendly '========================================'
    Write-Friendly ''
    Write-Friendly 'O OCS Inventory está instalado e funcionando, mas'
    Write-Friendly 'está ocupado com uma operação em andamento.'
    Write-Friendly ''
    Write-Friendly 'Nada foi alterado neste computador. Nenhuma'
    Write-Friendly 'instalação, atualização ou remoção foi realizada.'
    Write-Friendly ''
    Write-Friendly ("Cliente : {0}" -f $(if ($Client) { $Client.name } else { '(nao informado)' }))
    Write-Friendly ("Versão  : {0}" -f $(if ($InstalledVersion) { $InstalledVersion } else { '(nao identificada)' }))
    Write-Friendly ("TAG     : {0}" -f $(if ($Tag) { $Tag } else { '(nao identificada)' }))
    Write-Friendly ''
    if ($ConfigChangeAuthorized -and $Client -and $Tag -and ($Tag -cne $Client.tag)) {
        Write-Friendly ("ATENÇÃO: a troca para {0} NÃO foi aplicada." -f $Client.tag)
        Write-Friendly ("A TAG deste computador continua {0}." -f $Tag)
        Write-Friendly ''
    }
    Write-Friendly 'Um inventário do OCS pode levar vários minutos,'
    Write-Friendly 'porque inclui a varredura da rede (IpDiscover).'
    Write-Friendly ''
    Write-Friendly 'Aguarde alguns minutos e execute este instalador'
    Write-Friendly 'novamente. NÃO é necessário reiniciar o computador.'
    Write-Friendly ''
    Write-Friendly 'Código para suporte: 42'
    Write-Friendly ''
    Write-InstallerLog "Resultado final=42 AgenteOcupado=True ExitCode=42 Reason=$script:AgentBusyDetails"
}

function Show-OCSServiceReinstallNotice {
    param($ServiceState, [string]$InstalledVersion, $Client, [string]$Tag)
    Write-Friendly '========================================'
    Write-Friendly '     O SERVIÇO PRECISA SER RECRIADO'
    Write-Friendly '========================================'
    Write-Friendly ''
    if ($ServiceState.Exists) {
        Write-Friendly 'O OCS Inventory está instalado, mas o registro do'
        Write-Friendly 'serviço do Windows está incompleto.'
    } else {
        Write-Friendly 'O OCS Inventory está instalado, mas o serviço do'
        Write-Friendly 'Windows que envia o inventário não está registrado.'
        Write-Friendly ''
        Write-Friendly 'Isso acontece depois que o Windows conclui uma'
        Write-Friendly 'remoção pendente do serviço.'
    }
    Write-Friendly ''
    Write-Friendly ("Cliente : {0}" -f $Client.name)
    Write-Friendly ("Versão  : {0}" -f $(if ($InstalledVersion) { $InstalledVersion } else { '(nao identificada)' }))
    Write-Friendly ("TAG     : {0}" -f $(if ($Tag) { $Tag } else { '(nao identificada)' }))
    Write-Friendly ''
    Write-Friendly 'O instalador oficial precisa ser executado para'
    Write-Friendly 'recriar o serviço. Sua configuração e a identidade'
    Write-Friendly 'deste computador serão preservadas.'
    Write-Friendly ''
}

function Show-OCSUpdateAvailableNotice {
    param([string]$InstalledVersion, [string]$TargetVersion, $Client)
    Write-Friendly ''
    Write-Friendly '========================================'
    Write-Friendly '      ATUALIZAÇÃO DISPONÍVEL'
    Write-Friendly '========================================'
    Write-Friendly ''
    Write-Friendly ("OCS instalado    : {0}" -f $InstalledVersion)
    Write-Friendly ("Versão disponível: {0}" -f $TargetVersion)
    Write-Friendly ''
    Write-Friendly ("Cliente : {0}" -f $Client.name)
    Write-Friendly ("TAG     : {0}" -f $Client.tag)
    Write-Friendly ''
}

function Show-OCSNewerVersionNotice {
    param([string]$InstalledVersion, [string]$TargetVersion)
    Write-Friendly ''
    Write-Friendly 'Este computador já possui uma versão mais recente do OCS.'
    Write-Friendly ''
    Write-Friendly ("Versão instalada                  : {0}" -f $InstalledVersion)
    Write-Friendly ("Versão disponível neste instalador: {0}" -f $TargetVersion)
    Write-Friendly ''
    Write-Friendly 'Nenhum downgrade será realizado.'
    Write-Friendly ''
}

function Show-OCSConfigurationWarning {
    param([string]$Field, [string]$CurrentValue, [string]$SelectedValue)
    Write-Friendly ''
    Write-Friendly '========================================'
    Write-Friendly '        ATENÇÃO À CONFIGURAÇÃO'
    Write-Friendly '========================================'
    Write-Friendly ''
    Write-Friendly 'Este computador está configurado para outro cliente.'
    Write-Friendly ''
    Write-Friendly 'Configuração atual:'
    Write-Friendly ("{0}: {1}" -f $Field, $CurrentValue)
    Write-Friendly ''
    Write-Friendly 'Configuração selecionada:'
    Write-Friendly ("{0}: {1}" -f $Field, $SelectedValue)
    Write-Friendly ''
}

function Show-OCSReadyNotice {
    param([string]$Version, $Client, $ServiceState)
    Write-Friendly ''
    Write-Friendly '========================================'
    Write-Friendly '           OCS ESTÁ PRONTO'
    Write-Friendly '========================================'
    Write-Friendly ''
    Write-Friendly ("Versão : {0}" -f $(if ($Version) { $Version } else { '(nao identificada)' }))
    Write-Friendly ("Cliente: {0}" -f $Client.name)
    Write-Friendly ("TAG    : {0}" -f $Client.tag)
    Write-Friendly ''
    Write-Friendly 'Serviço:'
    Write-Friendly (Format-OCSServiceStateForUser $ServiceState)
    Write-Friendly ''
    Write-Friendly 'Nenhuma instalação ou atualização é necessária.'
    Write-Friendly ''
}

function Show-InstallationSummary {
    param($Client, $Agent, $ServiceState, $Existing)
    Write-Friendly ''
    Write-Friendly '========================================'
    Write-Friendly '           OPERAÇÃO CONCLUÍDA'
    Write-Friendly '========================================'
    Write-Friendly ''
    Write-Friendly ("Cliente selecionado : {0}" -f $(if ($Client) { $Client.name } else { '(nao informado)' }))
    Write-Friendly ("Servidor efetivo    : {0}" -f $(if ($Existing -and $Existing.Server) { Format-ExistingValue $Existing.Server -Url } else { '(nao determinado)' }))
    Write-Friendly ("TAG efetiva         : {0}" -f $(if ($Existing -and $Existing.Tag) { Format-ExistingValue $Existing.Tag } else { '(nao determinada)' }))
    Write-Friendly ("SSL efetivo         : {0}" -f $(if ($Existing -and $Existing.Ssl) { $Existing.Ssl } else { '(nao determinado)' }))
    Write-Friendly ("Versão              : {0}" -f $(if ($Agent -and $Agent.Version) { $Agent.Version } else { '(nao identificada)' }))
    Write-Friendly ("Serviço             : {0}" -f $(if ($ServiceState) { Format-OCSServiceStateForUser $ServiceState } else { '(nao determinado)' }))
    Write-Friendly ("Instalação          : {0}" -f $(if ($script:SetupPerformed) { 'Executada nesta sessão' } else { 'Não foi necessária' }))
    Write-Friendly ("Configuração pronta : {0}" -f $(if ($script:ConfigurationReady) { 'Sim' } else { 'Nao' }))
    Write-Friendly ("Execucao do agente  : {0}" -f $script:InventoryAgentExecution)
    Write-Friendly ("Contato com servidor: {0}" -f $script:InventoryServerContact)
    Write-Friendly ("Inventário enviado  : {0}" -f $script:InventorySent)
    Write-Friendly ''
    if ($script:RebootRequired) {
        Write-Friendly 'Instalação concluída.'
        Write-Friendly 'Reinicialização necessária antes de executar nova consulta ao servidor.'
    } elseif (-not $script:ConfigurationReady) {
        Write-Friendly 'A configuração selecionada NÃO foi aplicada neste computador.'
        Write-Friendly 'Nenhuma consulta ao servidor foi disparada para o cliente do menu.'
    } else {
        Write-Friendly 'Confira a recepção do inventário e a TAG no servidor.'
    }
}

function Confirm-OCSConfigurationChange {
    param($Existing, $Client)
    $tagKnown = [bool]$Existing.Tag
    $serverKnown = [bool]$Existing.Server
    $sslKnown = ($null -ne $Existing.Ssl -and "$($Existing.Ssl)" -ne '')
    $tagMatches = $tagKnown -and ($Existing.Tag -ceq $Client.tag)
    $serverMatches = $serverKnown -and (Test-OCSServerUrlEquals $Client.server $Existing.Server)
    $sslMatches = $sslKnown -and ("$($Existing.Ssl)" -in @('1', 'True'))

    if ($tagKnown -and -not $tagMatches) {
        Show-OCSConfigurationWarning 'TAG' (Format-ExistingValue $Existing.Tag) $Client.tag
        if (-not (Confirm-Yes ("Deseja realmente alterar este computador para {0}? [S/N]" -f $Client.tag))) {
            Write-InstallerLog 'Troca de TAG recusada pelo usuario. Nada foi alterado.'
            return $false
        }
        Write-InstallerLog "Troca de TAG autorizada explicitamente pelo usuario."
    }
    if ($serverKnown -and -not $serverMatches) {
        Show-OCSConfigurationWarning 'Servidor' (Format-ExistingValue $Existing.Server -Url) $Client.server
        if (-not (Confirm-Yes 'Deseja realmente alterar o servidor deste computador? [S/N]')) {
            Write-InstallerLog 'Troca de servidor recusada pelo usuario. Nada foi alterado.'
            return $false
        }
        Write-InstallerLog 'Troca de servidor autorizada explicitamente pelo usuario.'
    }
    if ($sslKnown -and -not $sslMatches) {
        Show-OCSConfigurationWarning 'SSL' (Format-ExistingValue $Existing.Ssl) '1'
        if (-not (Confirm-Yes 'Deseja reaplicar a configuracao com validacao TLS habilitada? [S/N]')) {
            Write-InstallerLog 'Correcao de SSL recusada pelo usuario. Nada foi alterado.'
            return $false
        }
        Write-InstallerLog 'Correcao de SSL autorizada explicitamente pelo usuario.'
    }
    if (-not $tagKnown -or -not $serverKnown -or -not $sslKnown) {
        Write-Friendly ''
        Write-Friendly 'Não foi possível confirmar a configuração atual deste computador.'
        if (-not $sslKnown) { Write-Friendly 'O estado SSL atual não pôde ser lido.' }
        if (-not (Confirm-Yes 'Deseja aplicar a configuracao selecionada? [S/N]')) {
            Write-InstallerLog 'Aplicacao de configuracao recusada pelo usuario com configuracao atual desconhecida.'
            return $false
        }
        Write-InstallerLog 'Usuario autorizou aplicar a configuracao com valores atuais desconhecidos.'
    }
    return $true
}

function Invoke-InstallerMain {
    $client = $null
    $agent = $null
    $existing = $null
    $serviceState = $null
    $targetVersion = $null
    $elevatedChild = $false
    $authorizedConfigChange = $false
    $script:SetupPerformed = $false
    $script:AutoInventoryCompleted = $false
    $script:ConfigurationReady = $false
    $script:RebootRequired = $false
    $script:RebootTechnicalDetails = $null
    $script:AgentBusyDetails = $null
    $script:InventoryResult = 'Nao executado'
    $script:InventoryAgentExecution = 'Nao executado'
    $script:InventoryServerContact = 'Nao confirmado'
    $script:InventorySent = 'Nao foi possivel confirmar'
    $script:InventoryRequested = [bool]$RunInventory
    $script:InventoryAlreadyRunning = $false
    $script:InventoryStarted = $false
    $script:MutationRequired = $false
    $script:StepIndex = 0
    try {
        if (-not $DryRun -and -not (Test-Administrator)) { $elevatedChild = $true; return (Restart-AsAdministrator) }
        $logBase = Join-Path $env:ProgramData 'OCSInstaller\Logs'
        if ($DryRun -and -not (Test-Administrator)) { $logBase = Join-Path $env:TEMP 'OCSInstaller\Logs' }
        New-Item -ItemType Directory -Force -Path $logBase -ErrorAction Stop | Out-Null
        $script:LogPath = Join-Path $logBase ('OCS-Install-{0}-{1}.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'), [guid]::NewGuid().ToString('N'))
        Write-InstallerLog "Computador=$env:COMPUTERNAME Usuario=$([Security.Principal.WindowsIdentity]::GetCurrent().Name) x64=$([Environment]::Is64BitOperatingSystem) DryRun=$DryRun"

        $script:Stage = 'Configuracao dos clientes'; $script:ResultCode = $ExitClientConfig
        if ($ClientTag -and $script:ClientIndexSpecified) { throw 'Use ClientTag ou ClientIndex, nao os dois.' }
        $clients = @(Read-ClientConfiguration $ClientsPath)
        $requestedIndex = $null
        if ($script:ClientIndexSpecified -or ($ClientIndex -gt 0 -and -not $ClientTag)) { $requestedIndex = $ClientIndex }
        $client = Select-Client -Clients $clients -RequestedIndex $requestedIndex -RequestedTag $ClientTag
        if (-not $client) { Write-InstallerLog 'Cancelado pelo usuario.'; return $ExitUserCancel }
        $menuIndex = 0
        for ($i = 0; $i -lt $clients.Count; $i++) {
            if ($clients[$i].tag -ceq $client.tag -and $clients[$i].name -ceq $client.name) { $menuIndex = $i + 1; break }
        }
        Write-InstallerLog "MenuIndex=$menuIndex ClientName=$($client.name) ClientTag=$($client.tag) Servidor=$($client.server)"
        if (-not $DryRun -and -not (Confirm-ClientSelection $client)) { Write-InstallerLog 'Selecao de cliente recusada.'; return $ExitUserCancel }

        $script:Stage = 'Pacote do agente'; $script:ResultCode = $ExitPackage
        Select-OCSInstallerPackage
        if ($InstallerArchitecture -notin @('universal', 'x64', 'x86')) { throw 'InstallerArchitecture invalida.' }
        if ($InstallerArchitecture -eq 'x64' -and -not [Environment]::Is64BitOperatingSystem) { throw 'Pacote x64 incompativel com Windows x86.' }
        if ($InstallerSHA256 -and $InstallerSHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'InstallerSHA256 deve conter 64 caracteres hexadecimais.' }
        $targetVersion = Resolve-OCSTargetVersion
        if (-not (ConvertTo-OCSVersion $targetVersion)) {
            if (Get-OCSInstallerLocalPath) {
                throw 'O instalador esta disponivel, mas FileVersion/ProductVersion nao puderam ser lidas. Nenhuma decisao de atualizacao ou downgrade sera tomada.'
            }
            throw 'Nao foi possivel determinar a versao do pacote do agente.'
        }

        # ---- [1/5] Deteccao -------------------------------------------------
        Write-InstallerStep 'Verificando o OCS Inventory...'
        $script:Stage = 'Deteccao'; $script:ResultCode = $ExitPackage
        $agent = Get-InstalledOCSAgent
        $serviceState = Get-OCSServiceState
        $existing = Get-ExistingOCSConfiguration
        $versionState = Get-OCSVersionState -Installed $agent.Found -InstalledVersion $agent.Version -TargetVersion $targetVersion
        Write-InstallerLog ("Deteccao: Encontrado=$($agent.Found) VersaoInstalada=$($agent.Version) VersaoAlvo=$targetVersion EstadoVersao=$versionState Arquitetura=$InstallerArchitecture")
        Write-InstallerLog ("Servico: " + $serviceState.TechnicalDetails)
        Write-InstallerLog ("Configuracao lida: ServerConhecido=$([bool]$existing.Server) TagConhecida=$([bool]$existing.Tag) TagAtual=$($existing.Tag) SslAtual=$($existing.Ssl) CaBundleAtual=$($existing.CaBundle)")

        if ($agent.Found) {
            if ($agent.Version) { Write-InstallerDetail "OCS Inventory $($agent.Version) encontrado." }
            else { Write-InstallerDetail 'OCS Inventory encontrado, mas a versão não pôde ser identificada.' 'Yellow' }
        } else {
            Write-InstallerDetail 'OCS Inventory ainda não está instalado neste computador.'
        }

        # Exclusao pendente do servico: parar tudo aqui, antes de qualquer alteracao.
        if ($serviceState.MarkedForDeletion -or $serviceState.RebootRequired) {
            $script:RebootRequired = $true
            $script:RebootTechnicalDetails = $serviceState.TechnicalDetails
            Write-InstallerLog ("Interrompendo por exclusao/alteracao pendente do servico. Nenhuma instalacao, reparo ou atualizacao executada. " + $serviceState.TechnicalDetails) 'ERRO'
            Show-OCSRebootRequiredNotice $client $agent.Version $existing.Tag
            $script:Stage = 'Servico'; $script:ResultCode = $ExitRebootRequired
            return $ExitRebootRequired
        }

        if ($agent.Found -and (Get-OptionalValue $existing 'HasCredentials' $false)) {
            throw 'Configuracao existente possui credenciais. Migre-as por procedimento seguro antes de usar este instalador.'
        }

        # ---- [2/5] Configuracao --------------------------------------------
        Write-InstallerStep 'Conferindo a configuração...'
        $script:Stage = 'Configuracao existente'
        $configurationMatches = $true
        $authorizedConfigChange = $false
        $caMigrationRequired = $false
        if ($agent.Found) {
            $effective = Test-OCSEffectiveConfiguration $existing $client
            if ($effective.ServerMatches) { Write-InstallerDetail 'Servidor correto.' }
            elseif ($existing.Server) { Write-InstallerDetail 'Servidor diferente do selecionado.' 'Yellow' }
            else { Write-InstallerDetail 'Servidor atual não pôde ser determinado.' 'Yellow' }
            if ($effective.TagMatches) { Write-InstallerDetail 'TAG correta.' }
            elseif ($existing.Tag) { Write-InstallerDetail ("TAG atual é {0}, diferente da selecionada." -f (Format-ExistingValue $existing.Tag)) 'Yellow' }
            else { Write-InstallerDetail 'TAG atual não pôde ser determinada.' 'Yellow' }
            if ($effective.SslMatches) { Write-InstallerDetail 'SSL habilitado.' }
            elseif ($null -ne $existing.Ssl -and "$($existing.Ssl)" -ne '') { Write-InstallerDetail ("SSL atual é {0}; a política exige 1." -f $existing.Ssl) 'Yellow' }
            else { Write-InstallerDetail 'SSL atual não pôde ser determinado.' 'Yellow' }
            Write-InstallerDetail ("Bundle CA atual: {0}" -f $(if ($existing.CaBundle) { Format-ExistingValue $existing.CaBundle } else { '(ausente)' }))
            Write-InstallerDetail ("Bundle CA esperado: {0}" -f $effective.ExpectedCaBundle)
            if ($effective.CaBundleReady) { Write-InstallerDetail 'Bundle CA correto.' }
            elseif ($effective.IdentityMatches) { Write-InstallerDetail 'Bundle CA: migracao necessaria.' 'Yellow' }
            else { Write-InstallerDetail 'Bundle CA ainda nao confere com o esperado.' 'Yellow' }
            Write-InstallerLog ("CaBundleAtual=$($existing.CaBundle) CaBundleEsperado=$($effective.ExpectedCaBundle) CaBundleExiste=$($effective.CaBundleFileExists) CaMigrationRequired=$($effective.CaMigrationRequired)")
            $configurationMatches = [bool]$effective.IdentityMatches
            $caMigrationRequired = [bool]$effective.CaMigrationRequired
            $script:ConfigurationReady = [bool]$effective.Ready
            if (-not $effective.IdentityMatches -and -not $DryRun) {
                if (-not (Confirm-OCSConfigurationChange $existing $client)) {
                    Write-InstallerLog "Decisao de configuracao: Coincide=False Pronta=False MudancaAutorizada=False"
                    return $ExitUserCancel
                }
                $authorizedConfigChange = $true
            } elseif (-not $effective.IdentityMatches) {
                Write-InstallerLog 'DryRun: exigiria confirmacao explicita antes de alterar TAG/servidor.'
            }
            if ($caMigrationRequired -and $DryRun) {
                Write-InstallerLog 'DryRun: seria necessario gerar o novo bundle CA e atualizar a configuracao.'
                Write-InstallerLog 'DryRun: nenhum arquivo CA, INI, servico ou inventario sera alterado.'
            }
        } else {
            Write-InstallerDetail 'Nenhuma configuração anterior para conferir.'
        }
        Write-InstallerLog "Decisao de configuracao: Coincide=$configurationMatches Pronta=$($script:ConfigurationReady) CaMigrationRequired=$caMigrationRequired MudancaAutorizada=$authorizedConfigChange"

        # ---- [3/5] Servico --------------------------------------------------
        Write-InstallerStep 'Conferindo o serviço...'
        $script:Stage = 'Servico'
        # StartPending/StopPending e transicao, nao diagnostico: aguardar.
        $serviceState = Wait-OCSServiceSettled $serviceState
        Write-InstallerDetail (Format-OCSServiceStateForUser $serviceState) $(if ($serviceState.Healthy -or -not $agent.Found) { $null } else { 'Yellow' })
        $serviceInTransition = Test-OCSServiceInTransition $serviceState
        if ($serviceInTransition) {
            Write-InstallerDetail 'Nenhuma alteração será feita enquanto o serviço estiver em transição.' 'Yellow'
        }
        $repairService = [bool]($agent.Found -and $serviceState.NeedsRepair)
        # Agente instalado sem servico registrado, ou com registro incompleto:
        # nao existe reparo possivel pelo SCM. Somente o instalador oficial
        # recria o servico, e isso exige autorizacao explicita.
        $serviceNeedsReinstall = [bool]($agent.Found -and ($serviceState.State -eq 'CorruptOrIncomplete' -or -not $serviceState.Exists))
        if ($serviceNeedsReinstall) {
            Write-InstallerDetail 'Somente uma reinstalação autorizada pode recriar o serviço.' 'Yellow'
        }
        Write-InstallerLog "Decisao de servico: Estado=$($serviceState.State) Saudavel=$($serviceState.Healthy) ReparoNecessario=$repairService RecriacaoNecessaria=$serviceNeedsReinstall EmTransicao=$serviceInTransition"

        # ---- [4/5] Versao ---------------------------------------------------
        Write-InstallerStep 'Conferindo versão...'
        $script:Stage = 'Versao'
        $performSetup = $false
        $isUpdate = $false
        switch ($versionState) {
            'NotInstalled' {
                Write-InstallerDetail ("Será instalado o OCS Inventory {0} ({1})." -f $targetVersion, $InstallerArchitecture)
                $performSetup = $true
            }
            'Older' {
                if ($DryRun) {
                    Write-InstallerLog 'DryRun: ofereceria atualizacao e exigiria confirmacao.'
                } else {
                    Show-OCSUpdateAvailableNotice $agent.Version $targetVersion $client
                    if (Confirm-Yes 'Deseja atualizar o OCS Inventory Agent? [S/N]') {
                        $performSetup = $true; $isUpdate = $true
                        Write-InstallerLog "Atualizacao autorizada: $($agent.Version) -> $targetVersion"
                    } else {
                        # Recusar atualizacao nao e erro.
                        Write-InstallerDetail 'Atualização dispensada. A versão atual será mantida.'
                        Write-InstallerLog 'Atualizacao recusada pelo usuario. Nao e considerado erro.'
                    }
                }
            }
            'Current' {
                Write-InstallerDetail 'Nenhuma atualização necessária.'
                if ($authorizedConfigChange -or $caMigrationRequired) {
                    if ($caMigrationRequired -and -not $authorizedConfigChange) {
                        Write-InstallerDetail 'O bundle CA sera migrado pelo instalador oficial.'
                    } else {
                        Write-InstallerDetail 'A configuração autorizada será reaplicada pelo instalador oficial.'
                    }
                    $performSetup = $true
                }
            }
            'Newer' {
                Show-OCSNewerVersionNotice $agent.Version $targetVersion
                Write-InstallerLog "Downgrade bloqueado: instalada=$($agent.Version) pacote=$targetVersion"
                if ($authorizedConfigChange) {
                    Write-InstallerDetail 'A troca de configuração exige um instalador da mesma versão ou mais recente.' 'Yellow'
                    Write-InstallerLog 'Mudanca de configuracao autorizada nao aplicada: exigiria downgrade do pacote.' 'AVISO'
                }
                if ($caMigrationRequired) {
                    Write-InstallerDetail 'A migracao do bundle CA exige um instalador da mesma versao ou mais recente.' 'Yellow'
                    Write-InstallerLog 'Migracao de CA nao aplicada: exigiria downgrade do pacote.' 'AVISO'
                }
            }
            default {
                Write-InstallerDetail 'Não foi possível identificar a versão instalada.' 'Yellow'
                if ($DryRun) {
                    Write-InstallerLog 'DryRun: exigiria confirmacao explicita antes de reinstalar com versao desconhecida.'
                } elseif (Confirm-Yes 'Deseja reinstalar o agente com o pacote deste instalador? [S/N]') {
                    $performSetup = $true
                    Write-InstallerLog 'Reinstalacao com versao desconhecida autorizada pelo usuario.'
                } else {
                    Write-InstallerLog 'Versao desconhecida: reinstalacao nao autorizada. Nada foi alterado.'
                }
            }
        }
        # Servico ausente ou incompleto nao e "reparavel" pelo SCM: somente o
        # instalador oficial recria o registro, e isso exige autorizacao.
        # Este e o estado tipico depois de um reboot que concluiu a exclusao
        # pendente do servico (ERROR_SERVICE_MARKED_FOR_DELETE).
        if ($serviceNeedsReinstall -and -not $performSetup -and -not $DryRun) {
            Write-Friendly ''
            Show-OCSServiceReinstallNotice $serviceState $agent.Version $client $existing.Tag
            if ($versionState -eq 'Newer') {
                Write-InstallerLog 'Servico nao recriado: exigiria downgrade do agente.' 'ERRO'
                $script:ResultCode = $ExitServiceCorrupt
                throw 'O servico precisa ser recriado, mas este instalador faria downgrade do agente. Use um pacote igual ou mais recente que a versao instalada.'
            }
            if (Confirm-Yes 'Deseja reinstalar o agente para recriar o servico? [S/N]') {
                $performSetup = $true
                Write-InstallerLog "Reinstalacao autorizada para recriar o servico. Estado de origem: $($serviceState.State)"
            } else {
                Write-InstallerLog "Reinstalacao para recriar o servico recusada pelo usuario. Nada foi alterado. Estado: $($serviceState.State)" 'ERRO'
                $script:ResultCode = $ExitServiceCorrupt
                throw 'O servico do OCS continua ausente ou incompleto. Nenhuma alteracao foi realizada.'
            }
        }
        Write-InstallerLog "Decisao de versao: Estado=$versionState ExecutarSetup=$performSetup Atualizacao=$isUpdate"
        $script:MutationRequired = [bool]($performSetup -or $repairService -or $serviceNeedsReinstall -or $caMigrationRequired -or $authorizedConfigChange)
        Write-InstallerLog "MutationRequired=$($script:MutationRequired) InventoryRequested=$($script:InventoryRequested)"
        if ($serviceInTransition -and $script:MutationRequired -and -not $DryRun) {
            $script:ResultCode = $ExitAgentBusy
            throw (New-OCSAgentBusyError "Servico em $($serviceState.Status) apos a espera de estabilizacao; mutacao obrigatoria nao executada.")
        }
        if ($serviceInTransition -and -not $script:MutationRequired) {
            Write-InstallerLog "Servico em transicao sem mutacao obrigatoria; codigo 42 nao se aplica. Status=$($serviceState.Status)"
        }

        Write-InstallerLog ('Setup planejado: ' + (Get-OCSArguments $client Setup))
        Write-InstallerLog ('Inventario direto (nao utilizado; apenas referencia): ' + (Get-OCSArguments $client Inventory))

        if ($DryRun) {
            Write-InstallerLog 'DryRun: nenhum arquivo OCS, processo, registro ou servico alterado.'
            try { $previewPath = Get-OCSInstaller -Preview; Write-InstallerLog "Pacote: $previewPath" }
            catch { Write-InstallerLog $_.Exception.Message 'AVISO'; $script:ResultCode = $ExitPackage; return $ExitPackage }
            Write-InstallerLog "Resultado final=0 DryRun concluido. ConfiguracaoPronta=$($script:ConfigurationReady) MutationRequired=$($script:MutationRequired) InventoryRequested=False InventoryAlreadyRunning=False InventoryStarted=False"
            return $ExitSuccess
        }

        # ---- Acao: instalacao ou atualizacao --------------------------------
        if ($performSetup) {
            $script:Stage = 'Instalacao e configuracao'; $script:ResultCode = $ExitSetupFailed
            Write-InstallerDetail 'Preparando os certificados para uma conexão segura...'
            Initialize-OCSCertificateBundle $client
            Assert-OCSCaBundleReady
            $installer = Get-OCSInstaller
            $fromExe = Resolve-OCSTargetVersion -InstallerPath $installer
            if (-not (ConvertTo-OCSVersion $fromExe)) {
                throw 'O instalador esta disponivel, mas FileVersion/ProductVersion nao puderam ser lidas. Nenhuma decisao de atualizacao ou downgrade sera tomada.'
            }
            $provisional = ConvertTo-OCSVersion $targetVersion
            $actual = ConvertTo-OCSVersion $fromExe
            if ($provisional -and $actual -and ($provisional -ne $actual)) {
                throw ("A versao real do instalador ($fromExe) diverge da versao provisoria ($targetVersion). Interrompido para evitar upgrade/downgrade com versao suposta.")
            }
            $targetVersion = $fromExe
            $serviceState = Get-OCSServiceState
            Assert-OCSSafeToRunSetup $serviceState ([bool]$agent.Found)
            Write-InstallerDetail 'Instalando o agente. Isso pode levar alguns minutos...'
            $rawExitCode = if ($agent.Found) { Set-OCSConfiguration $installer $client } else { Install-OCSAgent $installer $client }
            $setupExitCode = 0
            foreach ($candidate in @($rawExitCode)) { if ($null -ne $candidate -and "$candidate" -match '^-?\d+$') { $setupExitCode = [int]$candidate } }

            $agent = Get-InstalledOCSAgent
            $serviceState = Get-OCSServiceState
            $outcome = Test-OCSUpdateOutcome $setupExitCode $agent.Version $targetVersion
            Write-InstallerLog ("Resultado do setup: ExitCode=$setupExitCode Aplicado=$($outcome.Applied) EstadoVersao=$($outcome.VersionState) VersaoEmDisco=$($agent.Version) Motivo=$($outcome.Reason)")
            Write-InstallerLog ('Servico apos setup: ' + $serviceState.TechnicalDetails)

            if ($serviceState.MarkedForDeletion -or $serviceState.RebootRequired) {
                $existing = Get-ExistingOCSConfiguration
                $script:RebootRequired = $true
                $script:RebootTechnicalDetails = $serviceState.TechnicalDetails
                Write-InstallerLog 'Servico ficou com alteracao pendente depois do setup. Nenhuma tentativa adicional sera feita.' 'ERRO'
                Show-OCSRebootRequiredNotice $client $agent.Version $existing.Tag
                $script:ResultCode = $ExitRebootRequired
                return $ExitRebootRequired
            }
            if (-not $outcome.Applied) {
                # Setup exit 0 nao autoriza declarar sucesso.
                $script:ResultCode = $ExitUpdateNotApplied
                throw ('A instalacao terminou sem erro, mas a versao em disco nao corresponde ao pacote. ' + $outcome.Reason)
            }

            # O servico recem-instalado dispara inventario sozinho. Esperar esse
            # processo sair ANTES de reler a TAG: o agente reescreve
            # admininfo.conf com o valor que carregou na memoria ao iniciar.
            $serviceState = Complete-OCSPostSetup
            $existing = Get-ExistingOCSConfiguration
            $effective = Test-OCSEffectiveConfiguration $existing $client
            if (-not $effective.Ready) {
                Write-InstallerLog "Configuracao apos inventario automatico nao coincide (TAG=$($existing.Tag) SERVER=$($existing.Server) SSL=$($existing.Ssl) CaBundle=$($existing.CaBundle)). Reaplicando uma vez a configuracao autorizada." 'AVISO'
                Write-InstallerDetail 'A configuração efetiva ainda não corresponde à selecionada. Reaplicando...' 'Yellow'
                $serviceState = Get-OCSServiceState
                Assert-OCSSafeToRunSetup $serviceState $true
                $null = Set-OCSConfiguration $installer $client
                $serviceState = Complete-OCSPostSetup
                $existing = Get-ExistingOCSConfiguration
                $effective = Test-OCSEffectiveConfiguration $existing $client
            }
            if (-not $effective.Ready) {
                $script:ConfigurationReady = $false
                $script:ResultCode = $ExitConfigNotPersisted
                throw 'Servidor, TAG, SSL ou bundle CA persistidos nao correspondem ao cliente selecionado.'
            }
            $script:ConfigurationReady = $true
            $configurationMatches = $true
            Write-InstallerLog ("CaBundleAtual=$($existing.CaBundle) CaBundleEsperado=$(Get-OCSExpectedCaBundlePath) CaBundleExiste=True CaMigrationRequired=False Pronta=True")
            Write-InstallerDetail ("Agente {0} instalado e configuração conferida." -f $agent.Version) 'Green'
            $repairService = [bool]$serviceState.NeedsRepair
            if ($outcome.RebootRequired) {
                $script:RebootRequired = $true
                Write-InstallerLog 'Setup retornou 3010: instalacao registrada; consulta ao servidor adiada ate a reinicializacao.'
                $serviceState = Get-OCSServiceState
                Show-InstallationSummary $client $agent $serviceState $existing
                Write-InstallerLog "Resultado final=3010 Instalacao=$($script:SetupPerformed) RebootRequired=True ConfiguracaoPronta=$($script:ConfigurationReady)"
                $script:ResultCode = $ExitRebootRequired
                return $ExitRebootRequired
            }
        }

        # ---- [5/5] Servico saudavel e inventario ----------------------------
        if (-not $script:ConfigurationReady) {
            $existing = Get-ExistingOCSConfiguration
            $script:ConfigurationReady = [bool](Test-OCSEffectiveConfiguration $existing $client).Ready
        }
        $shouldInventory = $false
        $script:InventoryAlreadyRunning = Test-OCSInventoryProcessRunning
        if ($script:RebootRequired) {
            Write-InstallerLog 'Consulta ao servidor nao sera disparada: reinicializacao necessaria.'
        } elseif (-not $script:ConfigurationReady) {
            Write-Friendly ''
            Write-Friendly 'A configuração selecionada não foi aplicada neste computador.'
            Write-Friendly ("TAG efetiva : {0}" -f $(if ($existing.Tag) { Format-ExistingValue $existing.Tag } else { '(nao determinada)' }))
            Write-Friendly ("TAG pedida  : {0}" -f $client.tag)
            Write-Friendly 'Nenhuma consulta ao servidor será disparada para o cliente do menu.'
            Write-InstallerLog 'Consulta ao servidor bloqueada: ConfigurationReady=False. Nada foi inventariado para o cliente selecionado.'
        } elseif ($RunInventory) {
            $shouldInventory = $true
        } elseif ($performSetup) {
            $shouldInventory = $true
        } elseif ($repairService) {
            Write-Friendly ''
            Write-Friendly 'O agente e a configuração estão corretos, mas o serviço precisa ser corrigido.'
            if (Confirm-Yes 'Deseja corrigir o servico e consultar o servidor agora? [S/N]') {
                $shouldInventory = $true
            } else {
                $repairService = $false
                Write-InstallerLog 'Correcao do servico recusada pelo usuario. Nada foi alterado.'
            }
        } elseif ($NoPause) {
            if ($versionState -eq 'Current' -and $serviceState.Healthy) {
                Show-OCSReadyNotice $agent.Version $client $serviceState
            }
            Write-InstallerLog 'NoPause: maquina pronta; inventario opcional nao sera solicitado.'
            $shouldInventory = $false
        } elseif ($versionState -eq 'Current' -and $serviceState.Healthy) {
            Show-OCSReadyNotice $agent.Version $client $serviceState
            $shouldInventory = (Confirm-OCSOptionalAction 'Deseja executar o agente OCS e consultar o servidor agora? [S/N]')
        } else {
            $shouldInventory = (Confirm-OCSOptionalAction 'Deseja executar o agente OCS e consultar o servidor agora? [S/N]')
        }
        $script:InventoryRequested = [bool]$shouldInventory
        Write-InstallerLog "Decisao de inventario: Executar=$shouldInventory ReparoServico=$repairService ConfiguracaoPronta=$($script:ConfigurationReady) InventoryRequested=$($script:InventoryRequested) InventoryAlreadyRunning=$($script:InventoryAlreadyRunning) InventoryStarted=$($script:InventoryStarted) MutationRequired=$($script:MutationRequired)"

        if ($repairService) {
            $script:Stage = 'Reparo do servico'
            $script:ResultCode = if ($serviceState.State -eq 'CorruptOrIncomplete') { $ExitServiceCorrupt } else { $ExitServiceFailed }
            Write-Friendly ''
            Write-Friendly 'Corrigindo o serviço do OCS...'
            $serviceState = Repair-OCSService $serviceState
            Write-InstallerDetail (Format-OCSServiceStateForUser $serviceState)
            Write-InstallerLog ('Servico apos reparo: ' + $serviceState.TechnicalDetails)
        }

        if ($shouldInventory -and $script:InventoryAlreadyRunning) {
            $script:InventoryStarted = $false
            $script:InventoryAgentExecution = 'Ja em execucao'
            $script:InventoryServerContact = 'Nao confirmado nesta sessao'
            $script:InventorySent = 'Ja em andamento'
            $script:InventoryResult = 'Inventario ja em execucao; nova solicitacao nao enviada'
            Write-InstallerDetail 'Já existe um inventário em andamento. Nenhuma nova solicitação será enviada.'
            Write-InstallerLog 'InventoryAlreadyRunning=True InventoryStarted=False'
        } elseif ($shouldInventory) {
            Write-InstallerStep 'Consultando o servidor OCS...'
            $script:Stage = 'Inventario'; $script:ResultCode = $ExitInventoryFailed
            Invoke-OCSInventory $agent $client
            Write-InstallerDetail ("Execucao do agente: {0}." -f $script:InventoryAgentExecution) 'Green'
            Write-InstallerDetail ("Contato com servidor: {0}." -f $script:InventoryServerContact)
            Write-InstallerDetail ("Inventário enviado: {0}." -f $script:InventorySent)
        } else {
            Write-InstallerLog 'Consulta ao servidor nao solicitada. InventoryStarted=False'
            Write-Friendly ''
            Write-Friendly 'Nenhuma consulta ao servidor foi solicitada.'
        }

        $script:Stage = 'Servico'; $script:ResultCode = $ExitServiceFailed
        $serviceState = Get-OCSServiceState
        $existing = Get-ExistingOCSConfiguration
        $script:ConfigurationReady = [bool](Test-OCSEffectiveConfiguration $existing $client).Ready
        Show-InstallationSummary $client $agent $serviceState $existing
        $final = if ($script:RebootRequired) { $ExitRebootRequired } else { $ExitSuccess }
        Write-InstallerLog "Resultado final=$final Instalacao=$($script:SetupPerformed) ConfiguracaoPronta=$($script:ConfigurationReady) MutationRequired=$($script:MutationRequired) InventoryRequested=$($script:InventoryRequested) InventoryAlreadyRunning=$($script:InventoryAlreadyRunning) InventoryStarted=$($script:InventoryStarted) AgentExecution=$($script:InventoryAgentExecution) ServerContact=$($script:InventoryServerContact) InventorySent=$($script:InventorySent) Servico=$($serviceState.State)"
        return $final
    } catch {
        if (Test-OCSRebootRequiredError $_) {
            $script:RebootRequired = $true
            Write-InstallerLog ("Operacao interrompida com seguranca por alteracao pendente no servico. Nada foi reinstalado ou removido. " + $script:RebootTechnicalDetails) 'ERRO'
            Show-OCSRebootRequiredNotice $client $(if ($agent) { $agent.Version }) $(if ($existing) { $existing.Tag })
            $script:ResultCode = $ExitRebootRequired
            return $ExitRebootRequired
        }
        if (Test-OCSAgentBusyError $_) {
            Write-InstallerLog ("Operacao interrompida com seguranca porque o agente esta ocupado. Nada foi instalado, reparado ou removido. Nenhuma alteracao pendente do Windows. ExitCode=42 Reason=" + $script:AgentBusyDetails) 'ERRO'
            Show-OCSAgentBusyNotice $client $(if ($agent) { $agent.Version }) $(if ($existing) { $existing.Tag }) ([bool]$authorizedConfigChange)
            $script:ResultCode = $ExitAgentBusy
            return $ExitAgentBusy
        }
        # Mensagens de erros externos podem conter URLs/segredos: registrar somente erros controlados.
        $detail = 'Falha operacional. Consulte a etapa, permissoes e diagnostico no README.'
        if ($_.Exception -is [Management.Automation.RuntimeException] -and $_.CategoryInfo.Category -eq 'OperationStopped') { $detail = $_.Exception.Message }
        if ($script:SetupPerformed) {
            Write-Friendly ''
            Write-Friendly 'O AGENTE FOI INSTALADO, MAS A FINALIZACAO PRECISA DE ATENCAO' 'Yellow'
            if ($script:Stage -eq 'Inventario') {
                Write-Friendly 'Nao conseguimos concluir o envio do inventario. Isso nao significa que a instalacao falhou.'
                Write-Friendly "Log do agente: $(Join-Path $AgentDataDirectory 'OCSInventory.log')"
            }
        } else {
            Write-Friendly ''
            Write-Friendly 'NAO FOI POSSIVEL CONCLUIR ESTA ETAPA' 'Yellow'
            Write-Friendly 'Nenhuma instalação foi realizada nesta execução.'
        }
        Write-Friendly $detail
        Write-Friendly "Etapa: $script:Stage | Codigo para suporte: $script:ResultCode"
        try { Write-InstallerLog "Resultado final=$script:ResultCode Etapa=$script:Stage SetupExecutado=$($script:SetupPerformed) Detalhes=$detail" 'ERRO' }
        catch { Write-Friendly 'Nao foi possivel gravar o log.' }
        return $script:ResultCode
    } finally {
        if ($script:LogPath) { Write-Friendly ''; Write-Friendly "Log: $script:LogPath" }
        if (-not $NoPause -and -not $DryRun -and -not $elevatedChild) { [void](Read-Host 'Pressione ENTER para sair') }
    }
}

# Dot-source permite testes das funcoes sem executar o instalador.
if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-InstallerMain) }

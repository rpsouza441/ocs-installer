#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Install-OCS.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$ServiceSettleWaitSeconds = 0
$PostSetupSettleWaitSeconds = 0
$testRoot = Join-Path $env:TEMP ('OCS tests spaces ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $configPath = Join-Path $testRoot 'clients test.json'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\clients.example.json') -Destination $configPath
    $clients = @(Read-ClientConfiguration $configPath)
    Assert ($clients.Count -eq 2) 'JSON e caminho com espacos'
    Assert (@($clients | Where-Object server -ne 'https://ocs.example.com/ocsinventory').Count -eq 0) 'Todos os clientes herdam servidor global'
    Assert ($clients[0].tag -ne $clients[1].tag) 'Clientes mantem TAGs distintas'
    Assert ((Select-Client $clients 2).tag -eq 'CLIENTE-02') 'ClientIndex 2 seleciona o segundo cliente'
    Assert-Throws { Select-Client $clients 999 } 'ClientIndex inexistente aborta'
    Assert-Throws { Read-ClientConfiguration (Join-Path $testRoot 'ausente.json') } 'JSON inexistente'
    $bad = Join-Path $testRoot 'bad.json'
    Set-Content -LiteralPath $bad -Value '{broken' -Encoding UTF8
    Assert-Throws { Read-ClientConfiguration $bad } 'JSON invalido'
    '{"clients":[{"name":"A","tag":"A"}]}' | Set-Content -LiteralPath $bad
    Assert-Throws { Read-ClientConfiguration $bad } 'Servidor global obrigatorio'
    '{"server":"http://ocs.example/ocsinventory","clients":[{"name":"A","tag":"A"}]}' | Set-Content -LiteralPath $bad
    Assert-Throws { Read-ClientConfiguration $bad } 'Servidor global exige HTTPS'
    '{"server":"https://ocs.example/ocsinventory","clients":[{"name":"A","tag":"A","server":"https://outro.example/ocsinventory"}]}' | Set-Content -LiteralPath $bad
    Assert-Throws { Read-ClientConfiguration $bad } 'Servidor diferente por cliente bloqueado'
    function Read-Host { param($Prompt); return $script:Answers.Dequeue() }
    $script:Answers = [Collections.Generic.Queue[string]]::new()
    foreach ($answer in @('abc', '-1', '999', '2')) { $script:Answers.Enqueue($answer) }
    Assert ((Select-Client $clients $null).tag -eq 'CLIENTE-02') 'Menu recupera entradas invalidas'
    $script:Answers.Enqueue('0')
    Assert ($null -eq (Select-Client $clients $null)) 'Opcao zero cancela'
    $script:Answers.Enqueue('N')
    Assert (-not (Confirm-ClientSelection $clients[0])) 'Confirmacao negativa'
    $script:Answers.Enqueue('S')
    Assert (Confirm-ClientSelection $clients[0]) 'Confirmacao positiva'
    Assert ((ConvertTo-NativeArgument 'C:\path with spaces\') -eq '"C:\path with spaces\\"') 'Quoting de barras finais'
    Assert-Throws { ConvertTo-NativeArgument 'bad"arg' } 'Rejeita aspas embutidas'
    $clients[0].tag = 'CLIENTE COM ESPACOS'
    $arguments = Get-OCSArguments $clients[0] Setup
    Assert ($arguments -like '*/TAG="CLIENTE COM ESPACOS"*') 'TAG com espacos'
    Assert ($arguments -like '*/SSL=1*' -and $arguments -notlike '*/NOW*') 'TLS e inventario separado'
    Assert ((Get-OCSArguments $clients[0] Inventory) -like '/FORCE *') 'Inventario forcado'
    foreach ($property in @('password', 'user', 'additionalArguments', 'proxy')) {
        $obj = @{server='https://ocs.example/ocsinventory'; clients = @(@{name='A';tag='A'; $property='TOP_SECRET_TEST'})}
        $obj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $bad -Encoding UTF8
        $message = ''
        try { Read-ClientConfiguration $bad | Out-Null } catch { $message = $_.Exception.Message }
        Assert ($message -and $message -notmatch 'TOP_SECRET_TEST') "Campo $property rejeitado sem segredo"
    }
    '{"server":"https://ocs.example/ocsinventory","clients":[{"name":"A","tag":"A","ssl":0}]}' | Set-Content -LiteralPath $bad
    Assert-Throws { Read-ClientConfiguration $bad } 'SSL inseguro bloqueado'
    '{"server":"https://user:secret@ocs.example/ocsinventory","clients":[{"name":"A","tag":"A"}]}' | Set-Content -LiteralPath $bad
    Assert-Throws { Read-ClientConfiguration $bad } 'Credenciais na URL bloqueadas'
    '[HTTP]', 'Server=https://old.example/ocsinventory', 'SSL=0', 'CaBundle=C:\ca.pem', 'Pwd=TOP_SECRET_TEST' | Set-Content -LiteralPath (Join-Path $testRoot 'ocsinventory.ini')
    '<REQUEST><ACCOUNTINFO><KEYNAME>TAG</KEYNAME><KEYVALUE>OLD</KEYVALUE></ACCOUNTINFO></REQUEST>' | Set-Content -LiteralPath (Join-Path $testRoot 'admininfo.conf')
    $existing = Get-ExistingOCSConfiguration $testRoot
    Assert ($existing.Server -eq 'https://old.example/ocsinventory' -and $existing.Tag -eq 'OLD') 'Configuracao existente XML/INI'
    Assert-Equal '0' $existing.Ssl 'SSL efetivo e lido do INI'
    Assert-Equal 'C:\ca.pem' $existing.CaBundle 'CaBundle efetivo e lido do INI'
    Assert (-not (Test-OCSEffectiveConfiguration $existing ([pscustomobject]@{server='https://old.example/ocsinventory';tag='OLD'})).Ready) 'SSL=0 impede configuracao pronta'
    Assert $existing.HasCredentials 'Detecta credenciais antigas sem expor valores'
    Set-Content -LiteralPath (Join-Path $testRoot 'admininfo.conf') -Value 'opaque data'
    Assert ($null -eq (Get-ExistingOCSConfiguration $testRoot).Tag) 'TAG opaca fica desconhecida'
    Assert ((Format-ExistingValue 'https://u:secret@host/path?token=secret' -Url) -notmatch 'secret') 'URL antiga redigida'
    $InstallerFileName = 'missing-test-file.exe'; $InstallerUrl = ''
    Assert-Throws { Get-OCSInstaller -Preview } 'Instalador ausente'
    $InstallerUrl = 'http://example.test/setup.exe'
    Assert-Throws { Get-OCSInstaller -Preview } 'Download HTTP bloqueado'
    $InstallerUrl = 'https://example.test/setup.exe'
    Assert ((Get-OCSInstaller -Preview) -eq '(download pendente)') 'Preview nao baixa'
    # Integracao simulada: todas as fronteiras mutaveis sao substituidas por sentinelas.
    function Test-Administrator { return $false }
    function Restart-AsAdministrator { throw 'DryRun tentou elevar' }
    function Install-OCSAgent { throw 'DryRun tentou instalar' }
    function Set-OCSConfiguration { throw 'DryRun tentou configurar' }
    function Start-OCSService { throw 'DryRun tentou iniciar servico' }
    function Set-OCSServiceState { throw 'DryRun tentou controlar servico' }
    function Invoke-OCSInventory { throw 'DryRun tentou inventariar' }
    function Invoke-ServiceControllerTool { throw 'DryRun tentou executar sc.exe' }
    function Get-InstalledOCSAgent { return [pscustomobject]@{Found=$script:SimulatedInstalled;Version='2.10.0.0';Exe='C:\fake agent\OCSInventory.exe'} }
    function Get-ExistingOCSConfiguration { return [pscustomobject]@{Server='https://old.example/ocsinventory';Tag='OLD';Ssl='1';CaBundle=$null;HasCredentials=$false} }
    function Get-OCSServiceFacts { return $script:SimulatedServiceFacts }
    $AgentDataDirectory = Join-Path $testRoot 'agent-data'
    $DryRun = $true; $NoPause = $true; $RunInventory = $false; $ClientIndex = 2; $ClientTag = $null; $script:ClientIndexSpecified = $true; $ClientsPath = $configPath
    $script:SimulatedServiceFacts = New-FakeServiceFacts
    $script:SimulatedInstalled = $false
    Assert ((Invoke-InstallerMain) -eq 0) 'DryRun sem agente e sem mutacoes'
    Assert (-not (Test-Path -LiteralPath (Join-Path $AgentDataDirectory 'ocs-cacert.pem'))) 'DryRun nao cria ocs-cacert.pem'
    Assert (-not (Test-Path -LiteralPath (Join-Path $AgentDataDirectory 'legacy-cacert.pem'))) 'DryRun nao cria legacy-cacert.pem'
    Assert ((Get-Content -LiteralPath $script:LogPath -Raw) -match 'ocs-cacert\.pem') 'DryRun planeja /CA com ocs-cacert.pem'
    Assert ((Get-Content -LiteralPath $script:LogPath -Raw) -notmatch 'legacy-cacert\.pem') 'DryRun nao referencia legacy-cacert.pem'
    $script:SimulatedInstalled = $true
    Assert ((Invoke-InstallerMain) -eq 0) 'DryRun com agente de outro cliente'
    Assert ((Get-Content -LiteralPath $script:LogPath -Raw) -match 'EstadoVersao=Older') 'DryRun classifica a versao sem alterar nada'
    Assert ((Get-Content -LiteralPath $script:LogPath -Raw) -match 'exigiria confirmacao') 'DryRun registra que exigiria confirmacao antes de alterar'
    Assert ((Get-Content -LiteralPath $script:LogPath -Raw) -notmatch 'TOP_SECRET_TEST|Pwd=') 'Log sem segredo da configuracao'
    # DryRun tambem diagnostica exclusao pendente do servico, sem tentar corrigi-la.
    $script:SimulatedServiceFacts = New-MarkedForDeletionFacts
    Assert ((Invoke-InstallerMain) -eq 3010) 'DryRun detecta servico marcado para exclusao e retorna 3010'
    Assert ((Get-Content -LiteralPath $script:LogPath -Raw) -match 'Nenhuma instalacao, reparo ou atualizacao executada') 'DryRun confirma no log que nada foi executado'
    $script:SimulatedServiceFacts = New-FakeServiceFacts
    $InstallerPackages.x64 = @{FileName='missing-test-file.exe';Url='';SHA256=''}
    Assert ((Invoke-InstallerMain) -eq 20) 'DryRun sinaliza pacote ausente'
    $ClientIndex = 999
    Assert ((Invoke-InstallerMain) -eq 10) 'Codigo de erro ClientIndex'
    # Processo real do launcher, em pasta com espacos, sem pacote e sem mutacoes OCS.
    foreach ($file in @('Install-OCS.ps1', 'Install-OCS.cmd')) {
        Copy-Item -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') $file) -Destination (Join-Path $testRoot $file)
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\clients.example.json') -Destination (Join-Path $testRoot 'clients.json')
    $null = & (Join-Path $testRoot 'Install-OCS.cmd') -ClientId 999 -DryRun -NoPause 2>&1
    Assert ($LASTEXITCODE -eq 10) 'CMD em pasta com espacos propaga exit code'
    $launcherOutput = & (Join-Path $testRoot 'Install-OCS.cmd') -ClientId 2 -DryRun -NoPause 2>&1
    Assert (($launcherOutput -join "`n") -match 'ClientName=Cliente Exemplo 2' -or ($launcherOutput -join "`n") -match 'Cliente=Cliente Exemplo 2' -or ($launcherOutput -join "`n") -match 'ClientTag=CLIENTE-02') 'CMD carrega JSON ao lado do script'
    # O DryRun real le o estado deste computador: 20 (pacote ausente na copia) ou
    # 3010 quando o Windows tem uma alteracao de servico pendente.
    Assert ($LASTEXITCODE -in @(20, 3010)) 'DryRun real retorna um codigo documentado'
    Write-TestTotal 'Test-Installer'
} finally {
    # Exclusao restrita ao diretorio temporario criado neste teste.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

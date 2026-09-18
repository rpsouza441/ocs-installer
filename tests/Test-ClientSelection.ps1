#requires -Version 5.1
# Selecao de clientes sem ID persistente, validacao de URL e Authenticode.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Install-OCS.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$testRoot = Join-Path $env:TEMP ('OCS-clients-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Write-ClientJson {
    param([string]$Path, [object[]]$Clients, [string]$Server = 'https://ocs.example.com/ocsinventory')
    $document = @{ server = $Server; clients = @($Clients) }
    $document | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Get-MenuLines {
    param($Clients)
    $output = & { Show-ClientMenu $Clients } *>&1 | Out-String
    return $output
}

try {
    $json = Join-Path $testRoot 'clients.json'

    # TESTE 1: ordem A B C D
    Write-ClientJson $json @(
        @{ name = 'A'; tag = 'A' }
        @{ name = 'B'; tag = 'B' }
        @{ name = 'C'; tag = 'C' }
        @{ name = 'D'; tag = 'D' }
    )
    $clients = @(Read-ClientConfiguration $json)
    Assert-Equal 4 $clients.Count 'TESTE 1: quatro clientes'
    Assert-Equal 'A' $clients[0].name 'TESTE 1: primeiro e A'
    Assert-Equal 'B' $clients[1].name 'TESTE 1: segundo e B'
    Assert-Equal 'C' $clients[2].name 'TESTE 1: terceiro e C'
    Assert-Equal 'D' $clients[3].name 'TESTE 1: quarto e D'
    Assert ($null -eq (Get-OptionalValue $clients[0] 'id')) 'TESTE 1: nenhum id persistente no objeto'
    $menu = Get-MenuLines $clients
    Assert ($menu -match '\[1\] A' -and $menu -match '\[2\] B' -and $menu -match '\[3\] C' -and $menu -match '\[4\] D') 'TESTE 1: menu 1 A 2 B 3 C 4 D'
    Assert ($menu -notmatch '\[5\]') 'TESTE 1: sem quinto item'

    # TESTE 2: remover C
    Write-ClientJson $json @(
        @{ name = 'A'; tag = 'A' }
        @{ name = 'B'; tag = 'B' }
        @{ name = 'D'; tag = 'D' }
    )
    $clients = @(Read-ClientConfiguration $json)
    Assert-Equal 3 $clients.Count 'TESTE 2: tres clientes apos remover C'
    Assert-Equal 'D' $clients[2].name 'TESTE 2: terceiro passou a ser D sem renumerar JSON'
    $menu = Get-MenuLines $clients
    Assert ($menu -match '\[1\] A' -and $menu -match '\[2\] B' -and $menu -match '\[3\] D') 'TESTE 2: menu 1 A 2 B 3 D'
    Assert ($menu -notmatch '\[4\]' -and $menu -notmatch '\[3\] C') 'TESTE 2: C sumiu e nao sobrou 4'

    # TESTE 3: inserir X entre A e B
    Write-ClientJson $json @(
        @{ name = 'A'; tag = 'A' }
        @{ name = 'X'; tag = 'X' }
        @{ name = 'B'; tag = 'B' }
        @{ name = 'D'; tag = 'D' }
    )
    $clients = @(Read-ClientConfiguration $json)
    Assert-Equal 'X' $clients[1].name 'TESTE 3: X na segunda posicao'
    $menu = Get-MenuLines $clients
    Assert ($menu -match '\[1\] A' -and $menu -match '\[2\] X' -and $menu -match '\[3\] B' -and $menu -match '\[4\] D') 'TESTE 3: menu 1 A 2 X 3 B 4 D'

    # TESTE 4: ClientIndex 3 seleciona o terceiro item atual
    Assert-Equal 'B' (Select-Client $clients 3).name 'TESTE 4: ClientIndex 3 seleciona B'
    Assert-Equal 'B' (Select-Client $clients 3).tag 'TESTE 4: TAG do terceiro item e B'

    # TESTE 5: ClientTag independente da posicao
    Assert-Equal 'B' (Select-Client -Clients $clients -RequestedTag 'B').name 'TESTE 5: ClientTag B encontra o cliente'
    Assert-Equal 'B' (Select-Client -Clients $clients -RequestedTag 'b').name 'TESTE 5: ClientTag e case-insensitive'

    # TESTE 6: TAG duplicada aborta
    Write-ClientJson $json @(
        @{ name = 'Cliente Dup 1'; tag = 'DUP-TAG' }
        @{ name = 'Cliente Dup 2'; tag = 'dup-tag' }
    )
    $dupMessage = ''
    try { Read-ClientConfiguration $json | Out-Null } catch { $dupMessage = $_.Exception.Message }
    Assert ($dupMessage -match "TAG duplicada 'dup-tag'|TAG duplicada 'DUP-TAG'") 'TESTE 6: aborta com TAG duplicada'
    Assert ($dupMessage -match 'Cliente Dup 1' -and $dupMessage -match 'Cliente Dup 2') 'TESTE 6: lista os clientes em conflito'

    # Restaura o JSON de 4 itens para os testes de indice
    Write-ClientJson $json @(
        @{ name = 'A'; tag = 'A' }
        @{ name = 'X'; tag = 'X' }
        @{ name = 'B'; tag = 'B' }
        @{ name = 'D'; tag = 'D' }
    )
    $clients = @(Read-ClientConfiguration $json)

    # TESTE 7: indice maior que Count
    $over = ''
    try { Select-Client $clients 99 | Out-Null } catch { $over = $_.Exception.Message }
    Assert ($over -match 'fora do intervalo' -and $over -match '1 e 4') 'TESTE 7: ClientIndex maior que Count aborta com intervalo'

    # TESTE 8: ClientIndex 0 por parametro = sair
    Assert ($null -eq (Select-Client $clients 0)) 'TESTE 8: ClientIndex 0 equivale a sair'

    # TESTE 9: selecao interativa 0
    function Read-Host { param($Prompt); $script:Prompts += $Prompt; return $script:Answers.Dequeue() }
    $script:Prompts = @(); $script:Answers = [Collections.Generic.Queue[string]]::new()
    $script:Answers.Enqueue('0')
    Assert ($null -eq (Select-Client $clients $null)) 'TESTE 9: opcao interativa 0 sai'

    # TESTE 10: entradas invalidas nao quebram
    $script:Prompts = @()
    $script:Answers = [Collections.Generic.Queue[string]]::new()
    foreach ($answer in @('abc', '-1', '999', '1.5', '2')) { $script:Answers.Enqueue($answer) }
    $chosen = Select-Client $clients $null
    Assert-Equal 'X' $chosen.name 'TESTE 10: depois de entradas invalidas, 2 seleciona X'
    Assert-Equal 5 $script:Prompts.Count 'TESTE 10: quatro invalidas e uma valida, sem excecao'

    # TESTE 11: URL /ocsreports rejeitada
    $badUrl = Join-Path $testRoot 'bad-url.json'
    '{"server":"https://ocs.example.com/ocsreports/","clients":[{"name":"A","tag":"A"}]}' | Set-Content -LiteralPath $badUrl -Encoding UTF8
    $urlMessage = ''
    try { Read-ClientConfiguration $badUrl | Out-Null } catch { $urlMessage = $_.Exception.Message }
    Assert ($urlMessage -match '/ocsinventory' -and $urlMessage -match '/ocsreports') 'TESTE 11: /ocsreports e rejeitada com mensagem explicita'

    '{"server":"https://ocs.example.com/ocsreports/?function=visu_computers","clients":[{"name":"A","tag":"A"}]}' | Set-Content -LiteralPath $badUrl -Encoding UTF8
    Assert-Throws { Read-ClientConfiguration $badUrl } 'TESTE 11: query string de ocsreports tambem e rejeitada'

    '{"server":"https://ocs.example.com/","clients":[{"name":"A","tag":"A"}]}' | Set-Content -LiteralPath $badUrl -Encoding UTF8
    Assert-Throws { Read-ClientConfiguration $badUrl } 'TESTE 11: raiz do site nao e o endpoint do agente'

    # TESTE 12: URL /ocsinventory aceita, inclusive barra final
    '{"server":"https://ocs.example.com/ocsinventory/","clients":[{"name":"A","tag":"A"}]}' | Set-Content -LiteralPath $badUrl -Encoding UTF8
    $normalized = @(Read-ClientConfiguration $badUrl)
    Assert-Equal 'https://ocs.example.com/ocsinventory' $normalized[0].server 'TESTE 12: barra final e normalizada'
    Assert-Equal 'https://ocs.example.com/ocsinventory' (ConvertTo-OCSAgentServerUrl 'https://ocs.example.com/ocsinventory') 'TESTE 12: URL canonica aceita'

    # TESTE 16: equivalencia de SERVER (hostname case + barra final)
    $canonical = 'https://ocs.example.com/ocsinventory'
    Assert (Test-OCSServerUrlEquals $canonical 'https://ocs.example.com/ocsinventory/') 'TESTE 16: barra final e equivalente'
    Assert (Test-OCSServerUrlEquals $canonical 'https://OCS.EXAMPLE.COM/ocsinventory') 'TESTE 16: hostname em maiusculas e equivalente'
    Assert (Test-OCSServerUrlEquals $canonical 'https://OCS.EXAMPLE.COM/ocsinventory/') 'TESTE 16: case + barra final juntos sao equivalentes'
    Assert-Equal $canonical (ConvertTo-OCSAgentServerUrl 'https://OCS.EXAMPLE.COM/ocsinventory/') 'TESTE 16: forma canonica lower-case sem barra'
    Assert-Equal $canonical (ConvertTo-OCSComparableServerUrl 'https://ocs.example.com:443/ocsinventory') 'TESTE 16: porta 443 default e omitida'
    Assert (-not (Test-OCSServerUrlEquals $canonical 'http://ocs.example.com/ocsinventory')) 'TESTE 16: HTTP nao equivale a HTTPS'
    Assert (-not (Test-OCSServerUrlEquals $canonical 'https://ocs.example.com/ocsreports')) 'TESTE 16: /ocsreports nao equivale a /ocsinventory'
    Assert (-not (Test-OCSServerUrlEquals $canonical 'https://other.example/ocsinventory')) 'TESTE 16: host diferente nao equivale'
    Assert (-not (Test-OCSServerUrlEquals $canonical 'https://ocs.example.com:8443/ocsinventory')) 'TESTE 16: porta nao padrao nao equivale'
    $equivCfg = Test-OCSEffectiveConfiguration ([pscustomobject]@{
        Server = 'https://OCS.EXAMPLE.COM/ocsinventory/'
        Tag = 'CLIENT-A'
        Ssl = '1'
    }) ([pscustomobject]@{ server = $canonical; tag = 'CLIENT-A' })
    Assert $equivCfg.ServerMatches 'TESTE 16: configuracao efetiva considera SERVER equivalente'
    Assert $equivCfg.IdentityMatches 'TESTE 16: SERVER+TAG+SSL equivalentes = identidade correta'
    Assert $equivCfg.CaMigrationRequired 'TESTE 16: sem CaBundle esperado a identidade nao basta'
    Assert (-not $equivCfg.Ready) 'TESTE 16: Ready exige tambem o bundle CA'

    # TESTE 17: clients.json com um unico cliente (objeto, nao array) nos dois hosts
    $singlePath = Join-Path $testRoot 'single-client.json'
    Write-Utf8BomFile $singlePath @'
{
  "server": "https://ocs.example.com/ocsinventory",
  "clients": [
    {
      "name": "Cliente A",
      "tag": "CLIENT-A"
    }
  ]
}
'@
    $singleRaw = Read-ClientConfiguration $singlePath
    $single = @($singleRaw)
    Assert-Equal 1 $single.Count 'TESTE 17: um unico cliente permanece Count=1'
    Assert-Equal 'Cliente A' $single[0].name 'TESTE 17: nome do unico cliente'
    Assert-Equal 'CLIENT-A' $single[0].tag 'TESTE 17: TAG do unico cliente'
    Assert-Equal 'CLIENT-A' (Select-Client $singleRaw 1).tag 'TESTE 17: Select-Client trata objeto unico como colecao'
    Assert-Equal 'Cliente A' (Select-Client -Clients $singleRaw -RequestedTag 'CLIENT-A').name 'TESTE 17: ClientTag com retorno nao envelopado'
    $singleMenu = Get-MenuLines $singleRaw
    Assert ($singleMenu -match '\[1\] Cliente A') 'TESTE 17: menu [1] Cliente A'
    Assert ($singleMenu -match '\[0\] Sair') 'TESTE 17: menu [0] Sair'
    Assert ($singleMenu -notmatch '\[2\]') 'TESTE 17: sem segundo item'
    Assert-Equal 'CLIENT-A' (Select-Client $single 1).tag 'TESTE 17: ClientIndex 1 seleciona o unico cliente'
    Assert-Equal 'Cliente A' (Select-Client -Clients $single -RequestedTag 'CLIENT-A').name 'TESTE 17: ClientTag seleciona o unico cliente'

    # TESTE 18: UTF-8 com nomes reais fora de ASCII
    $saoJose = 'S{0}o Jos{1}' -f [char]0x00E3, [char]0x00E9
    $coordenacao = 'Coordena{0}{1}o' -f [char]0x00E7, [char]0x00E3
    $industria = 'Ind{0}stria' -f [char]0x00FA
    $clinicaParana = 'Cl{0}nica Paran{1}' -f [char]0x00ED, [char]0x00E1
    $unicodePath = Join-Path $testRoot 'unicode-clients.json'
    $unicodeJson = @"
{
  "server": "https://ocs.example.com/ocsinventory",
  "clients": [
    { "name": "$saoJose", "tag": "$saoJose" },
    { "name": "$coordenacao", "tag": "COORDENACAO" },
    { "name": "$industria", "tag": "$industria" },
    { "name": "$clinicaParana", "tag": "CLINICA-PR" }
  ]
}
"@
    Write-Utf8BomFile $unicodePath $unicodeJson
    $unicodeClients = @(Read-ClientConfiguration $unicodePath)
    Assert-Equal 4 $unicodeClients.Count 'TESTE 18: quatro clientes unicode'
    Assert-Equal $saoJose $unicodeClients[0].name 'TESTE 18: Sao Jose lido sem perda'
    Assert-Equal $saoJose $unicodeClients[0].tag 'TESTE 18: TAG acentuada preservada'
    Assert-Equal $coordenacao $unicodeClients[1].name 'TESTE 18: Coordenacao lida sem perda'
    Assert-Equal $industria $unicodeClients[2].name 'TESTE 18: Industria lida sem perda'
    Assert-Equal $clinicaParana $unicodeClients[3].name 'TESTE 18: Clinica Parana lida sem perda'
    Assert-Equal $saoJose (Select-Client -Clients $unicodeClients -RequestedTag $saoJose).name 'TESTE 18: ClientTag acentuada encontra o cliente'
    $unicodeMenu = Get-MenuLines $unicodeClients
    Assert ($unicodeMenu -match '\[1\]') 'TESTE 18: menu lista o primeiro cliente'
    Assert ($unicodeMenu -match '\[4\]') 'TESTE 18: menu lista o quarto cliente'
    Assert ($unicodeMenu.Contains((Format-ConsoleText $saoJose))) 'TESTE 18: menu exibe Sao Jose (ou forma do console)'
    Assert ($unicodeMenu.Contains((Format-ConsoleText $clinicaParana))) 'TESTE 18: menu exibe Clinica Parana (ou forma do console)'
    $unicodeLog = Join-Path $testRoot 'unicode.log'
    $script:LogPath = $unicodeLog
    Write-InstallerLog "ClientName=$saoJose ClientTag=$saoJose"
    $logText = Read-Utf8File $unicodeLog
    Assert ($logText.Contains($saoJose)) 'TESTE 18: log UTF-8 preserva acentos; nao remove nem corrompe'
    $script:LogPath = $null

    # TESTE 15: assinatura Authenticode invalida nao executa
    $dummy = Join-Path $testRoot 'fake-setup.exe'
    [IO.File]::WriteAllBytes($dummy, [byte[]](0x4D, 0x5A, 0x00, 0x00))
    function Get-OCSInstallerSignature {
        param([string]$Path)
        return [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }
    }
    $sigMessage = ''
    try { Assert-OCSInstallerTrust $dummy } catch { $sigMessage = $_.Exception.Message }
    Assert ($sigMessage -match 'Authenticode invalida' -and $sigMessage -match 'NotSigned') 'TESTE 15: EXE sem assinatura valida e recusado'
    Assert-Throws { Assert-OCSInstallerTrust $dummy } 'TESTE 15: nao executa instalador com assinatura invalida'

    # SHA256 divergente tambem aborta
    $InstallerSHA256 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    $hashMessage = ''
    try { Assert-OCSInstallerTrust $dummy } catch { $hashMessage = $_.Exception.Message }
    Assert ($hashMessage -match 'SHA256') 'TESTE 15: SHA256 divergente aborta'
    $InstallerSHA256 = ''

    # SHA256 real e sempre calculado e registrado, mesmo sem hash esperado.
    $trustLog = Join-Path $testRoot 'trust.log'
    $script:LogPath = $trustLog
    function Get-OCSInstallerSignature {
        param([string]$Path)
        return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Example Publisher' } }
    }
    $InstallerPublisher = ''
    Assert-OCSInstallerTrust $dummy
    $trustText = Read-Utf8File $trustLog
    Assert ($trustText -match 'SHA256=[A-F0-9]{64}') 'TESTE 15: SHA256 real sempre registrado'
    Assert ($trustText -match 'SHA256 esperado nao configurado') 'TESTE 15: ausencia de hash esperado nao impede o registro'
    Assert ($trustText -notmatch 'Publisher conferido') 'TESTE 15: sem publisher configurado, nao exige CN fixo'

    $InstallerPublisher = 'FactorFX'
    $pubMessage = ''
    try { Assert-OCSInstallerTrust $dummy } catch { $pubMessage = $_.Exception.Message }
    Assert ($pubMessage -match 'Publisher Authenticode divergente' -and $pubMessage -match 'FactorFX') 'TESTE 15: publisher configurado divergente aborta'
    $InstallerPublisher = 'Example Publisher'
    Assert-OCSInstallerTrust $dummy
    $trustText = Read-Utf8File $trustLog
    Assert ($trustText -match 'Publisher conferido: Example Publisher') 'TESTE 15: publisher configurado correspondente e aceito'
    $InstallerPublisher = ''
    $script:LogPath = $null

    Write-TestTotal 'Test-ClientSelection'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

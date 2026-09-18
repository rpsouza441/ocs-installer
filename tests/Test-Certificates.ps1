#requires -Version 5.1
# Bundle CA e argumentos de SSL. Escreve apenas em um diretório temporário
# próprio: o diretório real do agente OCS não é tocado.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Install-OCS.ps1')
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$AgentDataDirectory = Join-Path $env:TEMP ('OCS-CA-test-' + [guid]::NewGuid().ToString('N'))
$client = [pscustomobject]@{server='https://ocs.example/ocsinventory';tag='TEST'}
try {
    Assert-Equal 'ocs-cacert.pem' $CaBundleFileName 'Nome do bundle nao e CA privada da organizacao'
    Assert ($CaBundleFileName -notmatch 'legacy-cacert') 'Nenhuma referencia funcional a legacy-cacert.pem'

    $path = Join-Path $AgentDataDirectory $CaBundleFileName
    $legacyPath = Join-Path $AgentDataDirectory 'legacy-cacert.pem'
    foreach ($mode in @('Setup','Inventory')) {
        $arguments = Get-OCSArguments $client $mode
        Assert ($arguments -like ('*/CA="*{0}"*' -f $path)) "CA aponta para ocs-cacert.pem em $mode"
        Assert ($arguments -like '*/SSL=1*') "SSL permanece habilitado em $mode"
        Assert ($arguments -notlike '*/SSL=0*') "SSL nunca e desabilitado em $mode"
        Assert ($arguments -notlike '*legacy-cacert.pem*') "Argumentos de $mode nao usam legacy-cacert.pem"
    }
    Assert (-not (Test-Path -LiteralPath $path)) 'Get-OCSArguments nao cria o bundle (mesmo contrato do DryRun)'
    Assert (-not (Test-Path -LiteralPath $legacyPath)) 'DryRun/argumentos nao recriam legacy-cacert.pem'

    Initialize-OCSCertificateBundle $client
    Assert (Test-Path -LiteralPath $path -PathType Leaf) 'Bundle criado como ocs-cacert.pem'
    Assert (-not (Test-Path -LiteralPath $legacyPath)) 'Initialize nao grava legacy-cacert.pem'
    $pem = Get-Content -LiteralPath $path -Raw
    $blocks = [regex]::Matches($pem, '(?s)-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----')
    Assert ($blocks.Count -gt 0) "Bundle CA gerado com $($blocks.Count) certificados"
    Assert ($pem -notmatch 'PRIVATE KEY') 'Bundle nao contem chave privada'
    $valid = $true
    foreach ($block in $blocks) {
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($block.Groups[1].Value))
        if (-not $certificate.Thumbprint) { $valid = $false }
        $certificate.Dispose()
    }
    Assert $valid 'Todos os certificados exportados sao validos'
    $custom = Join-Path $AgentDataDirectory 'custom.pem'
    Copy-Item -LiteralPath $path -Destination $custom
    $client | Add-Member -NotePropertyName caFile -NotePropertyValue $custom
    Initialize-OCSCertificateBundle $client
    Assert ((Get-FileHash $path).Hash -eq (Get-FileHash $custom).Hash) 'CA customizada do cliente e preservada'
    Assert ((Get-OCSArguments $client 'Setup') -like ('*/CA="*{0}"*' -f $path)) 'caFile customizado continua publicado como ocs-cacert.pem'

    $expected = Get-OCSExpectedCaBundlePath
    $legacy = Join-Path $AgentDataDirectory 'legacy-cacert.pem'
    Set-Content -LiteralPath $legacy -Value 'legado' -Encoding ASCII
    Initialize-OCSCertificateBundle $client
    Assert (Test-Path -LiteralPath $legacy -PathType Leaf) 'Arquivo legado legacy-cacert.pem nao e apagado na migracao'
    Assert (Test-Path -LiteralPath $expected -PathType Leaf) 'Bundle novo ocs-cacert.pem permanece apos Initialize'

    $identity = [pscustomobject]@{ server = $client.server; tag = $client.tag; Ssl = '1'; CaBundle = $legacy }
    $legacyCfg = Test-OCSEffectiveConfiguration $identity $client
    Assert $legacyCfg.IdentityMatches 'SERVER/TAG/SSL corretos com CA legada ainda sao a mesma identidade'
    Assert $legacyCfg.CaMigrationRequired 'legacy-cacert.pem exige migracao tecnica'
    Assert (-not $legacyCfg.Ready) 'legacy-cacert.pem nao deixa Pronta=True'

    $readyCfg = Test-OCSEffectiveConfiguration ([pscustomobject]@{ server = $client.server; tag = $client.tag; Ssl = '1'; CaBundle = $expected }) $client
    Assert $readyCfg.Ready 'CaBundle esperado + arquivo valido => Pronta=True'
    Assert (-not $readyCfg.CaMigrationRequired) 'Sem migracao quando o bundle ja confere'

    $caseCfg = Test-OCSEffectiveConfiguration ([pscustomobject]@{ server = $client.server; tag = $client.tag; Ssl = '1'; CaBundle = $expected.ToLowerInvariant() }) $client
    Assert $caseCfg.CaBundlePathMatches 'Case do filesystem Windows nao e divergencia'
    Assert $caseCfg.Ready 'Path equivalente em case permanece pronto'

    Assert (Test-OCSCaBundlePathEquals $expected $expected.ToUpperInvariant()) 'Comparacao de path ignora case'
    Assert (-not (Test-OCSCaBundlePathEquals $expected $legacy)) 'legacy-cacert.pem nao equivale a ocs-cacert.pem'

    $missingCfg = Test-OCSEffectiveConfiguration ([pscustomobject]@{ server = $client.server; tag = $client.tag; Ssl = '1'; CaBundle = $expected }) $client
    $savedPath = Join-Path $AgentDataDirectory 'ocs-cacert.bak'
    Move-Item -LiteralPath $expected -Destination $savedPath
    $missingCfg = Test-OCSEffectiveConfiguration ([pscustomobject]@{ server = $client.server; tag = $client.tag; Ssl = '1'; CaBundle = $expected }) $client
    Assert $missingCfg.CaBundlePathMatches 'INI pode apontar para o caminho certo'
    Assert (-not $missingCfg.CaBundleFileExists) 'Arquivo ausente e detectado'
    Assert (-not $missingCfg.Ready) 'Caminho correto sem arquivo nao esta pronto'
    Assert $missingCfg.CaMigrationRequired 'Arquivo ausente dispara migracao'
    Move-Item -LiteralPath $savedPath -Destination $expected

    $absentCfg = Test-OCSEffectiveConfiguration ([pscustomobject]@{ server = $client.server; tag = $client.tag; Ssl = '1'; CaBundle = '' }) $client
    Assert (-not $absentCfg.Ready) 'CaBundle ausente no INI => Pronta=False'
    Assert $absentCfg.CaMigrationRequired 'CaBundle ausente exige migracao'

    Write-TestTotal 'Test-Certificates'
} finally {
    $resolved = [IO.Path]::GetFullPath($AgentDataDirectory)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

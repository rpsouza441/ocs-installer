# Segurança

[Voltar ao README](../README.md) · [Recuperação do serviço](SERVICE-RECOVERY.md)

Este documento detalha a validação dos instaladores, o uso de certificados e as restrições para configuração e execução.

## Execução e políticas

O launcher CMD usa `ExecutionPolicy Bypass` apenas no processo. Não altera política permanente, GPO, Defender ou certificados. Políticas corporativas podem impedir execução; nesse caso use assinatura/aprovação corporativa. A execução real solicita UAC quando necessário; `-DryRun` não precisa de elevação.

## Pacote e versão alvo

**A versão alvo não está fixa no código.** Depois que o EXE selecionado (local ou baixado) está em disco, `Get-OCSVersionFromInstaller` lê `FileVersion` e, se essa não for interpretável, `ProductVersion`. `ConvertTo-OCSVersion` normaliza o valor (aceita `2.11.0.1` e `2, 11, 0, 1`). Essa versão lida do arquivo é a fonte de verdade para Current, Upgrade, Downgrade, resumo e log. `AgentVersionFallback` existe em um único ponto e **só** é usado enquanto o pacote ainda não está em disco. Se o EXE já existe e a versão não puder ser lida, o script **não inventa** versão a partir do fallback: registra o fato e aborta, para não decidir upgrade/downgrade por suposição. Se a versão real do EXE divergir da provisória usada antes do download, a execução é interrompida. Trocar os EXEs de `files\` muda a versão alvo sem editar código.

`InstallerPackages` centraliza `FileName`, `Url`, `SHA256` e `Publisher` separadamente para x86 e x64.

- Windows 64 bits seleciona `files\OCS-Windows-Agent-Setup-x64.exe`.
- Windows 32 bits seleciona `files\OCS-Windows-Agent-Setup-x86.exe`.
- Se o arquivo específico não existir, o fallback é `files\OCS-Windows-Agent-Setup.exe`, desde que a arquitetura PE do EXE coincida com o Windows.
- PowerShell 32 bits em Windows 64 bits também seleciona x64.
- ARM não é suportado. Não há fallback silencioso para outra arquitetura.

Antes de executar qualquer setup, `Assert-OCSInstallerTrust` exige `Get-AuthenticodeSignature` com `Status = Valid`. O SHA256 do EXE real é **sempre** calculado e gravado no log. Se `SHA256` estiver configurado no pacote, a igualdade é obrigatória (comparação hexadecimal sem distinguir maiúsculas); divergência aborta. `Publisher` é opcional e configurável; **não** há CN fixo no código. Se `Publisher` estiver preenchido, o Subject do assinante precisa contê-lo; se estiver vazio, Authenticode Valid + registro do hash bastam. Assinatura inválida aborta. DryRun também valida o pacote local quando ele existe. TLS do download permanece HTTPS sem redirecionamento.

Não é necessário escolher arquitetura no menu. O arquivo selecionado aparece no log. Se faltar, configure `Url` HTTPS direta na entrada correspondente de `InstallerPackages`; `SHA256` e `Publisher` são opcionais por arquitetura. Downloads continuam exigindo status 200, certificado válido e tamanho maior que zero, sem redirecionamentos. Não edite as variáveis derivadas `InstallerFileName`, `InstallerUrl`, `InstallerSHA256`, `InstallerPublisher` e `InstallerArchitecture`: são preenchidas pelo mapa.

## Certificados e campos sensíveis

`ocs-cacert.pem` não é o certificado do servidor OCS nem uma CA privada da organização. É um bundle de autoridades certificadoras confiáveis exportadas da Windows Certificate Store para uso do OCS Agent. Destino: `%ProgramData%\OCS Inventory NG\Agent\ocs-cacert.pem`. O setup recebe `/SSL=1 /CA="C:\ProgramData\OCS Inventory NG\Agent\ocs-cacert.pem"`.

O fluxo permanece: Windows Trusted Root Certificate Store → `Initialize-OCSCertificateBundle` → exportação somente de certificados públicos → bundle PEM → agente com `/SSL=1 /CA="..."`. Não há download remoto de CA nem mTLS neste instalador.

`ConfigurationReady` só fica verdadeira quando SERVER, TAG, SSL=1 **e** o `CaBundle` efetivo apontam para `ocs-cacert.pem` **e** esse arquivo existe com certificados X509 válidos. Um INI legado com outro nome de bundle (SERVER/TAG/SSL corretos) **não** é troca de cliente: é migração técnica local. O DryRun relata a divergência sem criar o arquivo novo, sem editar o INI e sem apagar o legado. A execução real gera `ocs-cacert.pem` pelo `Initialize-OCSCertificateBundle` já existente, reaplica a configuração pelo instalador oficial (`Set-OCSConfiguration`) e só então marca `Pronta=True`. O arquivo legado **não** é removido.

`caFile` é opcional, absoluto ou relativo ao JSON. O arquivo precisa existir e é copiado para o mesmo destino `ocs-cacert.pem`, para não depender da pasta temporária após instalação. Sem esse campo, o script gera o bundle a partir das autoridades raiz confiáveis de LocalMachine no Windows. Exporta somente certificados públicos, sem chaves privadas. Não importa certificados nem desabilita SSL. Certificados privados devem estar confiáveis no Windows ou ser fornecidos por `caFile`; a cadeia do servidor deve estar completa. `DryRun` não cria nem modifica o bundle.

`proxy`, `user`, `password` e `additionalArguments` estão reservados: valores não vazios são rejeitados explicitamente. Não são ignorados nem enviados ao processo. Isso evita injeção de parâmetros, desativação de SSL e exposição de segredos. Para implementar proxy, use objeto validado com tipo/host/porta e mapeamento explícito no adaptador, sem aceitar texto livre.

Para autenticação futura, obtenha `PSCredential` interativamente ou via cofre/DPAPI sob a identidade de execução. Nunca armazene senha no JSON, código, histórico ou log. Converter SecureString e passar `/PWD=` ainda expõe a senha na linha de comando; exige avaliação específica. A opção oficial `/save_conf` não é implementada aqui. Configurações existentes com campos de credenciais preenchidos são bloqueadas para evitar reaproveitar segredos de outro cliente.

## Adaptador e argumentos do setup

`Get-OCSArguments`, `Install-OCSAgent`, `Set-OCSConfiguration`, `Repair-OCSService` e `Invoke-OCSInventory` isolam o comportamento do produto. Setup: `/S /NOSPLASH /SERVER="..." /TAG="..." /SSL=1 /NOTAG /DEBUG=0`, sempre com `/CA="..."` apontando para o bundle preparado. Não usa `/NOW`, pois o inventário é executado separadamente.

Esses argumentos estão documentados pelo instalador oficial e cobertos pelos testes. `/SSL=0` não é usado e certificados não são ignorados em nenhuma circunstância.

Referências consultadas:

- [Documentação oficial de instalação Windows e opções](https://wiki.ocsinventory-ng.org/03.Basic-documentation/Setting-up-the-Windows-Agent-2.x-on-client-computers/)
- [OPTIONS.TXT oficial](https://github.com/OCSInventory-NG/WindowsAgent/blob/master/OPTIONS.TXT)

## Práticas proibidas neste script

Não são usados, em nenhum caminho de código: `Win32_Product`, `Invoke-Expression`, remoção forçada de chave de registro, `DeleteService` como "correção", `taskkill`, `Stop-Process -Force`, reinicialização automática, alteração permanente de `ExecutionPolicy`, `/SSL=0`, desativação de verificação de certificado, downgrade automático, troca silenciosa de TAG, remoção de `ocsinventory.dat` e laços de reinstalação ou reparo.

O script para o serviço apenas quando uma instalação ou atualização foi explicitamente autorizada, e o faz pelo SCM (`Stop-Service`, com fallback `sc.exe stop`), aguardando a saída do processo — nunca encerrando processos.

## Logs

Os logs incluem hostname, usuário, cliente, TAG e informações operacionais; revise-os antes de compartilhar. Credenciais e configurações brutas não são registradas. Consulte [logs e códigos de saída](TROUBLESHOOTING.md#logs-e-códigos-de-saída) para os caminhos e os campos registrados.

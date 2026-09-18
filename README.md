# Instalador interativo OCS Inventory para Windows

Implementação para Windows PowerShell 5.1, Windows 10/11 x86/x64, sem módulos externos. Distribua a pasta inteira; os caminhos são relativos ao script, não ao diretório atual. Pode executar de uma pasta temporária com espaços. Extraia o ZIP antes de executar e mantenha a pasta disponível até terminar.

**Objetivo:** instalar, atualizar ou conferir o OCS Inventory Agent no Windows de forma interativa e idempotente, a partir de um cadastro local de clientes. A versão alvo é lida do EXE oficial em `files\`. Copie `clients.example.json` para `clients.json` e preencha o servidor e as TAGs do seu ambiente. A instalação real ocorre após as confirmações do usuário e as validações do pacote.

O `Install-OCS.ps1` é salvo em UTF-8 com BOM: as telas amigáveis usam acentuação e o Windows PowerShell 5.1 precisa do BOM para interpretá-la. `clients.json` e os logs são lidos/escritos em UTF-8; nomes como São José, Coordenação, Indústria e Clínica Paraná são preservados nos dados. Quando a página de código do console não representa um caractere acentuado (por exemplo CP437 em Windows em inglês), `Format-ConsoleText` remove apenas o acento na **exibição**, em vez de imprimir `?`. Em CP850 (padrão pt-BR) a acentuação é exibida integralmente. Essa adaptação vale só para o console: JSON, TAG e log não são destituídos de acento.

## Arquivos

```text
OCS-Installer/
  Install-OCS.cmd            lançamento por duplo clique
  Install-OCS.ps1            funções, fluxo interativo e adaptador OCS
  clients.example.json       modelo versionado do cadastro
  clients.json               cadastro local (não versionado; criar a partir do exemplo)
  README.md
  files/                     instaladores oficiais x86 e x64, se fornecidos
  tests/                     suítes automatizadas
    Run-AllTests.ps1
    TestHelpers.ps1
    Test-VersionDecisions.ps1
    Test-ServiceStateMachine.ps1
    Test-ServiceTransitions.ps1
    Test-Certificates.ps1
    Test-ClientSelection.ps1
    Test-ExistingInstallationFlow.ps1
    Test-Installer.ps1
    Test-CmdLauncher.ps1
    fixtures/clients.json    cadastro sintético usado pelos testes
```

## Executar e testar

Na pasta da distribuição:

```powershell
.\Install-OCS.cmd
.\Install-OCS.ps1
.\Install-OCS.ps1 -DryRun
.\Install-OCS.ps1 -ClientTag "CLIENTE-01"
.\Install-OCS.ps1 -ClientTag "CLIENTE-01" -NoPause
.\Install-OCS.ps1 -ClientTag "CLIENTE-01" -RunInventory -NoPause
.\Install-OCS.ps1 -ClientIndex 2 -DryRun
.\Install-OCS.ps1 -ClientsPath 'C:\Pacotes OCS\clients.json' -DryRun
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\Run-AllTests.ps1'
```

O CMD usa `ExecutionPolicy Bypass` apenas no processo. Não altera política permanente, GPO, Defender ou certificados. Políticas corporativas podem impedir execução; nesse caso use assinatura/aprovação corporativa, sem enfraquecer a política. A execução real solicita UAC quando necessário e propaga o código do processo elevado. `DryRun` não precisa de elevação.

**Não existem IDs no `clients.json`.** Os números do menu são gerados na hora, na ordem do arquivo. `-ClientTag` é o identificador estável para automação. `-ClientIndex` é só a posição atual do menu nesta execução e **não** deve ser gravado em scripts permanentes. `-ClientId` continua aceito como alias de `-ClientIndex` para não quebrar chamadas antigas, mas o log registra `MenuIndex` e `ClientTag`, nunca `ClientId`.

Esses parâmetros dispensam o menu, mas **mantêm as confirmações de troca de cliente**; não são modo totalmente desassistido. `-ClientIndex 0` (explícito) equivale a escolher Sair no menu e retorna código 2. `-NoPause` remove apenas pausas e perguntas **opcionais** (inventário no final, “Pressione ENTER para sair”). Não confirma automaticamente ações opcionais: em máquina já pronta, `-NoPause` **não** reinstala, **não** reconfigura e **não** dispara inventário. `-RunInventory` solicita inventário de forma explícita, inclusive junto com `-NoPause`. Opção `0` ou resposta diferente de `S` cancela. Não existe confirmação automática para troca de cliente.

`DryRun` lê configuração, detecta o agente, classifica o serviço e a versão, mostra os comandos planejados e verifica o pacote local ou a configuração de download. Não baixa, instala, copia certificados, altera arquivos OCS, eleva, controla serviços ou executa inventário. Escreve apenas seu próprio log. Pacote ausente gera aviso e código 20. Um serviço com exclusão pendente faz o `DryRun` retornar 3010: é um diagnóstico real, não uma falha da simulação.

## Interface: cinco etapas

O console acompanha o que realmente está acontecendo. Uma etapa só é impressa quando começa de verdade.

```text
[1/5] Verificando o OCS Inventory...
      OCS Inventory 2.11.0.1 encontrado.

[2/5] Conferindo a configuração...
      Servidor correto.
      TAG correta.

[3/5] Conferindo o serviço...
      Serviço em execução com início automático.

[4/5] Conferindo versão...
      Nenhuma atualização necessária.

[5/5] Consultando o servidor OCS...
      Execucao do agente: Executado.
      Contato com servidor: Confirmado.
      Inventário enviado: Confirmado.
```

A etapa 5 aparece somente depois de o script confirmar que pode executar o inventário. Mensagens do tipo "Coletando e enviando inventário..." antes dessa confirmação foram removidas.

## Clientes

Não há campo `id`. O administrador só adiciona, remove ou reordena objetos. O PowerShell numera o menu em tempo de execução, na ordem exata do JSON.

```json
{
  "server": "https://ocs.example.com/ocsinventory",
  "clients": [
    { "name": "Cliente Exemplo 1", "tag": "CLIENTE-01" },
    { "name": "Cliente Exemplo 2", "tag": "CLIENTE-02" }
  ]
}
```

Copie esse arquivo para `clients.json` (ignorado pelo Git) e ajuste servidor e clientes. Adicionar um cliente: inclua um objeto em `clients`. Remover: apague o objeto. Alterar a ordem: mova os objetos. Nenhuma renumeração é necessária.

O menu correspondente a esse arquivo:

```text
[1] Cliente Exemplo 1
[2] Cliente Exemplo 2
[0] Sair
```

Se `Cliente Exemplo 2` for removido, a próxima execução mostra `[1] Cliente Exemplo 1`.

`server` é obrigatório na raiz e deve ser o endpoint do **agente**: HTTPS, sem credenciais, query ou fragmento, com caminho `/ocsinventory` (barra final opcional, normalizada). A comparação com o servidor efetivo do agente ignora maiúsculas/minúsculas do hostname e a barra final; **não** ignora protocolo, porta, host diferente nem path diferente. `https://ocs.exemplo/ocsinventory` equivale a `https://OCS.EXEMPLO/ocsinventory/` e **não** equivale a `http://ocs.exemplo/ocsinventory` nem a `https://ocs.exemplo/ocsreports`. A interface `/ocsreports` é rejeitada com a mensagem: `O servidor do agente OCS deve apontar para o endpoint /ocsinventory, e nao para /ocsreports.` `name` e `tag` são obrigatórios. TAGs são únicas (comparação sem distinguir maiúsculas); duplicatas abortam listando os nomes em conflito. Um `server` diferente dentro de um cliente é rejeitado. Aspas e controles são rejeitados; espaços e acentos são permitidos e **não** são removidos dos dados. `ssl` aceita apenas `1` ou `true`; `debug` aceita 0, 1 ou 2. Um `id` residual no JSON, se existir, é **ignorado**.

Automação:

```powershell
.\Install-OCS.ps1 -ClientTag "CLIENTE-01"
.\Install-OCS.ps1 -ClientIndex 2 -DryRun
```

`-ClientTag` procura exatamente uma TAG. Nenhuma TAG: `Cliente com TAG 'CLIENTE-01' nao encontrado.` TAG duplicada não chega a essa busca porque o JSON já foi recusado.

`ocs-cacert.pem` não é o certificado do servidor OCS nem uma CA privada da organização. É um bundle de autoridades certificadoras confiáveis exportadas da Windows Certificate Store para uso do OCS Agent. Destino: `%ProgramData%\OCS Inventory NG\Agent\ocs-cacert.pem`. O setup recebe `/SSL=1 /CA="C:\ProgramData\OCS Inventory NG\Agent\ocs-cacert.pem"`.

O fluxo permanece: Windows Trusted Root Certificate Store → `Initialize-OCSCertificateBundle` → exportação somente de certificados públicos → bundle PEM → agente com `/SSL=1 /CA="..."`. Não há download remoto de CA nem mTLS neste instalador.

`ConfigurationReady` só fica verdadeira quando SERVER, TAG, SSL=1 **e** o `CaBundle` efetivo apontam para `ocs-cacert.pem` **e** esse arquivo existe com certificados X509 válidos. Um INI legado com outro nome de bundle (SERVER/TAG/SSL corretos) **não** é troca de cliente: é migração técnica local. O DryRun relata a divergência sem criar o arquivo novo, sem editar o INI e sem apagar o legado. A execução real gera `ocs-cacert.pem` pelo `Initialize-OCSCertificateBundle` já existente, reaplica a configuração pelo instalador oficial (`Set-OCSConfiguration`) e só então marca `Pronta=True`. O arquivo legado **não** é removido.

`caFile` é opcional, absoluto ou relativo ao JSON. O arquivo precisa existir e é copiado para o mesmo destino `ocs-cacert.pem`, para não depender da pasta temporária após instalação. Sem esse campo, o script gera o bundle a partir das autoridades raiz confiáveis de LocalMachine no Windows. Exporta somente certificados públicos, sem chaves privadas. Não importa certificados nem desabilita SSL. Certificados privados devem estar confiáveis no Windows ou ser fornecidos por `caFile`; a cadeia do servidor deve estar completa. `DryRun` não cria nem modifica o bundle.

`proxy`, `user`, `password` e `additionalArguments` estão reservados: valores não vazios são rejeitados explicitamente. Não são ignorados nem enviados ao processo. Isso evita injeção de parâmetros, desativação de SSL e exposição de segredos. Para implementar proxy, use objeto validado com tipo/host/porta e mapeamento explícito no adaptador, sem aceitar texto livre.

Para autenticação futura, obtenha `PSCredential` interativamente ou via cofre/DPAPI sob a identidade de execução. Nunca armazene senha no JSON, código, histórico ou log. Converter SecureString e passar `/PWD=` ainda expõe a senha na linha de comando; exige avaliação específica. A opção oficial `/save_conf` não é implementada aqui. Configurações existentes com campos de credenciais preenchidos são bloqueadas para evitar reaproveitar segredos de outro cliente.

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

## Máquina de estados do serviço

Toda decisão sobre o serviço passa por um único ponto, em três funções:

| Função | Responsabilidade |
| --- | --- |
| `Get-OCSServiceFacts` | Lê o sistema, somente leitura: `Get-Service`, chave `HKLM\SYSTEM\CurrentControlSet\Services\OCS Inventory Service` (`Start`, `DeleteFlag`, `ImagePath`), existência do binário, PID de `OcsService` e indícios de reinicialização pendente. |
| `Resolve-OCSServiceState` | Função **pura**: classifica os fatos. Testável sem tocar no Windows. |
| `Get-OCSServiceState` | Combina as duas e devolve o objeto usado por todo o fluxo. |

O objeto retornado contém `State`, `Exists`, `Status`, `StartType`, `MarkedForDeletion`, `ProcessId`, `RebootRequired`, `Healthy`, `NeedsRepair`, `SafeToModify`, `PendingRebootReasons` e `TechnicalDetails`.

| Estado | Condição | Consequência |
| --- | --- | --- |
| `ServiceHealthy` | Running + Automatic (ou automático com atraso) | Nada a fazer |
| `RunningDisabled` | Running, mas início não é automático | Corrigir apenas o início; não volta no próximo boot |
| `StoppedAutomatic` | Stopped + Automatic | Iniciar o serviço |
| `StoppedDisabled` | Stopped + Disabled/Manual | Corrigir início e iniciar |
| `ServiceMissing` | Sem serviço e sem chave no registro | Instalação nova. Se o agente **já estiver instalado**, exige reinstalação autorizada (código 41) |
| `ServiceStarting` | `StartPending` | Aguardar; nenhuma instalação ou reparo. Código 42 só se uma mutação obrigatória continuar bloqueada |
| `ServiceStopping` | `StopPending` | Aguardar; nenhuma instalação ou reparo. Código 42 só se uma mutação obrigatória continuar bloqueada |
| `MarkedForDeletion` | `DeleteFlag=1` ou erro 1072 na consulta | Interromper tudo, recomendar reinicialização, código 3010 |
| `ProcessStillRunning` | Serviço parado, mas `OcsService.exe` ativo | Não executar setup: risco de travar arquivos |
| `RebootRequired` | `ProcessStillRunning` ou `CorruptOrIncomplete` junto com alteração pendente do Windows | Código 3010 |
| `CorruptOrIncomplete` | Chave sem serviço, ou `ImagePath` apontando para binário ausente | Exige reinstalação autorizada; não é "reparado" |
| `Unknown` | `Paused` ou estado não classificável | Nenhuma decisão destrutiva |

`Manual` é tratado junto com `Disabled` porque em ambos os casos o serviço não volta sozinho no próximo boot. `PendingFileRenameOperations` só conta como reinicialização pendente quando alguma entrada menciona OCS: essa chave existe em quase toda máquina e usá-la de forma ampla produziria falsos positivos.

## Erro 1072: causa e tratamento

### Como o instalador oficial chega a 1072

Se o setup oficial for reexecutado enquanto um inventário ainda está ativo, a sequência típica é:

1. O script reexecutou o setup oficial para "reaplicar a configuração" enquanto um inventário disparado pela execução anterior ainda estava ativo.
2. O setup tentou parar o serviço e recebeu `O serviço não pode aceitar mensagens de controle neste momento`, seguido de `Error time out reached while waiting for service stop!`.
3. O setup matou `OcsSystray.exe`, mas **falhou em encerrar `OcsService.exe`** (`Result: 603`).
4. Todas as 15 cópias de arquivo falharam (`ERROR copying OcsService.exe`, `ERROR copying libcurl.dll`, ...), porque o processo vivo mantinha os binários travados. O log do agente confirma: `Error code 32 = O arquivo já está sendo usado por outro processo`.
5. O setup executou `DeleteService` (`Service is installed, so unregistering ... Result: 0`) **com o processo ainda ativo**. O Windows aceitou a remoção, marcou o serviço para exclusão e, como efeito do SCM, gravou `Start=4` (Disabled) e `DeleteFlag=1`.
6. O `CreateService` seguinte não pôde recriar o serviço com o mesmo nome e o start falhou: `O serviço não pode ser iniciado porque está desativado`.
7. Uma tentativa posterior de `Set-Service` / `sc.exe config` recebe **1072 — `ERROR_SERVICE_MARKED_FOR_DELETE`**.

Resultado observável: o serviço aparecia simultaneamente como `Running`, `StartupType Disabled` e marcado para exclusão. A mensagem final dizia "O AGENTE FOI INSTALADO, MAS A FINALIZAÇÃO PRECISA DE ATENÇÃO", embora nenhuma instalação tivesse ocorrido naquela execução.

### O que mudou

**Prevenção.** `Assert-OCSSafeToRunSetup` roda antes de qualquer setup em uma instalação existente: aguarda `OCSInventory.exe` terminar, para o serviço e **espera `OcsService.exe` realmente sair do processo**. Se algum processo não sair no prazo, o setup **não** é executado e o script retorna 3010. Essa é a correção central: o `DeleteService` do instalador oficial nunca mais é alcançado com o processo vivo.

**Detecção.** `DeleteFlag=1` na chave do serviço é lido diretamente, sem sondagem destrutiva. Mensagens contendo `1072`, `marked for delete` ou `marcado para ser excluído` também classificam como `MarkedForDeletion`.

**Reação.** Ao detectar 1072 ou `MarkedForDeletion`, o script:

1. interrompe operações de instalação, reparo e atualização relacionadas ao serviço;
2. preserva arquivos, configuração, `ocsinventory.ini`, `admininfo.conf` e `ocsinventory.dat`;
3. informa em linguagem simples que o Windows precisa concluir uma alteração;
4. recomenda reinicialização, **sem reiniciar automaticamente**;
5. retorna 3010;
6. registra `DeleteFlag`, `Start`, `Status`, `StartType`, PID e o erro Win32 no log.

Não há repetição de `sc.exe config`, `Set-Service`, reinstalação, reparo, `DeleteService` ou remoção de chave de registro. `sc.exe config` é tentado no máximo uma vez como fallback de `Set-Service`, e um 1072 encerra a tentativa em vez de iniciar um laço.

Tela apresentada ao técnico:

```text
========================================
       É NECESSÁRIO REINICIAR
========================================

O OCS Inventory já está instalado e configurado.

O Windows ainda está finalizando uma alteração
anterior no serviço do OCS.

Nenhuma reinstalação foi realizada.

Cliente : CLIENTE-01
Versão  : 2.11.0.1
TAG     : CLIENTE-01

Reinicie o computador quando for conveniente e
execute este instalador novamente.

Sua configuração foi preservada.

Código para suporte: 3010
```

Termos como `ChangeServiceConfig`, `ERROR_SERVICE_MARKED_FOR_DELETE` e `sc.exe 1072` ficam no log, não na tela.

### Depois da reinicialização

O Windows conclui a exclusão pendente:

| Item | Antes da reinicialização | Depois |
| --- | --- | --- |
| Chave `HKLM\SYSTEM\CurrentControlSet\Services\OCS Inventory Service` | Presente, `Start=4`, `DeleteFlag=1` | **Ausente** |
| `Get-Service 'OCS Inventory Service'` | `Running` / `Disabled` | **Não registrado** |
| `OcsService.exe` | Processo ainda ativo | Encerrado |
| Binários em `C:\Program Files\OCS Inventory Agent` | 2.11.0.1 | 2.11.0.1, intactos |
| `ocsinventory.ini`, `admininfo.conf`, `ocsinventory.dat` | Presentes | **Presentes e preservados** |
| Entrada de desinstalação | `OCS Inventory NG Agent 2.11.0.1` | Idem |

Isso confirma o diagnóstico: o 1072 era mesmo uma exclusão de serviço pendente, e a reinicialização — não uma reinstalação forçada — era a saída correta. Nenhum dado de identidade foi perdido.

O estado resultante, porém, revelou uma lacuna que não existia no desenho original: **agente instalado, versão correta, configuração correta e serviço inexistente**. Não há reparo possível pelo SCM, porque não há serviço para configurar. A versão anterior do fluxo perguntava sobre inventário e só então falhava com um erro técnico ("o serviço do OCS não está registrado no Windows", código 40).

O tratamento agora é unificado com o de registro incompleto, através de `$serviceNeedsReinstall` (`agente encontrado` **e** (`CorruptOrIncomplete` **ou** serviço inexistente)):

```text
========================================
     O SERVIÇO PRECISA SER RECRIADO
========================================

O OCS Inventory está instalado, mas o serviço do
Windows que envia o inventário não está registrado.

Isso acontece depois que o Windows conclui uma
remoção pendente do serviço.

Cliente : CLIENTE-01
Versão  : 2.11.0.1
TAG     : CLIENTE-01

O instalador oficial precisa ser executado para
recriar o serviço. Sua configuração e a identidade
deste computador serão preservadas.

Deseja reinstalar o agente para recriar o servico? [S/N]:
```

Recusar retorna 41 sem alterar nada. Autorizar executa o setup oficial, que recria o serviço e reaplica a configuração. Se a versão instalada for mais recente que a do pacote, a recriação é bloqueada em vez de fazer downgrade silencioso, também com retorno 41. Em nenhum caso um comando de serviço é enviado a um serviço inexistente.

## Versão: comparação e atualização

A comparação usa `[System.Version]`, nunca texto. Comparação textual erraria: como string, `'2.9.0.0' -gt '2.11.0.0'` é verdadeiro.

| Estado | Comportamento |
| --- | --- |
| `NotInstalled` | Instala, sem perguntas extras além da seleção de cliente |
| `Older` | Mostra a tela "Atualização disponível" e pergunta `Deseja atualizar o OCS Inventory Agent? [S/N]` |
| `Current` | Não reinstala; só reaplica configuração se uma mudança de TAG/servidor foi autorizada |
| `Newer` | Bloqueia downgrade e segue apenas com verificações seguras |
| `Unknown` | Não reinstala cegamente; pergunta explicitamente |

Recusar a atualização **não é erro**: o script mantém a versão atual e continua oferecendo o inventário. Antes de uma atualização autorizada, são verificados estado do serviço, processos ativos, reinicialização pendente e 1072; identidade, servidor e TAG são preservados, exceto quando a mudança foi autorizada. Com `MarkedForDeletion` a atualização não ocorre e o retorno é 3010.

Com uma versão instalada mais nova, nenhum downgrade é realizado:

```text
Este computador já possui uma versão mais recente do OCS.

Versão instalada                  : 2.12.0.0
Versão disponível neste instalador: 2.11.0.1

Nenhum downgrade será realizado.
```

Se a TAG/servidor divergirem nesse caso, a troca não é aplicada, porque exigiria rodar um pacote mais antigo. O script informa isso e registra o motivo no log.

**Setup com código 0 não é prova de sucesso.** `Test-OCSUpdateOutcome` compara a versão em disco depois do setup com a versão alvo. Se o pacote não foi aplicado (arquivos travados, por exemplo), o retorno é 31 e nenhuma atualização é declarada bem-sucedida. Setup com código 3010 propaga 3010.

## TAG e servidor

A TAG nunca muda silenciosamente. Quando a TAG atual difere da selecionada:

```text
========================================
        ATENÇÃO À CONFIGURAÇÃO
========================================

Este computador está configurado para outro cliente.

Configuração atual:
TAG: CLIENTE-02

Configuração selecionada:
TAG: CLIENTE-01
```

Seguido de `Deseja realmente alterar este computador para CLIENTE-01? [S/N]`. Um servidor divergente recebe tratamento equivalente, com `Deseja realmente alterar o servidor deste computador? [S/N]`. Quando a configuração atual não pode ser lida, há uma confirmação própria. Qualquer recusa cancela com código 2, sem alterar nada e sem inventariar para o cliente selecionado.

SERVER é lido de `[HTTP]` em `ocsinventory.ini`. A TAG é lida do XML `admininfo.conf`, com DTD desabilitado. `ocsinventory.dat` guarda a identidade da máquina, **não** a TAG: nunca é apagado, recriado ou tratado como arquivo de TAG. Arquivo ausente ou XML inválido deixa a TAG desconhecida e exige confirmação. URLs antigas potencialmente sensíveis são omitidas do console.

## Idempotência

Executar o instalador duas vezes em um PC saudável é seguro. A segunda execução não reinstala, não repara sem necessidade, não troca TAG, não remove serviço, não apaga identidade e não provoca bloqueio de arquivos.

Com `-NoPause` (execução não interativa), máquina pronta retorna **0** sem perguntar e **sem** disparar inventário:

```text
.\Install-OCS.cmd -ClientTag CLIENTE-01 -NoPause
```

Sem `-NoPause`, o técnico ainda vê a tela de pronto e pode recusar o inventário; recusar também é sucesso (código 0):

```text
========================================
           OCS ESTÁ PRONTO
========================================

Versão : 2.11.0.1
Cliente: CLIENTE-01
TAG    : CLIENTE-01

Serviço:
Serviço em execução com início automático.

Nenhuma instalação ou atualização é necessária.

Deseja executar o agente OCS e consultar o servidor agora? [S/N]:
```

Inventário explícito, independente de `-NoPause`:

```text
.\Install-OCS.ps1 -ClientTag CLIENTE-01 -RunInventory -NoPause
```

Quando a versão e a configuração estão corretas mas o serviço está errado, o script corrige **somente o serviço**, com a pergunta `Deseja corrigir o servico e consultar o servidor agora? [S/N]`. Nenhum pacote é reinstalado. Uma recusa não altera nada. Após o inventário, o estado do serviço é apenas relido para o resumo: não há uma segunda tentativa de reparo, para não criar laços de correção.

## Detecção da instalação

A detecção combina serviço, registro Uninstall nas duas visões usuais e diretórios Program Files, **sem `Win32_Product`**. A versão instalada vem do `FileVersion` de `OCSInventory.exe`. Instalações múltiplas e serviço com argumentos de diretório/servidor personalizados são bloqueados. Instalação customizada sem registro e sem serviço pode não ser detectada.

## Inventário

Antes de solicitar um inventário, o script aguarda o serviço sair de `StartPending` e verifica se `OCSInventory.exe` já está em execução. Isso é o caso normal logo após o setup: o serviço recém-iniciado dispara um inventário sozinho, e o servidor OCS frequentemente pede **IpDiscover** (varredura de rede), que pode levar vários minutos.

Enquanto esse processo está ativo e **nenhuma mutação obrigatória** resta (máquina pronta, ou instalação/configuração já aplicada), o script **não** envia outro inventário e **não** retorna 42. Registra `InventoryAlreadyRunning=True` e `InventoryStatus` equivalente a já em execução. `-NoPause` nunca pergunta “Deseja aguardar mais 2 minutos?”: a espera de processo é finita (`InventoryQuietWaitSeconds`).

O código **42** permanece quando um processo OCS ativo **impede uma alteração obrigatória** (instalação, atualização, reparo, troca de configuração ou migração de CA ainda não aplicada). A primeira espera é silenciosa (30 s); no modo interativo o técnico decide, em rodadas de 2 minutos, se continua aguardando (até 15 minutos). Recusar essa espera, com mutação ainda pendente, retorna **42**, com a tela "O AGENTE ESTÁ OCUPADO AGORA" e `ExitCode=42 Reason=<motivo>` no log. `OcsService.exe` que não sai depois da parada continua sendo **3010**, porque aí sim há risco real de 1072.

Se `-RunInventory` foi pedido e não houver inventário em andamento, o script garante o serviço em `Automatic` e `Running` e envia ao serviço OCS seu controle privado `128` (`Run Inventory Now`). Aguarda até 180 segundos pelo resultado em `OCSInventory.log`; se o processo ainda estiver no IpDiscover, no modo interativo oferece espera adicional. Com `-NoPause`, não transforma isso em 42: registra envio não confirmado nesta sessão. Inventário em andamento **não** é motivo para 42 quando `ConfigurationReady=True` e `MutationRequired=False`.

O padrão "parar o serviço + executar `OCSInventory.exe /FORCE`" é evitado deliberadamente: foi ele que gerou concorrência entre `OcsService.exe` e `OCSInventory.exe` e arquivos bloqueados. `Get-OCSArguments -Mode Inventory` continua existindo e é registrado no log como referência, mas **não é executado** pelo fluxo atual.

Há uma corrida conhecida: o inventário automático carrega a TAG antiga na memória e, ao terminar, reescreve `admininfo.conf`. Por isso a TAG só é considerada persistida **depois** que `OCSInventory.exe` sai. Se a TAG tiver voltado ao valor anterior, o setup é reaplicado **uma** vez — a troca já havia sido autorizada.

Referências: [`NTService.h` define `SERVICE_CONTROL_USER` como 128](https://github.com/OCSInventory-NG/WindowsAgent/blob/master/Service/NTService.h) e [`OcsService.cpp` trata o controle `Run Inventory Now`](https://github.com/OCSInventory-NG/WindowsAgent/blob/master/Service/OcsService.cpp).

## Adaptador e argumentos do setup

`Get-OCSArguments`, `Install-OCSAgent`, `Set-OCSConfiguration`, `Repair-OCSService` e `Invoke-OCSInventory` isolam o comportamento do produto. Setup: `/S /NOSPLASH /SERVER="..." /TAG="..." /SSL=1 /NOTAG /DEBUG=0`, sempre com `/CA="..."` apontando para o bundle preparado. Não usa `/NOW`, pois o inventário é executado separadamente.

Esses argumentos estão documentados pelo instalador oficial e cobertos pelos testes. `/SSL=0` não é usado e certificados não são ignorados em nenhuma circunstância.

Referências consultadas:

- [Documentação oficial de instalação Windows e opções](https://wiki.ocsinventory-ng.org/03.Basic-documentation/Setting-up-the-Windows-Agent-2.x-on-client-computers/)
- [OPTIONS.TXT oficial](https://github.com/OCSInventory-NG/WindowsAgent/blob/master/OPTIONS.TXT)

## Logs e códigos de saída

Logs: `%ProgramData%\OCSInstaller\Logs\OCS-Install-<data>-<guid>.log`. Em DryRun sem administrador, usa `%TEMP%\OCSInstaller\Logs`.

A tela recebe mensagem amigável; o log recebe informação técnica. São registrados: timestamp, hostname, usuário, cliente, TAG, servidor (conhecido/desconhecido), versão instalada, versão alvo e sua origem, estado da versão, estado do serviço com `Status`, `StartType`, `RegistryStart`, `DeleteFlag`, `ImagePathExists` e PID, reinicialização pendente, cada decisão tomada (configuração, serviço, versão, inventário), argumentos do setup, exit code do setup, resultado do inventário, erros Win32 incluindo 1072, o 3010 e o resultado final. Não faz transcript nem copia configurações brutas. Erros externos são resumidos para evitar vazamento de URLs. **Nunca registra credenciais**; configurações com campos de credencial são bloqueadas antes de qualquer uso.

| Código | Significado |
| --- | --- |
| 0 | Operação concluída com sucesso, ou simulação concluída |
| 1 | Inicialização ou criação do log falhou |
| 2 | Cancelamento do usuário, incluindo recusa de troca de TAG/servidor |
| 5 | UAC cancelado ou elevação indisponível |
| 10 | Cadastro, JSON ou seleção de cliente inválidos |
| 20 | Detecção do agente ou validação do pacote falhou |
| 30 | Instalação ou configuração falhou durante o setup |
| 31 | Setup terminou sem erro, mas a versão em disco não corresponde ao pacote |
| 32 | Setup terminou, mas servidor/TAG não foram persistidos |
| 40 | Controle do serviço falhou |
| 41 | Serviço ausente ou com registro incompleto, e a reinstalação necessária para recriá-lo não foi autorizada |
| 42 | Mutação obrigatória bloqueada por agente ocupado (`OCSInventory.exe` ou serviço em `StartPending`/`StopPending`); nada foi alterado; **não** é necessário reiniciar. Não se aplica a máquina já pronta só porque um inventário está em andamento |
| 50 | Inventário falhou ou não confirmou resultado no prazo |
| 3010 | Operação válida, mas reinicialização necessária |

Cada código tem um significado único; nenhum é reaproveitado para erros semanticamente diferentes. Exit codes nativos de processos ficam no log; os códigos da tabela classificam a etapa.

3010 é retornado quando o Windows precisa concluir uma alteração: serviço marcado para exclusão, `OcsService.exe` que não saiu depois da parada (risco real de 1072), e setup oficial que solicitou reinicialização. Inventário em andamento **não** é 3010. Também **não** é 42 quando a configuração já está pronta e nenhuma mutação é necessária.

Cadeia do código 3010, medida neste Windows:

| Camada | Comportamento |
| --- | --- |
| A) Setup OCS | Exit code nativo 3010 (reinicialização pedida pelo MSI/NSIS) |
| B) `Install-OCS.ps1` | Interpreta 3010 como `RebootRequired`, não dispara inventário, resume e `exit 3010` |
| C) `Install-OCS.cmd` | Captura `%ERRORLEVEL%` e faz `exit /b` do mesmo valor |

Windows PowerShell 5.1 (`powershell.exe -File`), PowerShell 7 (`pwsh -File`) e `cmd.exe` **preservam 3010**. Não há truncamento para 8 bits (3010 % 256 = 198). O contrato externo permanece 3010. O CMD sempre lança `powershell.exe` 5.1, mesmo que o técnico execute testes com `pwsh`.

Diagnóstico: para download, confira URL direta, certificado, proxy corporativo, SHA256 e tamanho. Para comunicação OCS, confira CA bundle, DNS, endpoint e `OCSInventory.log` no diretório de dados do agente. Para serviço, examine o Visualizador de Eventos e permissões. `debug: 2` aumenta os logs do próprio agente; revise-os antes de compartilhar.

## Testes

Suíte sem Pester ou módulos externos. Rode tudo com `tests\Run-AllTests.ps1`; cada suíte roda em um processo separado, para que as sentinelas de uma não vazem para outra. Executar por `powershell.exe` testa Windows PowerShell 5.1 e por `pwsh` testa PowerShell 7.

Resultado em 18/09/2026: **563 asserções passaram em Windows PowerShell 5.1 (5.1.26100.9444) e 563 em PowerShell 7.6.6**, nas 8 suítes.

| Suíte | Asserções | Cobertura |
| --- | --- | --- |
| `Test-VersionDecisions.ps1` | 42 | Normalização de versão, os cinco estados, prova de que a comparação textual erraria, avaliação do resultado do setup, versão alvo lida do EXE, fallback só sem arquivo, EXE ilegível não inventa versão |
| `Test-ServiceStateMachine.ps1` | 47 | Os dez estados do serviço, `DeleteFlag=1`, 1072 em `Set-Service` e em `sc.exe`, ausência de laço, recusa de reparo com exclusão pendente, espera de processo sem encerrá-lo |
| `Test-ServiceTransitions.ps1` | 22 | Transições `Pending`, idempotência do start, correção de `Disabled` sem parar o serviço, timeout com diagnóstico, controle 128, erro do agente não tratado como sucesso |
| `Test-Certificates.ps1` | 36 | Bundle `ocs-cacert.pem`, `/CA`/`SSL=1`, ausência de `/SSL=0`, DryRun sem criar arquivo, bundle legado não apagado, prontidão exige CaBundle+arquivo |
| `Test-ClientSelection.ps1` | 73 | Menu dinâmico, ClientTag, ClientIndex, TAG duplicada, cliente único, UTF-8, equivalência de URL, Authenticode, SHA256 sempre registrado, publisher opcional |
| `Test-ExistingInstallationFlow.ps1` | 277 | Fluxo ponta a ponta dos 18 cenários obrigatórios, config B vs A, SSL=0, SERVER equivalente, setup 0 e 3010, migração de CA, idempotência com `-NoPause`, `-RunInventory`, código 42 só com mutação bloqueada |
| `Test-Installer.ps1` | 51 | JSON, menu, quoting, caminhos com espaços, campos reservados, credenciais, DryRun com e sem agente, DryRun sem criar o bundle, DryRun com exclusão pendente, launcher CMD real |
| `Test-CmdLauncher.ps1` | 15 | `Install-OCS.cmd` com espaços, `-ClientTag`, `-DryRun`, `-NoPause`, `-RunInventory`, exit 10/255/256/3010 em CMD e `powershell.exe -File` |

Os 18 cenários obrigatórios e onde estão cobertos:

| # | Cenário | Suíte |
| --- | --- | --- |
| 1 | `NotInstalled` | Version + Flow |
| 2 | 2.10.1.0 → 2.11.0.1 = `Older` | Version + Flow |
| 3 | 2.11.0.1 → 2.11.0.1 = `Current` | Version + Flow |
| 4 | 2.12.0.0 → 2.11.0.1 = `Newer`, sem downgrade | Version + Flow |
| 5 | Versão desconhecida = `Unknown`, sem reinstalação cega | Version + Flow |
| 6 | Running + Automatic = `ServiceHealthy` | StateMachine |
| 7 | Running + Disabled precisa correção | StateMachine + Flow |
| 8 | Stopped + Automatic | StateMachine + Flow |
| 9 | `ServiceMissing` | StateMachine + Flow |
| 10 | `MarkedForDeletion`/1072 → 3010, sem update/reinstall | StateMachine + Flow + Installer |
| 11 | Setup 0 ainda valida versão, configuração e serviço | Version + Flow |
| 12 | Setup 3010 → reinicialização necessária | Version + Flow |
| 13 | Setup 0 mas versão continua antiga → não declara sucesso | Version + Flow |
| 14 | TAG diferente exige confirmação | Flow |
| 15 | SERVER diferente exige confirmação | Flow |
| 16 | Update recusado não é erro | Flow |
| 17 | Mesma versão e tudo correto → nenhuma reinstalação | Flow |
| 18 | Mesma versão e serviço incorreto → corrige só o serviço | Flow |

Cenários adicionais cobertos além dos 18 obrigatórios:

| Cenário | Resultado esperado |
| --- | --- |
| Registro do serviço incompleto, reinstalação recusada | 41, nada alterado |
| Registro do serviço incompleto, reinstalação autorizada | 0, serviço recriado |
| Registro incompleto com versão instalada mais nova | 41, sem downgrade |
| Agente instalado e serviço ausente (estado pós-reboot), recusado | 41, nenhum comando enviado a serviço inexistente |
| Agente instalado e serviço ausente, autorizado | 0, serviço recriado e inventário enviado |
| Processo do agente não liberou os arquivos | 3010, setup não executado |
| Configuração não persistida após o setup | 32 |
| Falha de serviço sem instalação nesta execução | 40, mensagem final honesta |
| Máquina pronta + `-NoPause` | 0, sem inventário, `MutationRequired=False` |
| Máquina pronta + recusa interativa de inventário | 0 |
| Máquina pronta + `-RunInventory` | inventário solicitado |
| `-RunInventory` com `OCSInventory.exe` já ativo | 0, sem segundo inventário |
| Instalação nova com inventário automático já ativo | 0, sem segundo inventário |
| Mutação obrigatória bloqueada por inventário/`StartPending` | 42, `ExitCode=42 Reason=` no log |
| `StartPending` sem mutação obrigatória | 0, código 42 não se aplica |

As fronteiras mutáveis são substituídas por sentinelas: `Get-OCSServiceFacts`, `Install-OCSAgent`, `Set-OCSConfiguration`, `Set-OCSServiceState`, `Invoke-OCSInventory`, `Invoke-ServiceControllerTool`, `Wait-OCSProcessExit`, `Get-InstalledOCSAgent`, `Get-ExistingOCSConfiguration` e `Read-Host`. Os testes não instalam OCS, não controlam o serviço real, não encerram processos e não escrevem no diretório real do agente. `Test-Certificates` e `Test-Installer` escrevem apenas em diretórios temporários próprios, removidos ao final com verificação de prefixo.

## Verificação real pendente

Os testes simulados cobrem as decisões do instalador. Ainda dependem de execução real em um ambiente de destino:

1. Instalação nova, atualização e reexecução idempotente com `-NoPause`.
2. Recriação autorizada do serviço após `MarkedForDeletion`/1072 e reboot.
3. Troca de cliente, migração de CaBundle e `-RunInventory` com e sem processo já ativo.
4. VMs Windows 10/11, incluindo x86: UAC, rede HTTPS, SHA256 incorreto, serviço parado, falha de comunicação e timeout.
5. Console em CP437 (Windows em inglês), para confirmar a remoção de acento em vez de `?`.

Nenhum desses resultados de integração é presumido pelos testes simulados.

## Práticas proibidas neste script

Não são usados, em nenhum caminho de código: `Win32_Product`, `Invoke-Expression`, remoção forçada de chave de registro, `DeleteService` como "correção", `taskkill`, `Stop-Process -Force`, reinicialização automática, alteração permanente de `ExecutionPolicy`, `/SSL=0`, desativação de verificação de certificado, downgrade automático, troca silenciosa de TAG, remoção de `ocsinventory.dat` e laços de reinstalação ou reparo.

O script para o serviço apenas quando uma instalação ou atualização foi explicitamente autorizada, e o faz pelo SCM (`Stop-Service`, com fallback `sc.exe stop`), aguardando a saída do processo — nunca encerrando processos.

# Diagnóstico e solução de problemas

[Voltar ao README](../README.md) · [Recuperação do serviço](SERVICE-RECOVERY.md) · [Segurança](SECURITY.md) · [Testes](TESTING.md)

## Por onde começar

Confira o código de saída e o log da execução. Use `-DryRun` para inspecionar a configuração e o pacote sem instalar. Para 1072 ou 3010, consulte [recuperação do serviço](SERVICE-RECOVERY.md). Para assinatura, SHA256 ou certificados, consulte [segurança](SECURITY.md). A tabela completa de retornos está em [logs e códigos de saída](#logs-e-códigos-de-saída).

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

## Parâmetros e simulação

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
```

O CMD usa `ExecutionPolicy Bypass` apenas no processo. Não altera política permanente, GPO, Defender ou certificados. Políticas corporativas podem impedir execução; nesse caso use assinatura/aprovação corporativa, sem enfraquecer a política. A execução real solicita UAC quando necessário e propaga o código do processo elevado. `DryRun` não precisa de elevação.

**Não existem IDs no `clients.json`.** Os números do menu são gerados na hora, na ordem do arquivo. `-ClientTag` é o identificador estável para automação. `-ClientIndex` é só a posição atual do menu nesta execução e **não** deve ser gravado em scripts permanentes. `-ClientId` continua aceito como alias de `-ClientIndex` para não quebrar chamadas antigas, mas o log registra `MenuIndex` e `ClientTag`, nunca `ClientId`.

Esses parâmetros dispensam o menu, mas **mantêm as confirmações de troca de cliente**; não são modo totalmente desassistido. `-ClientIndex 0` (explícito) equivale a escolher Sair no menu e retorna código 2. `-NoPause` remove apenas pausas e perguntas **opcionais** (inventário no final, “Pressione ENTER para sair”). Não confirma automaticamente ações opcionais: em máquina já pronta, `-NoPause` **não** reinstala, **não** reconfigura e **não** dispara inventário. `-RunInventory` solicita inventário de forma explícita, inclusive junto com `-NoPause`. Opção `0` ou resposta diferente de `S` cancela. Não existe confirmação automática para troca de cliente.

`DryRun` lê configuração, detecta o agente, classifica o serviço e a versão, mostra os comandos planejados e verifica o pacote local ou a configuração de download. Não baixa, instala, copia certificados, altera arquivos OCS, eleva, controla serviços ou executa inventário. Escreve apenas seu próprio log. Pacote ausente gera aviso e código 20. Um serviço com exclusão pendente faz o `DryRun` retornar 3010: é um diagnóstico real, não uma falha da simulação.

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

## Acentuação e codificação

O `Install-OCS.ps1` é salvo em UTF-8 com BOM: as telas amigáveis usam acentuação e o Windows PowerShell 5.1 precisa do BOM para interpretá-la. `clients.json` e os logs são lidos/escritos em UTF-8; nomes como São José, Coordenação, Indústria e Clínica Paraná são preservados nos dados. Quando a página de código do console não representa um caractere acentuado (por exemplo CP437 em Windows em inglês), `Format-ConsoleText` remove apenas o acento na **exibição**, em vez de imprimir `?`. Em CP850 (padrão pt-BR) a acentuação é exibida integralmente. Essa adaptação vale só para o console: JSON, TAG e log não são destituídos de acento.

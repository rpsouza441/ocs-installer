# Recuperação do serviço OCS

[Voltar ao README](../README.md) · [Diagnóstico e códigos de saída](TROUBLESHOOTING.md#logs-e-códigos-de-saída)

Consulte este guia quando o serviço estiver parado, ausente, com registro incompleto ou marcado para exclusão. Para o código 3010, reinicie o Windows quando for conveniente e execute novamente o instalador; a configuração e a identidade são preservadas.

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

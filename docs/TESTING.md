# Testes

[Voltar ao README](../README.md) · [Recuperação do serviço](SERVICE-RECOVERY.md)

## Executar as suítes

Na raiz do repositório, execute cada comando separadamente para validar o host correspondente. PowerShell 7 é opcional e precisa estar instalado para usar `pwsh`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\Run-AllTests.ps1'
pwsh -NoProfile -ExecutionPolicy Bypass -File '.\tests\Run-AllTests.ps1'
```

## Cobertura automatizada

Suíte sem Pester ou módulos externos. Rode tudo com `tests\Run-AllTests.ps1`; cada suíte roda em um processo separado, para que as sentinelas de uma não vazem para outra. Executar por `powershell.exe` testa Windows PowerShell 5.1 e por `pwsh` testa PowerShell 7.

Resultado histórico registrado em 18/09/2026 (não representa uma nova execução nesta revisão da documentação): **563 asserções passaram em Windows PowerShell 5.1 (5.1.26100.9444) e 563 em PowerShell 7.6.6**, nas 8 suítes.

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

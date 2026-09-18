# Instalador interativo OCS Inventory para Windows

Instala, atualiza ou confere o OCS Inventory Agent a partir de um cadastro local de clientes. Detecta a arquitetura do Windows, valida o instalador e preserva a configuração e a identidade da máquina. Em um computador já pronto, pode ser executado novamente sem reinstalar o agente.

Requer **Windows 10/11 x86 ou x64 e Windows PowerShell 5.1**, sem módulos externos. Windows ARM não é suportado.

## Instalação

1. Baixe ou clone este repositório. Se usar ZIP, extraia antes de executar e mantenha a pasta disponível até terminar.
2. Obtenha os instaladores oficiais do OCS Inventory e coloque os EXEs em `files/`, com os nomes abaixo. Os binários **não são versionados** neste repositório.
3. Crie o cadastro local a partir do exemplo e ajuste os dados conforme a seção [Configuração](#configuração):

   ```powershell
   Copy-Item .\clients.example.json .\clients.json
   ```

4. Execute `Install-OCS.cmd` por duplo clique ou pelo terminal. A execução real solicita elevação via UAC quando necessário.

```text
files/
├── OCS-Windows-Agent-Setup-x64.exe
└── OCS-Windows-Agent-Setup-x86.exe
```

O script escolhe o EXE pela arquitetura do Windows e lê dele a versão alvo. Para distribuir a ferramenta, envie a pasta inteira com o cadastro e os pacotes necessários; caminhos com espaços são aceitos. Consulte [pacotes e validação](docs/SECURITY.md#pacote-e-versão-alvo) para configurar download por HTTPS, SHA256 e publisher.

## Configuração

Edite `clients.json`, que é ignorado pelo Git:

```json
{
  "server": "https://ocs.example.com/ocsinventory",
  "clients": [
    { "name": "Cliente Exemplo 1", "tag": "CLIENTE-01" },
    { "name": "Cliente Exemplo 2", "tag": "CLIENTE-02" }
  ]
}
```

Use o endpoint HTTPS **`/ocsinventory`**, destinado ao agente. `/ocsreports` é a interface web e não é aceito. Cada cliente precisa de `name` e uma `tag` única, sem distinção entre maiúsculas e minúsculas. Espaços e acentos são permitidos.

Não há IDs: o menu segue a ordem do JSON. Para adicionar ou remover clientes, edite a lista; para automação, use `-ClientTag`. Não armazene senhas no cadastro. As [regras completas do cadastro](docs/TROUBLESHOOTING.md#clientes) e a [configuração de certificados](docs/SECURITY.md#certificados-e-campos-sensíveis) estão na documentação técnica.

## Uso

Na pasta do projeto:

```powershell
# Abrir o fluxo interativo
.\Install-OCS.cmd

# Simular para um cliente, sem instalar ou alterar o agente
.\Install-OCS.ps1 -ClientTag "CLIENTE-01" -DryRun

# Conferir o cliente sem pausas opcionais
.\Install-OCS.ps1 -ClientTag "CLIENTE-01" -NoPause

# Solicitar também o inventário
.\Install-OCS.ps1 -ClientTag "CLIENTE-01" -RunInventory -NoPause
```

| Parâmetro | Uso |
| --- | --- |
| `-ClientTag` | Seleciona o cliente por sua TAG estável. |
| `-ClientIndex` | Seleciona pela posição atual do menu; evite em automações permanentes. |
| `-ClientsPath` | Usa outro arquivo de cadastro, inclusive em caminho com espaços. |
| `-DryRun` | Inspeciona configuração, serviço, versão e pacote; escreve apenas o próprio log. |
| `-NoPause` | Remove pausas e perguntas opcionais; não autoriza troca de cliente nem solicita inventário. |
| `-RunInventory` | Solicita inventário explicitamente, inclusive com `-NoPause`. |

A troca de TAG ou servidor exige confirmação. Os parâmetros não tornam o fluxo totalmente desassistido. Uma versão mais nova já instalada não sofre downgrade; uma máquina pronta não é reinstalada. Um inventário já em execução não dispara outro processo.

Logs ficam em `%ProgramData%\OCSInstaller\Logs`; em simulação sem administrador, em `%TEMP%\OCSInstaller\Logs`. O código **3010** indica necessidade de reinicialização, sem reiniciar automaticamente. Consulte [diagnóstico e códigos de saída](docs/TROUBLESHOOTING.md#logs-e-códigos-de-saída) e [recuperação do serviço](docs/SERVICE-RECOVERY.md) para tratar falhas.

## Segurança

O instalador exige assinatura Authenticode válida e registra o SHA256 do pacote; um hash configurado também é conferido. O agente usa HTTPS com validação de certificado e um bundle de CAs confiáveis do Windows, ou um arquivo fornecido por `caFile`.

O launcher usa `ExecutionPolicy Bypass` apenas no processo, sem alterar a política permanente. Respeite as políticas corporativas de execução. Consulte [Segurança](docs/SECURITY.md) para validação de pacotes, certificados, campos bloqueados e tratamento de dados nos logs.

## Testes

Execute as oito suítes automatizadas com Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\Run-AllTests.ps1'
```

Os testes simulam as operações do agente e não instalam OCS nem alteram o serviço real. Consulte [Testes](docs/TESTING.md) para executar com PowerShell 7, conhecer a cobertura e conferir as verificações de integração ainda pendentes.

## Documentação técnica

| Documento | Conteúdo |
| --- | --- |
| [Recuperação do serviço](docs/SERVICE-RECOVERY.md) | Estados do serviço, erro 1072, reinicialização e recriação autorizada. |
| [Segurança](docs/SECURITY.md) | Pacotes, assinatura, SHA256, certificados e restrições. |
| [Testes](docs/TESTING.md) | Execução das suítes, cobertura e validação em ambiente real. |
| [Solução de problemas](docs/TROUBLESHOOTING.md) | Logs, códigos de saída, parâmetros, configuração e inventário. |

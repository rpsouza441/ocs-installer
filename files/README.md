# Pacotes do OCS Inventory Agent

Os instaladores não são versionados neste repositório. Obtenha os EXEs oficiais e coloque nesta pasta os pacotes necessários para os computadores de destino:

- `OCS-Windows-Agent-Setup-x64.exe`: Windows 64 bits.
- `OCS-Windows-Agent-Setup-x86.exe`: Windows 32 bits.

O script seleciona o pacote pela arquitetura do Windows e lê a versão alvo do EXE. Extraia os pacotes ZIP antes de usar; o instalador espera um EXE.

URLs HTTPS, SHA256 e publisher opcionais ficam em `InstallerPackages`, no início de `Install-OCS.ps1`. Consulte [pacotes e validação](../docs/SECURITY.md#pacote-e-versão-alvo) e o [guia de instalação](../README.md#instalação).

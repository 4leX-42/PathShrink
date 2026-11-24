<div align="center">

# PathShrink

Rutas de OneDrive y SharePoint de más de 400 caracteres, resueltas con el mínimo de renombrados. Primero sin perder letras.

[![CI](https://img.shields.io/github/actions/workflow/status/4leX-42/PathShrink/ci.yml?style=flat-square&label=CI)](https://github.com/4leX-42/PathShrink/actions/workflows/ci.yml) ![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-1f1f1f?style=flat-square&logo=powershell&logoColor=white) ![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-1f1f1f?style=flat-square) ![EN ES PT](https://img.shields.io/badge/EN_%C2%B7_ES_%C2%B7_PT-1f1f1f?style=flat-square) [![MIT](https://img.shields.io/badge/license-MIT-c9a96e?style=flat-square)](LICENSE)

<img src="docs/images/results.es.png" width="820" alt="PathShrink: rutas largas y cambios previstos">

<sub>[English](README.md) · Parte de <a href="https://github.com/4leX-42/GADGETS-SUPPORT_CX">GADGETS-SUPPORT_CX</a></sub>

</div>

## <img src="https://api.iconify.design/lucide/download.svg?color=%238b949e" width="18" align="top"> Instalar

PowerShell normal, con la cuenta dueña del OneDrive (sin elevar):

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; [Net.ServicePointManager]::SecurityProtocol=3072; $f="$env:TEMP\install-pathshrink.ps1"; irm https://raw.githubusercontent.com/4leX-42/PathShrink/main/install.ps1 -OutFile $f; powershell -NoProfile -ExecutionPolicy Bypass -File $f
```

Por usuario, sin admin, con SHA-256 comprobado. `-NoExe` si un antivirus o EDR detiene `PathShrink.exe`; `-Uninstall` lo quita. Zips portables en [Releases](https://github.com/4leX-42/PathShrink/releases/latest).

## <img src="https://api.iconify.design/lucide/folder-tree.svg?color=%238b949e" width="18" align="top"> Qué hace

| | |
|---|---|
| <img src="https://api.iconify.design/lucide/ruler.svg?color=%238b949e" width="18" align="top"> **Longitud en servidor** | Cuenta la ruta web decodificada, con el prefijo de la biblioteca, como Microsoft |
| <img src="https://api.iconify.design/lucide/sparkles.svg?color=%238b949e" width="18" align="top"> **Primero sin pérdida** | Espacios antes que letras; letras solo con recorte activado |
| <img src="https://api.iconify.design/lucide/list-checks.svg?color=%238b949e" width="18" align="top"> **Plan mínimo** | Carpetas antes que archivos; solo los renombrados que arreglan una ruta |
| <img src="https://api.iconify.design/lucide/shield-check.svg?color=%238b949e" width="18" align="top"> **Vista previa y verificación** | Nada cambia sin confirmar; el resultado se relee en disco |
| <img src="https://api.iconify.design/lucide/undo-2.svg?color=%238b949e" width="18" align="top"> **Reversión comprobada** | `undo.csv` por ejecución; solo restaura lo que sigue donde quedó |
| <img src="https://api.iconify.design/lucide/triangle-alert.svg?color=%238b949e" width="18" align="top"> **Otros bloqueos** | Nombres reservados, `~$`, `_vti_`, nombres de más de 255 (Pro) |

No borra, no mueve, no descarga; no toca el registro ni el sistema; sin red. Solo escribe en `%LOCALAPPDATA%\PathShrink`.

| Plan de ejecución | Cambios aplicados y reversión |
|---|---|
| ![Plan](docs/images/plan.es.png) | ![Historial](docs/images/history.es.png) |

## <img src="https://api.iconify.design/lucide/terminal.svg?color=%238b949e" width="18" align="top"> Línea de comandos

```powershell
Import-Module .\PathShrink\PathShrink.psd1
Invoke-PathShrink -WhatIf                     # solo el plan
Invoke-PathShrink -AllowTrim -MinNameLength 25
Get-PathShrinkHistory                         # ejecuciones que renombraron algo
Undo-PathShrink -UndoFile "$env:LOCALAPPDATA\PathShrink\Reports\<ejecucion>\undo.csv"
```

<sub>Algoritmo, ajustes Pro, limitaciones y solución de problemas: [README en inglés](README.md).</sub>

<div align="center">

<sub>[MIT](LICENSE) · Sin relación con Microsoft</sub>

</div>

# CLAUDE.md - HyperVLabKit

## Overview

Headless-сборка исследовательских лаб (Windows VM) на Hyper-V хосте с рабочей станции Windows.
Цепочка: `Workstation --WinRM(lib/hv.ps1)--> Hyper-V host --PS Direct / scheduled task--> guest`.
Офлайн-разливка VHD (без ADK), self-driving гости (state-машины, переживают ребуты),
host-only мониторинг через KVP. Пользователь просит лабу естественным языком - ты собираешь
её из building blocks. Скиллы: `lab-build` (универсальный), `lab-ad-multisite`,
`lab-s2d-stretched`, `lab-roles`.

## Quick Start (команды выполняются из корня репо)

```bash
# выполнить PS-скрипт НА ХОСТЕ; host/blocks.ps1 подклеивается автоматически,
# токен __LAB_PW__ заменяется на $env:LAB_PW из .env
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File <script.ps1>

# статус всех VM (host-only, не виснет при загрузке гостя)
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File host/status.ps1

# скриншот консоли VM (застрявший OOBE): сохраняет C:\Lab\<vm>.png на хосте
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File host/screenshot.ps1 -ArgumentList DC01

# файлы на хост / с хоста
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hvcopy.ps1 -Source <local> -Destination 'C:\Lab\x.ps1'
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hvfetch.ps1 -Source 'C:\Lab\x.log' -Destination ./x.log
```

## Architecture

- **lib/** - `common.ps1` (Import-DotEnv из `.env`, Get-LabSession, Expand-LabTokens -
  ordinal .Replace, НЕ regex), `hv.ps1`, `hvcopy.ps1`, `hvfetch.ps1`.
- **host/blocks.ps1** - функции, доступные каждому скрипту, отправленному через `hv.ps1`:
  `New-LabNetwork`, `New-LabVM` (офлайн VHD -> unattend -> SetupComplete -> arm task; nested
  virt, data-диски), `Install-LabGuestTask` (доставка ролевого скрипта в гость + scheduled
  task через PS Direct), `Invoke-LabGuest`, `Get-LabKvpStatus`, `Get-LabScreenshot`.
- **guest/** - шаблоны bootstrap: `bootstrap_dc_forest.ps1`, `bootstrap_dc_replica.ps1`,
  `bootstrap_member.ps1`. Копируются в `labs/<lab>/guest/`, правится блок CONFIG сверху,
  стейджатся на хост (`hvcopy` в `C:\Lab\<lab>\`), путь передаётся в `New-LabVM`.
- **roles/** - ролевые state-машины (`role_adcs.ps1`, `role_iis.ps1`, `role_exchange.ps1`,
  `role_s2d_node.ps1`); деплой ТОЛЬКО через `Install-LabGuestTask` (иначе роль встанет на хост!).
- **labs/** - каталог на лабу: guest-скрипты с заполненным CONFIG + `build.ps1` + post-скрипты.

## Workflow сборки лабы

1. Спроектируй топологию (таблица: VM, IP, роль, размеры), покажи пользователю.
2. `labs/<name>/`: скопируй шаблоны guest/, заполни CONFIG (IP, домен, сайт).
3. Стейджинг: `hvcopy` guest-скриптов на хост в `C:\Lab\<name>\`.
4. `build.ps1` через `hv.ps1`: `New-LabNetwork` + `New-LabVM` (сначала DC).
5. Жди KVP-статус `<VM>|...|DONE` циклом по `host/status.ps1` (интервал 60-120 c).
6. После DC: сайты/subnets через `Invoke-LabGuest`, потом остальные VM, потом роли.

## Жёсткие правила

- **Никогда** не выполняй долгие операции через PS Direct / WinRM синхронно: всё, что
  дольше ~2 минут - scheduled task в госте + KVP-поллинг. PS Direct виснет, пока гость
  грузится (см. docs/GOTCHAS.md).
- Скрипты `.ps1` - ASCII-only, комментарии на английском. Кириллица только в `.md`.
- Секреты: только токен `__LAB_PW__` в скриптах; никогда не печатай `$env:LAB_PW`, не
  вставляй пароли в команды и не проси пользователя писать их в чат - для этого
  `scripts/creds_editor.ps1`.
- Один `New-LabVM` за раз (билдер монтирует VHD на буквы S:/W: хоста).
- Exchange 2019 ставится ТОЛЬКО на гость WS2022 (на WS2025 не поддерживается).
- S2D: гости Datacenter edition, статическая память; nested-диски -
  `Enable-ClusterStorageSpacesDirect -SkipEligibilityChecks`. "Растянутый" =
  campus (rack FD, один пул) ИЛИ stretched (site FD, пул на сайт + Storage
  Replica) - выбор топологии см. скилл lab-s2d-stretched.
- При любой странности - сначала `docs/GOTCHAS.md`, потом `host/screenshot.ps1`.

## Configuration

`.env` в корне (см. `.env.example`): `HYPERV_HOST`, `HYPERV_USER`, `HYPERV_PASS`, `LAB_PW`.
`lib/common.ps1` грузит его автоматически; отсутствие ключа - жёсткая ошибка с подсказкой
запустить `scripts/creds_editor.ps1`.

## Testing

Смоук = поднявшаяся VM: `host/status.ps1` до терминального `...|DONE`, затем проверки через
`Invoke-LabGuest` (`Get-ADDomain`, `Get-ClusterS2D` и т.п.). Юнит-тестов нет - это инфра-тулинг.

## Versioning

Semver в этом файле и README. Текущая: **0.2.0** (S2D: campus/stretched
топологии по MS Learn, role_s2d_node, эталон приёмного тракта в GOTCHAS).

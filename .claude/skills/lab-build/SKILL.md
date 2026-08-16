---
name: lab-build
description: Universal constructor - build an arbitrary Hyper-V research lab from a natural-language request (domains, DCs, sites, member servers, clusters, roles). Use whenever the user describes a lab topology to create.
---

# lab-build: универсальный конструктор лаб

Пользователь описывает лабу словами - ты собираешь её из building blocks проекта.
Специализированные рецепты: `lab-ad-multisite` (КД по сайтам + CA), `lab-s2d-stretched`
(растянутый S2D), `lab-roles` (роли поверх домена). Этот скилл - общий каркас.

## 1. Проектирование

Разбери запрос в таблицу топологии и ПОКАЖИ пользователю до сборки:

| VM | IP | ОС/Edition | RAM/CPU/Disk | Роль | Bootstrap-шаблон |
|----|----|-----------|--------------|------|------------------|

Правила выбора:
- Первый DC - всегда первый: всё остальное зависит от него.
- IP из одной подсети лабы (default `10.80.0.0/24`, gateway `.1` = хост/NAT).
- Edition `Datacenter` - только когда нужно (S2D, Storage Replica); иначе `Standard`.
- Exchange 2019 - только на госте WS2022 (`-OsVersion 2022`).
- ISO-пути на хосте спроси у пользователя или найди: `Get-ChildItem D:\ -Filter *.iso` через `hv.ps1`.
- Один домен = один лес, DSRM/admin/domain пароль везде `$env:LAB_PW` (токен `__LAB_PW__`).

## 2. Каркас лабы

```
labs/<name>/
  guest/     # копии шаблонов из guest/ с заполненным блоком CONFIG
  build.ps1  # host-side: New-LabNetwork + стейджинг-инструкции + New-LabVM ...
  post_*.ps1 # шаги после поднятия DC (сайты, роли) через Invoke-LabGuest / Install-LabGuestTask
```

Шаблоны guest: `bootstrap_dc_forest.ps1` (первый DC), `bootstrap_dc_replica.ps1`
(доп. DC, поле `$SiteName`), `bootstrap_member.ps1` (member-join). Меняй ТОЛЬКО блок
`# --- CONFIG ---`. Пароль в шаблонах - токен `__LAB_PW__`, не трогать.

## 3. Порядок выполнения (все команды из корня репо)

```bash
# 1) стейджинг guest-скриптов на хост
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hvcopy.ps1 -Source labs/<name>/guest/dc01.ps1 -Destination 'C:\Lab\<name>\dc01.ps1'

# 2) сборка (build.ps1 вызывает New-LabNetwork и New-LabVM; blocks.ps1 подклеен автоматически)
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File labs/<name>/build.ps1

# 3) мониторинг: ждать <VM>|bootstrap|DONE-* (интервал 60-120 c; Exchange - 300 c)
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File host/status.ps1
```

Строй VM ПОСЛЕДОВАТЕЛЬНО относительно билдера (New-LabVM монтирует VHD на S:/W:
хоста - один билд за раз), но ждать DONE у нескольких уже стартовавших VM можно параллельно.
Зависимости: DC-forest -> DONE -> (сайты, если нужны) -> реплики DC и members -> роли.

## 4. Жёсткие правила

- Долгие операции (промо, join, установка ролей) - НИКОГДА синхронно через
  PS Direct/WinRM: только scheduled task в госте + KVP-поллинг. PS Direct виснет,
  пока гость грузится.
- Быстрые запросы к готовому госту - `Invoke-LabGuest` (секунды, не минуты).
- Не печатай `$env:LAB_PW` и не вставляй пароли в команды/файлы - только токен.
- Застряло? `host/screenshot.ps1 -ArgumentList <VM>` + `hvfetch` PNG, и смотри
  `docs/GOTCHAS.md` по симптому. Логи гостя: `C:\Lab\bootstrap.log` в госте,
  забрать можно `Invoke-LabGuest { Get-Content C:\Lab\bootstrap.log -Tail 50 }`.
- Прервал `Install-WindowsFeature` / установку - НЕ повторяй сразу: CBS-лок,
  сначала hard power-cycle VM (см. GOTCHAS).

## 5. Верификация

После терминальных статусов - проверь лабу по её смыслу через `Invoke-LabGuest`:
`Get-ADDomain`, `Get-ADReplicationSite`, `repadmin /replsummary`, `Get-ClusterS2D`,
`Get-ExchangeServer` и т.п. Потом предложи снапшот:
`Checkpoint-VM -Name <vm> -SnapshotName baseline` (через hv.ps1).

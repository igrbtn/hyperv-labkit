# HyperVLabKit

Тулкит для headless-развёртывания исследовательских лаб на **Hyper-V (Windows Server 2022/2025)**
с рабочей станции Windows - без RDP, без консоли, без ADK/WDS. Заточен под работу в паре с
**Claude Code** (VS Code): описываешь лабу естественным языком ("подними 2 КД в разных
сайтах с отдельным CA", "собери stretched S2D кластер") - агент собирает её из building blocks.

```
Workstation --WinRM/Negotiate--> Hyper-V host --PowerShell Direct--> Windows guest
   (PS 5.1, lib/hv.ps1)             (blocks)      (scheduled task, state-машина)
```

## Ключевые приёмы

- **Офлайн-разливка VHD без ADK**: `New-VHD -> GPT (EFI/MSR/OS) -> Expand-WindowsImage ->
  bcdboot -> инъекция unattend.xml` (GVLK-ключ в specialize проскакивает OOBE product-key).
- **Self-driving гость**: `SetupComplete.cmd` регистрирует AtStartup-задачу; state-машина
  в госте доводит промо/join/установку ролей через ребуты. Никаких длинных операций по
  PS Direct - он виснет, пока гость грузится.
- **Host-only мониторинг через KVP**: гость пишет статус в реестр
  (`HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\LabStatus`), хост читает через
  `Msvm_KvpExchangeComponent`. Работает даже когда гость в OOBE/ребуте.
- **Секреты только в env**: пароль лабы живёт в `.env` (`LAB_PW`), в скриптах - токен
  `__LAB_PW__`, который `lib/hv.ps1` подставляет в рантайме. Литералов в файлах нет.

## Быстрый старт

```bash
git clone <this-repo> && cd HyperVLabKit

# 1. Креды: локальный веб-редактор .env (значения маскируются, в чат/историю не попадают)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/creds_editor.ps1

# 2. Разово: доверить WinRM-клиенту адрес хоста (если хост не в домене)
powershell -Command "Set-Item WSMan:\localhost\Client\TrustedHosts -Value '<HOST_IP>' -Concatenate -Force"

# 3. Проверка связи: статус всех VM на хосте
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File host/status.ps1
```

Дальше - открой проект в VS Code с Claude Code и попроси собрать лабу. Скиллы
(`.claude/skills/`) объяснят агенту порядок действий.

## Что внутри

| Каталог | Назначение |
|---------|-----------|
| `lib/` | обёртки: `hv.ps1` (выполнить скрипт на хосте), `hvcopy.ps1`/`hvfetch.ps1` (файлы на/с хоста), `common.ps1` (.env, сессия, токены) |
| `host/` | `blocks.ps1` - building blocks, исполняются на хосте (New-LabVM, New-LabNetwork, Install-LabGuestTask, Get-LabKvpStatus...); `status.ps1`, `screenshot.ps1` |
| `guest/` | шаблоны self-driving bootstrap для гостей: первый DC (лес), реплика DC (сайт), member-join |
| `roles/` | ролевые state-машины поверх домена: AD CS, IIS, Exchange 2019, S2D-нода |
| `labs/` | по каталогу на лабу (генерирует Claude); `example-ad-multisite/` - рабочий пример |
| `scripts/` | `creds_editor.ps1` - локальный веб-редактор `.env` |
| `docs/` | `GOTCHAS.md` - грабли headless-развёртывания, набитые на практике. Читать при любой проблеме |
| `.claude/` | настройки и скиллы для Claude Code |

## Требования

- Хост: Windows Server 2022/2025 c ролью Hyper-V, включённый WinRM, ISO-образы ОС на диске.
- Рабочая станция: Windows 10/11, Windows PowerShell 5.1 (встроен), VS Code + Claude Code.
- VM кладите на быстрый NVMe: CBS-тяжёлые установки (Exchange) на QLC-дисках умирают
  (см. `docs/GOTCHAS.md`).

## Безопасность (прочитать)

- Это **лабораторный** тулкит: пароль администратора в открытом виде попадает внутрь VHD
  (unattend.xml) и в guest-скрипты. Не использовать паттерн для продуктивных систем.
- `.env` в `.gitignore`; `.claude/settings.json` запрещает агенту читать `.env`.
- Пароль `LAB_PW`: латиница, цифры и `@ # % ^ * ( ) - _ + = . ,`. Без кавычек, `;`, `$`
  и бэктика - он подставляется в PS-строки и XML.

## Версия

0.2.0 - S2D: развилка campus (rack-aware) / stretched (Storage Replica) по актуальной
документации WS2025, роль подготовки ноды, эталон RSS/VMQ/VMMQ для физических хостов
в GOTCHAS. 0.1.0 - первый срез: building blocks, AD multi-site, роли AD CS/IIS/Exchange.

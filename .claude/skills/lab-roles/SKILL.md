---
name: lab-roles
description: Add server roles to an existing lab domain - Exchange 2019, AD CS, IIS, SQL Server, or a custom role. Use for "install X on VM Y" requests on a running lab.
---

# lab-roles: роли поверх домена

Единый механизм: ролевой скрипт (state-машина) стейджится на хост и доставляется
в гость через `Install-LabGuestTask` (PS Direct -> scheduled task -> KVP-статусы).
НИКОГДА не запускай role-скрипт через `hv.ps1` напрямую - он исполнится на
Hyper-V ХОСТЕ и поставит роль туда.

## Общий паттерн

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hvcopy.ps1 -Source labs/<lab>/role_x.ps1 -Destination 'C:\Lab\<lab>\role_x.ps1'
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File labs/<lab>/deploy_role_x.ps1
```
где deploy_role_x.ps1 - одна команда:
```powershell
Install-LabGuestTask -VMName SRV01 -ScriptHostPath 'C:\Lab\<lab>\role_x.ps1' `
    -TaskName 'Lab-Role-X' -User 'RESEARCH\Administrator' -Password '__LAB_PW__'
```
Права: роли, трогающие AD (AD CS Enterprise, Exchange prep) - только domain admin.
Локальные роли (IIS) - можно `-AsSystem -User '.\Administrator'`.
Готовность - KVP `<tag>|role-*|DONE-*` через `host/status.ps1`.

## Готовые роли (roles/)

- **role_adcs.ps1** - Enterprise Root CA. CONFIG: `$VmTag`, `$CaName`. Домен-джойн
  обязателен, деплой под domain admin. DONE за ~2 мин.
- **role_iis.ps1** - IIS. CONFIG: `$VmTag`, `$Features`. Можно -AsSystem.
- **role_exchange.ps1** - Exchange 2019 Mailbox. Прочитай шапку файла: гость ТОЛЬКО
  WS2022; Exchange ISO примонтировать как DVD ДО деплоя (Add-VMDvdDrive через hv.ps1,
  затем FirstBootDevice обратно на VHD!); state-машина features -> reboot -> prereqs ->
  reboot -> prepinstall; полный цикл 40-60 мин, поллинг раз в 5 мин; нужен интернет
  через NAT (vcredist/URL Rewrite). Перед повторной попыткой на том же AD - вычистить
  arbitration-мейлбоксы (docs/GOTCHAS.md, раздел Exchange - главная засада).

## SQL Server (нет готового скрипта - генерируй по паттерну)

Скопируй скелет role_iis.ps1 (Log/Status/Disable-Task) и внутри:
1. ISO SQL как DVD (или скачай в гость), `setup.exe /ConfigurationFile=` с ConfigurationFile.ini:
   `ACTION="Install"`, `FEATURES=SQLENGINE`, `INSTANCENAME=MSSQLSERVER`,
   `SQLSYSADMINACCOUNTS="RESEARCH\Administrator"`, `IACCEPTSQLSERVERLICENSETERMS="True"`,
   `/QUIET="True"`. Статусы до/после, exit-code в лог.
2. SQL setup сам ставит prereqs; ребут между шагами обычно не нужен, но проверяй
   exit 3010 (= нужен reboot, потом resume).

## Свой role-скрипт (чек-лист скелета)

1. Шапка-комментарий: как деплоить, каким аккаунтом, какой терминальный статус.
2. CONFIG-блок с `$VmTag`.
3. Функции Log/Status (KVP `LabStatus`, формат `<tag>|role-<x>|<state>`).
4. State-файл, если есть ребуты; следующий state писать ДО ребута.
5. Идемпотентность: если роль уже стоит - сразу DONE.
6. В конце: `Disable-ScheduledTask -TaskName '<своё имя>'`, терминальный `...|DONE-*`.
7. ASCII-only, пароль - только токен `__LAB_PW__`.

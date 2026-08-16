---
name: lab-ad-multisite
description: Build N domain controllers across AD sites plus an optional separate Enterprise CA. Use for requests mentioning AD sites, site replication, multi-DC topologies, or a standalone CA.
---

# lab-ad-multisite: КД по сайтам + отдельный CA

Рецепт поверх `lab-build` (прочитай его каркас). Пример запроса: "2 КД в разных
сайтах с отдельным CA".

## Топология (референс)

| VM | IP | Шаблон | Примечание |
|----|----|--------|------------|
| DC01 | 10.80.0.10 | bootstrap_dc_forest | лес, Site-A (переименованный Default-First-Site-Name) |
| DC02 | 10.80.1.10 | bootstrap_dc_replica | `$SiteName='Site-B'` |
| CA01 | 10.80.0.20 | bootstrap_member | затем roles/role_adcs.ps1 |

Сайты в лабе - логические (один vSwitch): разделение делается объектами
subnet/site в AD, реальный L3 не нужен. Держи IP разных "сайтов" в разных /24
внутри одного switch (маску у гостей можно оставить /16, чтобы был L2-реаче,
или /24 + один gateway - для лабы AD-репликации достаточно /24 и общего шлюза).

## Порядок

1. `New-LabNetwork` + build DC01 (bootstrap_dc_forest). Ждать `DC01|bootstrap|DONE-forest`.
2. **Сайты ДО промо реплики** (иначе `-SiteName` упадёт) - через `Invoke-LabGuest` на DC01:

```powershell
Invoke-LabGuest -VMName DC01 -User 'RESEARCH\Administrator' -Password '__LAB_PW__' -ScriptBlock {
    Get-ADReplicationSite 'Default-First-Site-Name' -ErrorAction SilentlyContinue |
        Rename-ADObject -NewName 'Site-A'
    New-ADReplicationSite -Name 'Site-B'
    New-ADReplicationSubnet -Name '10.80.0.0/24' -Site 'Site-A'
    New-ADReplicationSubnet -Name '10.80.1.0/24' -Site 'Site-B'
    Set-ADReplicationSiteLink 'DEFAULTIPSITELINK' -SitesIncluded @{Add='Site-B'} -ReplicationFrequencyInMinutes 15
}
```

3. Build DC02 (bootstrap_dc_replica, `$SiteName='Site-B'`, `$DnsServer=10.80.0.10`).
   Ждать `DC02|bootstrap|DONE-dc`.
4. Build CA01 (bootstrap_member). Ждать `CA01|bootstrap|DONE-joined`.
5. CA: стейджинг `roles/role_adcs.ps1` (правь CONFIG: `$VmTag`, `$CaName`) на хост,
   затем в build/post-скрипте:

```powershell
Install-LabGuestTask -VMName CA01 -ScriptHostPath 'C:\Lab\<name>\role_adcs.ps1' `
    -TaskName 'Lab-Role-ADCS' -User 'RESEARCH\Administrator' -Password '__LAB_PW__'
```

Ждать `CA01|role-adcs|DONE-adcs`. Деплой роли - ТОЛЬКО через Install-LabGuestTask
(запуск role-скрипта через hv.ps1 поставит CA на Hyper-V хост!).

## Верификация

```powershell
Invoke-LabGuest ... { Get-ADReplicationSite -Filter * | Select Name }
Invoke-LabGuest ... { repadmin /replsummary }
Invoke-LabGuest ... { certutil -config - -ping }   # на CA01
```

Грабли: шаблон сертификата WebServer по умолчанию не даёт Enroll обычным
участникам - см. docs/GOTCHAS.md (AD CS).

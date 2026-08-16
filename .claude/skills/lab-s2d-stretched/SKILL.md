---
name: lab-s2d-stretched
description: Build a stretched Storage Spaces Direct cluster - two logical sites, nested-virt nodes with data disks, file-share witness, Enable-ClusterStorageSpacesDirect. Use for S2D, failover cluster, or storage replica lab requests.
---

# lab-s2d-stretched: растянутый S2D кластер

Рецепт поверх `lab-build`. Пример запроса: "собери stretched S2D кластер".

## Требования (не обсуждаются)

- Гости - **Datacenter** edition (`-Edition Datacenter`): S2D и Storage Replica
  есть только там. WS2025 ок.
- Ноды: `-EnableNestedVirt` (ExposeVirtualizationExtensions + MacAddressSpoofing;
  статическая память билдер ставит всегда), RAM >= 8GB/нода, `-DataDiskSizesGB @(60,60)`
  (минимум 2 data-диска на ноду).
- Stretched = 2 "сайта" x 2 ноды = **4 ноды** минимум + DC (может нести witness-шару).
  Если хосту тесно, предложи обычный (не stretched) 2-нодовый S2D.
- AD-сайты Site-A/Site-B должны существовать и subnets назначены (см. lab-ad-multisite
  шаг 2) - fault domains кластера мапятся на сайты.

## Топология (референс)

| VM | IP | Шаблон | Параметры New-LabVM |
|----|----|--------|---------------------|
| DC01 | 10.80.0.10 | bootstrap_dc_forest | Standard |
| S2D1 | 10.80.0.31 | bootstrap_member | Datacenter, Nested, DataDisks 2x60 |
| S2D2 | 10.80.0.32 | bootstrap_member | -- " -- |
| S2D3 | 10.80.1.31 | bootstrap_member | -- " -- |
| S2D4 | 10.80.1.32 | bootstrap_member | -- " -- |

## Порядок

1. DC01 -> DONE-forest; сайты Site-A/Site-B + subnets (lab-ad-multisite, шаг 2).
2. Ноды по очереди через New-LabVM, ждать `...|DONE-joined` у всех четырёх.
3. Фичи на всех нодах (быстро, можно Invoke-LabGuest по очереди):
```powershell
Invoke-LabGuest -VMName S2D1 ... { Install-WindowsFeature Failover-Clustering, FS-FileServer -IncludeManagementTools; Restart-Computer -Force }
```
   (после ребута дождись, пока VM поднимется - poll host/status.ps1 / Get-VM Uptime).
4. Witness-шара на DC01: `New-Item C:\Witness; New-SmbShare -Name Witness -Path C:\Witness -FullAccess 'RESEARCH\Domain Admins','RESEARCH\CLUSTER1$'` (доступ компьютер-аккаунту кластера добавь после создания кластера).
5. Формирование кластера - это минуты, но допустимо через Invoke-LabGuest с одной ноды
   (домен уже жив; если хочешь надёжнее - оформи как role-скрипт через Install-LabGuestTask):
```powershell
Invoke-LabGuest -VMName S2D1 -User 'RESEARCH\Administrator' -Password '__LAB_PW__' -ScriptBlock {
    Test-Cluster -Node S2D1,S2D2,S2D3,S2D4 -Include 'Storage Spaces Direct','Inventory','Network','System Configuration'
    New-Cluster -Name CLUSTER1 -Node S2D1,S2D2,S2D3,S2D4 -StaticAddress 10.80.0.40 -NoStorage
    # fault domains = сайты (stretched)
    New-ClusterFaultDomain -Name 'Site-A' -Type Site
    New-ClusterFaultDomain -Name 'Site-B' -Type Site
    Set-ClusterFaultDomain -Name S2D1 -Parent 'Site-A'
    Set-ClusterFaultDomain -Name S2D2 -Parent 'Site-A'
    Set-ClusterFaultDomain -Name S2D3 -Parent 'Site-B'
    Set-ClusterFaultDomain -Name S2D4 -Parent 'Site-B'
    Set-ClusterQuorum -FileShareWitness '\\DC01\Witness'
    # nested/virtual disks fail eligibility (MediaType Unspecified) - skip checks in a lab
    Enable-ClusterStorageSpacesDirect -Confirm:$false -SkipEligibilityChecks -CacheState Disabled
}
```
6. Тома: в stretched-кластере S2D сам создаёт пулы per-site; тома с репликацией
   создавай через `New-Volume` с `-ProtectionLevel` / Storage Replica
   (`Get-ClusterFaultDomain` должен показывать 2 сайта с нодами). Простой smoke:
   `New-Volume -FriendlyName Vol1 -Size 20GB -FileSystem CSVFS_ReFS` на пуле Site-A.

## Верификация и грабли

- `Get-ClusterS2D`, `Get-StoragePool`, `Get-ClusterFaultDomain`, `Get-VirtualDisk`.
- Test-Cluster может ругаться на сеть (один адаптер) - для лабы допустимо.
- Динамическая память на нодах ломает S2D - билдер всегда ставит StaticMemory, не меняй.
- Чекпоинты на нодах S2D не делать (виртуальные диски в пуле); baseline-снапшот -
  только ДО Enable-ClusterStorageSpacesDirect или на выключенном кластере.

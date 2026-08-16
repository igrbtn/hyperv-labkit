---
name: lab-s2d-stretched
description: Build a stretched or campus (rack-aware) Storage Spaces Direct cluster - fault domains, nested-virt nodes with data disks, witness, Enable-ClusterStorageSpacesDirect, Storage Replica volumes. Use for S2D, failover cluster, or storage replica lab requests.
---

# lab-s2d-stretched: растянутый S2D кластер

Рецепт поверх `lab-build`. На WS2025 "растянутый" S2D бывает ДВУХ видов - сначала
выбери с пользователем топологию:

| | **Campus (rack-aware)** - рекомендуется для лабы | **Stretched (site)** |
|---|---|---|
| Fault domains | 2 x `-Type Rack` | 2 x `-Type Site` (AD-сайты) |
| Пул | ОДИН на кластер | по пулу НА САЙТ |
| Репликация томов | Rack Level Nested Mirror (2/4 копии), без SR | Storage Replica (sync <5ms RTT) |
| Требования | WS2025 + декабрьский CU 2025 (KB5072033)+ | Datacenter (SR), фича Storage-Replica |
| Сложность в лабе | ниже | выше (SR-партнёрства руками) |

Campus проще и без Storage Replica - для исследования "переживёт ли кластер потерю
стойки/сайта" его обычно достаточно. Stretched - когда исследуется именно SR/DR.

## Требования к нодам (обе топологии)

- Гости - **Datacenter** edition (`-Edition Datacenter`), WS2025.
- `-DataDiskSizesGB @(60,60)` минимум (2 data-диска на ноду), RAM >= 8GB/нода.
- `-EnableNestedVirt` - только если ноды будут сами крутить VM (hyper-converged,
  `$WithHyperV = $true` в role_s2d_node); для чисто storage-лабы не обязателен.
  Статическую память билдер ставит всегда - для S2D это требование, не менять.
- 2+2 = 4 ноды (кампус поддерживает и 1+1 с nested two-way mirror - минимальная лаба).
- AD-сайты Site-A/Site-B нужны только для stretched (см. lab-ad-multisite, шаг 2).

## Порядок

1. DC01 -> `DONE-forest` (для stretched - ещё сайты/subnets).
2. Ноды через `New-LabVM` по очереди, ждать `...|DONE-joined` у всех.
3. Фичи кластеризации на всех нодах - через роль (fire-and-forget, с ребутом):
```powershell
Install-LabGuestTask -VMName S2D1 -ScriptHostPath 'C:\Lab\<lab>\role_s2d_node.ps1' `
    -TaskName 'Lab-Role-S2DNode' -User 'RESEARCH\Administrator' -Password '__LAB_PW__'
```
   (CONFIG в копии role_s2d_node.ps1 на каждую ноду: свой `$VmTag`). Ждать
   `<tag>|role-s2dnode|DONE-s2dnode` у всех четырёх.
4. Кластер (минуты, домен жив - допустим Invoke-LabGuest с первой ноды):
```powershell
Invoke-LabGuest -VMName S2D1 -User 'RESEARCH\Administrator' -Password '__LAB_PW__' -ScriptBlock {
    Test-Cluster -Node S2D1,S2D2,S2D3,S2D4 -Include 'Storage Spaces Direct','Inventory','Network','System Configuration'
    New-Cluster -Name CLUSTER1 -Node S2D1,S2D2,S2D3,S2D4 -StaticAddress 10.80.0.40 -NoStorage
}
```
5. Fault domains - ПОСЛЕ New-Cluster, ДО Enable-ClusterS2D:
```powershell
# campus:   -Type Rack (Rack-A/Rack-B)
# stretched: -Type Site (Site-A/Site-B)
New-ClusterFaultDomain -Name 'Rack-A' -Type Rack
New-ClusterFaultDomain -Name 'Rack-B' -Type Rack
Set-ClusterFaultDomain -Name S2D1 -Parent 'Rack-A'
Set-ClusterFaultDomain -Name S2D2 -Parent 'Rack-A'
Set-ClusterFaultDomain -Name S2D3 -Parent 'Rack-B'
Set-ClusterFaultDomain -Name S2D4 -Parent 'Rack-B'
```
6. Witness - шара НЕ на нодах кластера. Права кластерному аккаунту выдаются
   ПОСЛЕ New-Cluster (до него `CLUSTER1$` не существует). По-хорошему witness
   должен жить в третьем месте (не в одном из двух fault domain); DC01 в лабе -
   осознанный компромисс:
```powershell
# на DC01 (Invoke-LabGuest):
New-Item -ItemType Directory -Force -Path C:\Witness
New-SmbShare -Name Witness -Path C:\Witness -FullAccess 'RESEARCH\Domain Admins','RESEARCH\CLUSTER1$'
# на S2D1:
Set-ClusterQuorum -FileShareWitness '\\DC01\Witness'
```
7. S2D:
```powershell
# nested/virtual диски проваливают eligibility (MediaType Unspecified) - в лабе пропускаем
Enable-ClusterStorageSpacesDirect -Confirm:$false -SkipEligibilityChecks -CacheState Disabled
```
   - campus: получится один пул; тома с нужной живучестью:
     `New-Volume -FriendlyName Vol1 -Size 20GB -FileSystem CSVFS_ReFS -ResiliencySettingName Mirror -PhysicalDiskRedundancy 3`
     (4 копии = переживает стойку+ноду; 2 копии - `-PhysicalDiskRedundancy 1`).
   - stretched: пул НА КАЖДЫЙ сайт; для stretched заранее добавь `Storage-Replica`
     в `$Features` роли role_s2d_node (по умолчанию её там нет). Том + лог-том
     в пуле каждого сайта, затем партнёрство:
     `New-SRPartnership -SourceComputerName S2D1 -SourceRGName rg01 -SourceVolumeName C:\ClusterStorage\Vol1 -SourceLogVolumeName L: -DestinationComputerName S2D3 -DestinationRGName rg02 ...`
     (внутри одного кластера - stretch-режим SR).

## Верификация

`Get-ClusterS2D`, `Get-StoragePool`, `Get-ClusterFaultDomain`, `Get-VirtualDisk`,
для stretched - `Get-SRPartnership`. Смоук отказоустойчивости: `Stop-VM -Force`
обеих нод одного fault domain -> CSV должен переехать и остаться online.

## Грабли

- Test-Cluster ругается на один сетевой адаптер - для лабы допустимо.
- Динамическая память ломает S2D - билдер ставит StaticMemory, не менять.
- Чекпоинты Hyper-V на нодах с дисками в пуле не делать; baseline-снапшот - только
  ДО Enable-ClusterStorageSpacesDirect или на выключенном кластере.
- Campus cluster требует WS2025 с CU от декабря 2025 (KB5072033) или новее -
  проверь билд ISO (`Get-WindowsImage`), при старом - поставь CU или бери stretched.
- Тюнинг RSS/VMQ/VMMQ внутри nested-нод не имеет смысла (нет аппаратных очередей);
  для ФИЗИЧЕСКИХ S2D-хостов см. docs/GOTCHAS.md, раздел "Приёмный тракт".

# GOTCHAS - грабли headless-развёртывания, набитые на практике

Каждый пункт стоил часов отладки. Проверено на WS2022-хосте; на WS2025 поведение
ожидаемо то же (отдельно отмечено, где важна версия).

## OOBE / офлайн-разливка Windows

- **OOBE product-key блокирует ВСЁ.** Retail ISO упирается в экран ввода ключа;
  `SetupComplete.cmd` НЕ запускается, пока OOBE не завершён - любой self-driving
  сценарий стоит намертво (чёрный экран, CPU 0, без ребута). **Фикс:** GVLK-ключ
  в pass `specialize` (компонент Microsoft-Windows-Shell-Setup). Это публичные
  KMS client-ключи из документации Microsoft: ничего не активируют, только
  проскакивают страницу. Таблица ключей - в `host/blocks.ps1` (`$LabGvlk`,
  WS2022/WS2025 x Standard/Datacenter). "Do this later" вручную НЕ помогает.

- **Офлайн-разливка без ADK/WDS:** `New-VHD -Dynamic` -> `Mount-VHD` -> GPT
  (EFI 260MB FAT32 + MSR 16MB + OS NTFS) -> `Expand-WindowsImage -Index N` ->
  `bcdboot W:\Windows /s S: /f UEFI` -> инъекция `W:\Windows\Panther\unattend.xml`.
  Gen2 VM, SecureBoot MicrosoftWindows template. Индекс образа проверяй:
  `Get-WindowsImage -ImagePath <iso>:\sources\install.wim` (обычно 2 = Standard
  Desktop Experience, 4 = Datacenter Desktop Experience).

- **`SetupComplete.cmd` не должен делать тяжёлую CBS-работу** (Install-WindowsFeature
  и т.п.): он выполняется в pre-login фазе и дедлочит. Только регистрация
  AtStartup-задачи (arm.ps1), вся работа - из задачи после старта системы.

## PS Direct / WinRM / servicing

- **PS Direct виснет намертво**, пока гость грузится/ребутится/в OOBE (ошибка
  "The Hyper-V socket target process has ended"). Убить залипший runspace нельзя.
  **Правило:** длинные операции - только fire-and-forget (scheduled task в госте),
  статус - host-only через KVP.

- **Прерывание `Install-WindowsFeature` залочивает CBS/TrustedInstaller** -
  следующая установка встаёт на локе (CPU 0, тишина). Лечится hard power-cycle
  (`Stop-VM -Force` + `Start-VM`) - CBS откатывает на загрузке. **Никогда не
  рубить servicing по таймауту.**

- **QLC-SSD = смерть для CBS-тяжёлых установок.** Exchange install на медленном
  диске давал таймауты создания IIS-vdir (~10 c на fsync). VM класть на быстрый NVMe.

## Host-only мониторинг (KVP)

- Гость пишет статус в `HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest` (значение
  `LabStatus`); хост читает через `Msvm_KvpExchangeComponent.GuestExchangeItems`.
  Не виснет, PS Direct не нужен. `GuestIntrinsicExchangeItems` - FQDN/OSName гостя.
  Формат статуса в этом ките: `<VMTAG>|<phase>|<state>`, терминальный - `...|DONE-*`.
- Скрин застрявшего OOBE с хоста: `Msvm_VirtualSystemManagementService.
  GetVirtualSystemThumbnailImage` (RGB565 -> Bitmap). См. `host/screenshot.ps1`.

## AD CS

- **Шаблон `WebServer` по умолчанию не даёт Enroll** обычным компьютерам/юзерам
  (`certutil -CATemplates` -> "Access is denied"). Для выписки через certreq выдать
  Enroll на шаблон (ACE с extended-right GUID `0e10c968-78fb-11d2-90d4-00c04f79dc55`)
  или выписывать под Enterprise Admin.

## AD multi-site

- **AD-сайт должен существовать ДО `Install-ADDSDomainController -SiteName`** -
  иначе промо падает. Порядок: лес -> New-ADReplicationSite/Subnet -> реплика.
- Сайты в лабе - логические объекты AD; реальный L3 между "сайтами" не нужен,
  достаточно разных subnet-объектов, привязанных к сайтам.

## S2D / кластеры (nested)

- Ноды: Datacenter edition, **статическая память** (динамическая ломает S2D);
  nested virt (`ExposeVirtualizationExtensions` + MacAddressSpoofing) - только
  если ноды сами крутят VM (hyper-converged).
- **"Растянутый" S2D на WS2025 - две разные топологии** (Microsoft Learn,
  failover-clustering/topologies). Не смешивать:
  - **Campus (rack-aware)**: 2 fault domain `-Type Rack`, ОДИН пул, тома
    Rack Level Nested Mirror (2/4 копии), БЕЗ Storage Replica. Требует WS2025 +
    CU от декабря 2025 (KB5072033). Для лабы обычно достаточно его.
  - **Stretched (site)**: 2 fault domain `-Type Site` (AD-сайты), пул НА САЙТ,
    тома реплицирует Storage Replica (sync <5ms RTT, фича Storage-Replica,
    Datacenter). SR-партнёрства настраиваются руками.
- **Witness - в третьем месте**, не в одном из двух fault domain (иначе потеря
  "сайта" с witness кладёт кворум). Права на шару кластерному аккаунту
  (`DOMAIN\CLUSTER1$`) выдавать ПОСЛЕ New-Cluster - до него аккаунта нет.
- Fault domains создавать ПОСЛЕ New-Cluster и ДО Enable-ClusterStorageSpacesDirect.
- Виртуальные data-диски проваливают eligibility-check (MediaType Unspecified):
  в лабе `Enable-ClusterStorageSpacesDirect -SkipEligibilityChecks -CacheState Disabled`.
- Чекпоинты Hyper-V на нодах с дисками в пуле - способ убить пул.

## Приёмный тракт ФИЗИЧЕСКОГО хоста (RSS/VMQ/VMMQ)

К nested-гостям не применимо (нет аппаратных очередей). Для физических
Hyper-V/S2D хостов - краткий эталон, чтобы не наступать на типовые грабли:

- **Ядро 0 не несёт очередей**: на нём default queue и прерывания ОС.
  `Set-NetAdapterRss -BaseProcessorNumber 2` (при HT RSS и так берёт по одному
  LP на физическое ядро).
- **Номера процессоров - относительно processor group.** На машинах >64 LP Windows
  режет LP на группы по NUMA-нодам; RSS не пересекает границу группы. Задавать
  `-BaseProcessorGroup/-MaxProcessorGroup` явно, диапазоны считать на хосте от
  группы/NUMA порта, а не таблицей абсолютных чисел.
- **Профиль `ClosestStatic`**, не `Closest`: динамический профиль пересчитывает
  indirection-таблицу на ходу. Числовое значение advanced-ключворда `*RSSProfile`
  для ClosestStatic = 2 (1 = Closest), но надёжнее `Set-NetAdapterRss -Profile`.
  Driver advanced properties и Set-NetAdapterRss пишут одни и те же registry-ключи -
  побеждает написавший последним; два источника истины = разъехавшийся конфиг.
- **VMQ-диапазон порта = RSS-диапазон порта**; каждому порту - свой непересекающийся
  блок ядер своей NUMA-ноды; vNIC пинится к порту через Set-VMNetworkAdapterTeamMapping
  и живёт в блоке своего порта.
- **VmmqQueuePairs**: фактическое число выдаёт система (requested vs actual в
  `Get-VMNetworkAdapter`). Задавать requested явно и выравнивать с
  `DefaultQueueVmmqQueuePairs` на свитче, иначе значения плавают между хостами.
- **RDMA (SMB Direct) идёт МИМО RSS/VMQ/VMMQ**: для S2D-storage главный рычаг -
  DCB/PFC и единый DcbxMode на всех портах всех узлов, а не VMMQ-пары. RSS-тюнинг
  vNIC влияет на TCP-фазу и fallback.
- **SR-IOV и VMMQ на одном vPort взаимоисключающи**; SR-IOV на порту при
  `IovEnabled False` на свитче - мёртвое свойство, выключить.
- **PacketDirect выключать** - потребителей интерфейса нет, только резервирует
  очереди и буферы.

## Exchange 2019 (каждый пункт стоил ночи)

- **Только гость WS2022.** Exchange 2019 не поддерживается на WS2025.
- **RebootPending.** Prereq-инсталляторы (VC++, URL Rewrite, UCMA) ставят
  pending-reboot. Если `Setup /PrepareSchema` идёт сразу после них - ВСЕ prep-шаги
  падают exit=1 (Rule:RebootPending), org не создаётся, каскад "org name required".
  **Фикс:** reboot между prereqs и prep (в `roles/role_exchange.ps1` уже так).
- **UCMA 4.0 не ставится через `Setup.exe /q`** - это bootstrapper: спавнит
  установщик и сразу возвращается (`-Wait` - no-op). Прямой msiexec блокирован
  LaunchCondition. Рабочий способ: `SpeechPlatformRuntime.msi`, затем bootstrapper
  `/passive` + опрос реестра Uninstall до появления "...Core Runtime".
- **"Database is mandatory on UserMailbox"** - главная маскирующаяся ошибка.
  В `CN=Users` копятся дубликаты arbitration-мейлбоксов (SystemMailbox{*},
  FederatedEmail.*, Migration.*, DiscoverySearchMailbox{*}) от каждого прошлого
  PrepareAD с пустым `msExchHomeMDB`. Снос org-контейнера их НЕ трогает. **Фикс:**
  ```powershell
  Get-ADObject -LDAPFilter '(|(cn=SystemMailbox*)(cn=FederatedEmail*)(cn=Migration.*)(cn=DiscoverySearchMailbox*))' `
      -SearchBase 'DC=<your>,DC=<lab>' | Remove-ADObject -Recursive
  ```
  и свежий PrepareAD создаёт чистый набор.
- **Частичный install оставляет MailboxRole watermark** (`HKLM:\...\ExchangeServer\
  v15\*Role\Watermark`) - блокирует даже PrepareSchema. role_exchange.ps1 чистит
  его перед install.
- **Урок:** не чистить AD по кускам между попытками. Чистый путь = fresh VM +
  полностью пустой AD + один непрерывный install.
- Prereq-URLы Microsoft не пиннятся и без чексумм - если качается мусор/404,
  проверь URL руками (документированный риск).

## Общее

- **ASCII-only** в `.ps1`/конфигах: парсеры ломаются на не-ASCII. Кириллица - только в `.md`.
- **Секреты - только env** (`.env`, токен `__LAB_PW__`, ordinal `.Replace`).
  Литералов паролей в файлах нет. Но помни: пароль в открытом виде оказывается
  ВНУТРИ VHD (unattend.xml, bootstrap.ps1) - это лабораторный компромисс.
- Подстановка токена - строго ordinal `String.Replace()`, не `-replace` (regex
  сожрёт `$`/спецсимволы пароля). Запрещённые символы в LAB_PW: кавычки, `;`,
  бэктик, `<`, `>`, `&` (валидируется в lib/common.ps1).

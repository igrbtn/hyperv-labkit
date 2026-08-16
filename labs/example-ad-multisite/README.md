# Пример: 2 КД в разных AD-сайтах + отдельный CA

Рабочий референс для скилла `lab-ad-multisite`. Домен `research.lab`, подсеть
`10.80.0.0/16` (Site-A = 10.80.0.x, Site-B = 10.80.1.x), switch `Lab Internal`.

| VM | IP | Роль |
|----|----|------|
| DC01 | 10.80.0.10 | лес research.lab, Site-A |
| DC02 | 10.80.1.10 | реплика DC, Site-B |
| CA01 | 10.80.0.20 | member + Enterprise Root CA |

Перед запуском поправь в `build.ps1` пути к ISO (`$Iso`) и каталогу VM (`$VMDir`)
под свой хост.

## Запуск (из корня репо)

```bash
# 1. guest-скрипты на хост
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hvcopy.ps1 -Source labs/example-ad-multisite/guest/dc01.ps1 -Destination 'C:\Lab\example\dc01.ps1'
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hvcopy.ps1 -Source labs/example-ad-multisite/guest/dc02.ps1 -Destination 'C:\Lab\example\dc02.ps1'
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hvcopy.ps1 -Source labs/example-ad-multisite/guest/ca01.ps1 -Destination 'C:\Lab\example\ca01.ps1'
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hvcopy.ps1 -Source roles/role_adcs.ps1 -Destination 'C:\Lab\example\role_adcs.ps1'

# 2. сеть + DC01
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File labs/example-ad-multisite/build.ps1 -ArgumentList dc01
# ждать DC01|bootstrap|DONE-forest:
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File host/status.ps1

# 3. сайты (после DONE-forest)
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File labs/example-ad-multisite/post_sites.ps1

# 4. DC02 и CA01 (последовательно; ждать DONE-dc / DONE-joined)
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File labs/example-ad-multisite/build.ps1 -ArgumentList dc02
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File labs/example-ad-multisite/build.ps1 -ArgumentList ca01

# 5. CA роль (после CA01|bootstrap|DONE-joined); ждать CA01|role-adcs|DONE-adcs
powershell -NoProfile -ExecutionPolicy Bypass -File lib/hv.ps1 -File labs/example-ad-multisite/post_ca.ps1
```

guest/*.ps1 - копии шаблонов из `guest/` с заполненным CONFIG-блоком (это
единственное отличие от шаблонов).

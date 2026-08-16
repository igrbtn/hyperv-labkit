# Print State|LabStatus for every VM on the host (or the ones passed as args).
# Host-only via KVP - safe to poll while guests boot/promote/install.
# Usage: powershell ... -File lib/hv.ps1 -File host/status.ps1 [-ArgumentList DC01,DC02]
if ($args.Count -gt 0) { Get-LabKvpStatus -VMName $args } else { Get-LabKvpStatus }

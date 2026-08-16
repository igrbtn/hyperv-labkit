# Console screenshot of a VM (stuck OOBE etc). Saves C:\Lab\<vm>.png on the host.
# Usage: powershell ... -File lib/hv.ps1 -File host/screenshot.ps1 -ArgumentList DC01
# Then:  powershell ... -File lib/hvfetch.ps1 -Source 'C:\Lab\DC01.png' -Destination ./DC01.png
if ($args.Count -lt 1) { throw 'usage: screenshot.ps1 <VMName>' }
Get-LabScreenshot -VMName $args[0]

# Example lab: 2 DCs in different AD sites + separate CA.
# Runs ON the host via lib/hv.ps1 (blocks.ps1 prepended). Builds ONE VM per
# invocation: pass which one as an argument (dc01 | dc02 | ca01).
# EDIT $Iso and $VMDir for your host before first run.

$Iso   = 'D:\Install\ws2025.iso'    # Windows Server 2025 ISO on the host
$VMDir = 'C:\VMs'                   # fast NVMe
$Switch = 'Lab Internal'

$target = if ($args.Count -gt 0) { [string]$args[0] } else { 'dc01' }

New-LabNetwork -SwitchName $Switch -Subnet '10.80.0.0/16' -GatewayIP '10.80.0.1'

switch ($target) {
    'dc01' {
        New-LabVM -Name DC01 -VMDir $VMDir -SwitchName $Switch -IsoPath $Iso `
            -SizeGB 80 -RamGB 6 -Cpu 2 -OsVersion 2025 -Edition Standard `
            -AdminPassword '__LAB_PW__' -BootstrapHostPath 'C:\Lab\example\dc01.ps1'
    }
    'dc02' {
        New-LabVM -Name DC02 -VMDir $VMDir -SwitchName $Switch -IsoPath $Iso `
            -SizeGB 80 -RamGB 4 -Cpu 2 -OsVersion 2025 -Edition Standard `
            -AdminPassword '__LAB_PW__' -BootstrapHostPath 'C:\Lab\example\dc02.ps1'
    }
    'ca01' {
        New-LabVM -Name CA01 -VMDir $VMDir -SwitchName $Switch -IsoPath $Iso `
            -SizeGB 60 -RamGB 4 -Cpu 2 -OsVersion 2025 -Edition Standard `
            -AdminPassword '__LAB_PW__' -BootstrapHostPath 'C:\Lab\example\ca01.ps1'
    }
    default { throw "unknown target '$target' (dc01|dc02|ca01)" }
}

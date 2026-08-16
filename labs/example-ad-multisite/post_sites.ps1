# After DC01|bootstrap|DONE-forest: rename default site, create Site-B,
# bind subnets, add Site-B to the default site link. MUST run before DC02
# promotes with -SiteName. Short PS Direct calls are fine here - DC is up.
Invoke-LabGuest -VMName DC01 -User 'RESEARCH\Administrator' -Password '__LAB_PW__' -ScriptBlock {
    Import-Module ActiveDirectory
    $def = Get-ADReplicationSite -Filter "Name -eq 'Default-First-Site-Name'" -ErrorAction SilentlyContinue
    if ($def) { Rename-ADObject -Identity $def.DistinguishedName -NewName 'Site-A' }
    if (-not (Get-ADReplicationSite -Filter "Name -eq 'Site-B'")) { New-ADReplicationSite -Name 'Site-B' }
    if (-not (Get-ADReplicationSubnet -Filter "Name -eq '10.80.0.0/24'")) { New-ADReplicationSubnet -Name '10.80.0.0/24' -Site 'Site-A' }
    if (-not (Get-ADReplicationSubnet -Filter "Name -eq '10.80.1.0/24'")) { New-ADReplicationSubnet -Name '10.80.1.0/24' -Site 'Site-B' }
    Set-ADReplicationSiteLink -Identity 'DEFAULTIPSITELINK' -SitesIncluded @{Add = 'Site-B'} -ReplicationFrequencyInMinutes 15
    Get-ADReplicationSite -Filter * | Select-Object Name
}

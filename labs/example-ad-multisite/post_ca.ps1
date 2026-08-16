# After CA01|bootstrap|DONE-joined: deliver the Enterprise Root CA role into
# the guest as a scheduled task (domain admin - Enterprise CA needs the rights).
# Then poll host/status.ps1 until CA01|role-adcs|DONE-adcs.
Install-LabGuestTask -VMName CA01 -ScriptHostPath 'C:\Lab\example\role_adcs.ps1' `
    -TaskName 'Lab-Role-ADCS' -User 'RESEARCH\Administrator' -Password '__LAB_PW__'

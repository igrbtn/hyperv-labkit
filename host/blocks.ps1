# HyperVLabKit building blocks - executed ON the Hyper-V host.
# lib/hv.ps1 prepends this file to every submitted script, so all functions
# below are available to lab scripts as plain calls. ASCII only.
#
# Conventions:
#   - host work dir C:\Lab (staged guest scripts, logs, screenshots)
#   - guest work dir C:\Lab (bootstrap.ps1, state.txt, role scripts)
#   - guest KVP status: registry value 'LabStatus', format <VMTAG>|<phase>|<state>,
#     terminal success always ends with |DONE-<what>
#   - only ONE New-LabVM at a time (the builder mounts the VHD on host drive
#     letters S: and W:)

$ErrorActionPreference = 'Stop'

$LabGvlk = @{
    # Public KMS client setup keys (Microsoft docs). They do NOT activate anything;
    # they only skip the OOBE product-key screen that would deadlock a headless build.
    '2022-Standard'   = 'VDYBN-27WPP-V4HQT-9VMD4-VMK7H'
    '2022-Datacenter' = 'WX4NM-KYWYW-QJJR4-XV3QB-6VM33'
    '2025-Standard'   = 'TVRH6-WHNXV-R9WG3-9XRFY-MY832'
    '2025-Datacenter' = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF'
}

# arm.ps1 content injected into every Windows guest: SetupComplete.cmd runs it
# once OOBE finalizes. It ONLY registers the bootstrap task - no CBS work here
# (heavy work in the pre-logon phase deadlocks, see docs/GOTCHAS.md).
$LabArmContent = @'
$ErrorActionPreference = 'Continue'
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Lab\bootstrap.ps1'
$pr  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$st  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
$t1  = New-ScheduledTaskTrigger -AtStartup
# Repeat every 5 minutes: a guest whose dependency is not ready yet (DC still
# promoting, DNS silent) rewinds its state and needs another attempt without
# waiting for a reboot. The state machine disables the task when it is done.
$t2  = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Hours 4)
Register-ScheduledTask -TaskName 'Lab-Bootstrap' -Action $act -Principal $pr -Settings $st -Trigger $t1,$t2 -Force
'@

function New-LabNetwork {
    # Idempotent: internal vSwitch + gateway IP on the host vNIC + NAT.
    param(
        [string]$SwitchName = 'Lab Internal',
        [string]$Subnet     = '10.80.0.0/24',
        [string]$GatewayIP  = '10.80.0.1',
        [string]$NatName    = 'Lab-NAT'
    )
    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
        Start-Sleep 3
    }
    $if = Get-NetAdapter | Where-Object Name -like "*$SwitchName*" | Select-Object -First 1
    $plen = [int]($Subnet.Split('/')[1])
    if (-not (Get-NetIPAddress -IPAddress $GatewayIP -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -IPAddress $GatewayIP -PrefixLength $plen -InterfaceIndex $if.ifIndex | Out-Null
    }
    if (-not (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)) {
        New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $Subnet | Out-Null
    }
    "network ready: switch '$SwitchName', subnet $Subnet, gateway $GatewayIP"
}

function New-LabVM {
    # Offline-provisioned Gen2 Windows VM: VHD -> GPT (EFI/MSR/OS) ->
    # Expand-WindowsImage -> bcdboot -> unattend.xml (GVLK skips OOBE key screen)
    # -> inject bootstrap + SetupComplete -> VM. Idempotent: tears down a prior
    # VM with the same name. Run ONE build at a time (uses host letters S:/W:).
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ComputerName,
        [Parameter(Mandatory)][string]$VMDir,          # put on fast NVMe, see GOTCHAS
        [int]$SizeGB = 80,
        [int]$RamGB  = 4,
        [int]$Cpu    = 2,
        [Parameter(Mandatory)][string]$SwitchName,
        [Parameter(Mandatory)][string]$IsoPath,
        [int]$WimIndex = 2,                            # usually: 2 = Standard Desktop Experience
        [ValidateSet('2022','2025')][string]$OsVersion = '2025',
        [ValidateSet('Standard','Datacenter')][string]$Edition = 'Standard',
        [Parameter(Mandatory)][string]$AdminPassword,
        [string]$BootstrapHostPath,                    # staged guest bootstrap ON THE HOST; injected as C:\Lab\bootstrap.ps1
        [int[]]$DataDiskSizesGB = @(),
        [switch]$EnableNestedVirt,
        [string]$TimeZone = 'UTC'
    )
    if (-not $ComputerName) { $ComputerName = $Name }
    $vmPath  = Join-Path $VMDir $Name
    $vhdPath = Join-Path $vmPath "$Name.vhdx"
    $gvlk    = $LabGvlk["$OsVersion-$Edition"]

    # idempotent teardown of a prior VM and all its disks
    $old = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if ($old) {
        Write-Host "Removing existing $Name ..."
        Stop-VM -Name $Name -Force -TurnOff -ErrorAction SilentlyContinue
        Start-Sleep 3
        $olddisks = (Get-VMHardDiskDrive -VMName $Name).Path
        Remove-VM -Name $Name -Force
        foreach ($d in $olddisks) { Remove-Item $d -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path $vhdPath) {
        Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue
        Remove-Item $vhdPath -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $vmPath | Out-Null

    Write-Host "Creating VHD $vhdPath ($SizeGB GB dynamic)"
    New-VHD -Path $vhdPath -SizeBytes ($SizeGB * 1GB) -Dynamic | Out-Null
    $disk = Mount-VHD -Path $vhdPath -Passthru | Get-Disk
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false | Out-Null

    $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
    $efi | Set-Partition -NewDriveLetter S
    New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
    $os = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $os | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $os | Set-Partition -NewDriveLetter W

    Write-Host "Applying image index $WimIndex from $IsoPath ..."
    $m  = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $dl = ($m | Get-Volume).DriveLetter
    try {
        Expand-WindowsImage -ImagePath ($dl + ':\sources\install.wim') -Index $WimIndex -ApplyPath 'W:\' | Out-Null

        Write-Host 'Making bootable (bcdboot) ...'
        $bcd = Start-Process -FilePath 'W:\Windows\System32\bcdboot.exe' -ArgumentList 'W:\Windows /s S: /f UEFI' -Wait -PassThru -NoNewWindow
        if ($bcd.ExitCode -ne 0) { throw "bcdboot failed: $($bcd.ExitCode)" }

        Write-Host 'Injecting unattend.xml ...'
        # XML-escape the password so &, < etc. cannot break the document
        $pwXml = [System.Security.SecurityElement]::Escape($AdminPassword)
        New-Item -ItemType Directory -Force -Path 'W:\Windows\Panther' | Out-Null
        $unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>$ComputerName</ComputerName>
      <ProductKey>$gvlk</ProductKey>
      <RegisteredOwner>Lab</RegisteredOwner>
      <RegisteredOrganization>Lab</RegisteredOrganization>
      <TimeZone>$TimeZone</TimeZone>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <UserAccounts>
        <AdministratorPassword>
          <Value>$pwXml</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <TimeZone>$TimeZone</TimeZone>
    </component>
  </settings>
</unattend>
"@
        Set-Content -Path 'W:\Windows\Panther\unattend.xml' -Value $unattend -Encoding UTF8

        if ($BootstrapHostPath) {
            Write-Host 'Injecting self-driving bootstrap (SetupComplete + arm task) ...'
            New-Item -ItemType Directory -Force -Path 'W:\Lab' | Out-Null
            # Ordinal .Replace (NOT -replace): password may contain regex/substitution chars
            $gb = (Get-Content $BootstrapHostPath -Raw).Replace('__LAB_PW__', $AdminPassword)
            Set-Content -Path 'W:\Lab\bootstrap.ps1' -Value $gb -Encoding UTF8
            Set-Content -Path 'W:\Lab\arm.ps1' -Value $LabArmContent -Encoding UTF8
            New-Item -ItemType Directory -Force -Path 'W:\Windows\Setup\Scripts' | Out-Null
            # SetupComplete runs BEFORE setup finalizes: ONLY register the task here
            $setupComplete = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Lab\arm.ps1`r`nexit /b 0`r`n"
            Set-Content -Path 'W:\Windows\Setup\Scripts\SetupComplete.cmd' -Value $setupComplete -Encoding Ascii
        }
    } finally {
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
        Dismount-VHD -Path $vhdPath
    }

    Write-Host 'Creating Gen2 VM ...'
    New-VM -Name $Name -MemoryStartupBytes ($RamGB * 1GB) -Generation 2 -VHDPath $vhdPath -SwitchName $SwitchName -Path $VMDir | Out-Null
    Set-VM -Name $Name -ProcessorCount $Cpu -StaticMemory -AutomaticStartAction Nothing
    Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    Set-VMFirmware -VMName $Name -FirstBootDevice (Get-VMHardDiskDrive -VMName $Name)
    Enable-VMIntegrationService -VMName $Name -Name 'Guest Service Interface'

    if ($DataDiskSizesGB.Count -gt 0) {
        $n = 1
        foreach ($gb in $DataDiskSizesGB) {
            $dp = Join-Path $vmPath ("$Name-data$n.vhdx")
            if (Test-Path $dp) { Remove-Item $dp -Force }
            New-VHD -Path $dp -SizeBytes ($gb * 1GB) -Dynamic | Out-Null
            Add-VMHardDiskDrive -VMName $Name -Path $dp
            $n++
        }
        Write-Host ("Attached " + $DataDiskSizesGB.Count + " data disk(s)")
    }
    if ($EnableNestedVirt) {
        # nested virt / S2D nodes: static memory (already set) + MAC spoofing
        Set-VMProcessor -VMName $Name -ExposeVirtualizationExtensions $true
        Set-VMNetworkAdapter -VMName $Name -MacAddressSpoofing On
        Write-Host 'Nested virtualization enabled'
    }

    Start-VM -Name $Name
    "DONE: $Name created and started"
}

function Get-LabKvpStatus {
    # Host-only guest status via Hyper-V KVP - never hangs, works during
    # boot/OOBE when PS Direct would freeze. Guests write registry value
    # 'LabStatus' under HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest.
    param([string[]]$VMName = @())
    if (-not $VMName -or $VMName.Count -eq 0) {
        $VMName = Get-VM | Select-Object -ExpandProperty Name
    }
    foreach ($name in $VMName) {
        $vm = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$name'"
        if (-not $vm) { "$name=MISSING"; continue }
        $state  = (Get-VM $name).State
        $status = '<none>'
        try {
            $kvp = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_KvpExchangeComponent
            foreach ($xmlStr in $kvp.GuestExchangeItems) {
                $x = [xml]$xmlStr
                $n = ($x.INSTANCE.PROPERTY | Where-Object { $_.NAME -eq 'Name' }).VALUE
                if ($n -eq 'LabStatus') {
                    $status = ($x.INSTANCE.PROPERTY | Where-Object { $_.NAME -eq 'Data' }).VALUE
                }
            }
        } catch { $status = '<kvp-err>' }
        "$name=$state|$status"
    }
}

function Get-LabScreenshot {
    # Console thumbnail of a (possibly stuck) VM, e.g. OOBE waiting on input.
    # Saves a PNG on the host; fetch it with lib/hvfetch.ps1.
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$OutFile
    )
    if (-not $OutFile) { $OutFile = "C:\Lab\$VMName.png" }
    Add-Type -AssemblyName System.Drawing
    $vsms  = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
    $vm    = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
    $video = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VideoHead -ErrorAction SilentlyContinue | Select-Object -First 1
    $w = 1024; $h = 768
    if ($video -and [int]$video.CurrentHorizontalResolution -gt 0) {
        $w = [int]$video.CurrentHorizontalResolution
        $h = [int]$video.CurrentVerticalResolution
    }
    $res   = Invoke-CimMethod -InputObject $vsms -MethodName GetVirtualSystemThumbnailImage -Arguments @{ TargetSystem = $vm; WidthPixels = [uint16]$w; HeightPixels = [uint16]$h }
    $bytes = $res.ImageData
    $bmp  = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $data.Scan0, [Math]::Min($bytes.Length, $w * $h * 2))
    $bmp.UnlockBits($data)
    New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null
    $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    "saved $OutFile (${w}x${h})"
}

function Install-LabGuestTask {
    # Fire-and-forget delivery of a long-running script INTO a guest:
    # PS Direct session -> write script -> register AtStartup+Once scheduled
    # task -> start it. Never wait for the work itself - poll Get-LabKvpStatus.
    # Role scripts that need domain rights (AD CS, Exchange) must run as a
    # domain admin (default); use -AsSystem for local-only work.
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ScriptHostPath,   # script ON THE HOST (staged via hvcopy)
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$User,             # 'DOMAIN\Administrator' or '.\Administrator'
        [Parameter(Mandatory)][string]$Password,
        [switch]$AsSystem
    )
    # Substitute the password token here: staged files keep the token, only the
    # in-guest copy gets the real value. Ordinal .Replace by design.
    $content   = (Get-Content $ScriptHostPath -Raw).Replace('__LAB_PW__', $Password)
    $guestPath = "C:\Lab\$TaskName.ps1"
    $sec  = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
    $sess = New-PSSession -VMName $VMName -Credential $cred
    try {
        Invoke-Command -Session $sess -ScriptBlock {
            param($c, $p, $tn, $gp, $asSystem, $user)
            New-Item -ItemType Directory -Force -Path C:\Lab | Out-Null
            Set-Content -Path $gp -Value $c -Encoding UTF8
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File ' + $gp)
            $st  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
            $t1  = New-ScheduledTaskTrigger -AtStartup
            $t2  = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1))
            if ($asSystem) {
                $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                Register-ScheduledTask -TaskName $tn -Action $act -Principal $pr -Settings $st -Trigger $t1, $t2 -Force | Out-Null
            } else {
                Register-ScheduledTask -TaskName $tn -Action $act -Settings $st -Trigger $t1, $t2 -User $user -Password $p -RunLevel Highest -Force | Out-Null
            }
            Start-ScheduledTask -TaskName $tn
            Start-Sleep 3
            $tn + ' state: ' + (Get-ScheduledTask -TaskName $tn).State
        } -ArgumentList $content, $Password, $TaskName, $guestPath, [bool]$AsSystem, $User
    } finally {
        Remove-PSSession $sess -ErrorAction SilentlyContinue
    }
}

function Invoke-LabGuest {
    # Short synchronous PS Direct call for QUICK queries/config only (seconds,
    # not minutes) on a guest that is fully booted. Long work: Install-LabGuestTask.
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    $sec  = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
    $sess = New-PSSession -VMName $VMName -Credential $cred
    try {
        Invoke-Command -Session $sess -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    } finally {
        Remove-PSSession $sess -ErrorAction SilentlyContinue
    }
}

#-----------------------
# Phase3.ps1
#-----------------------

$ErrorActionPreference='Stop'

echo "$(date) Phase3.ps1 started" >> $env:SystemDrive\packer\configure.log

try {
    echo "$(date) Phase3.ps1 starting" >> $env:SystemDrive\packer\configure.log    

    #--------------------------------------------------------------------------------------------
    # We delayed docker earlier until after privates were installed. Enabled it now and start it.
    echo "$(date) Phase3.ps1 Starting docker..." >> $env:SystemDrive\packer\configure.log    
    sc config "docker" start= auto
    sc start docker
    sleep 5
    docker version >> $env:SystemDrive\packer\configure.log
    

    #--------------------------------------------------------------------------------------------
    # Install the container OS images
    echo "$(date) Phase3.ps1 Installing OS images..." >> $env:SystemDrive\packer\configure.log    
    powershell -command "$env:SystemDrive\packer\InstallOSImages.ps1"

    #--------------------------------------------------------------------------------------------
    # Initiate Phase4. This runs as the Jenkins user interactively. This is particularly on account
    # of configuring cygwin SSH not working as local system, RunOnce regkey also fails. And so does
    # a scheduled task that isn't interactive. All due to cygwin oddities.
    echo "$(date) Phase3.ps1 Initiating phase4..." >> $env:SystemDrive\packer\configure.log    
    $pass = Get-Content c:\packer\password.txt -raw
    REG ADD "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinLogon" /v AutoAdminLogon /t REG_DWORD /d 1 /f | Out-Null
    REG ADD "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinLogon" /v DefaultUserName /t REG_SZ /d jenkins /f | Out-Null
    REG ADD "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinLogon" /v DefaultPassword /t REG_SZ /d $pass /f | Out-Null
    
    # Create the shortcut (and the containing directory as we haven't logged on interactively yet)
    New-Item "C:\Users\jenkins\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup" -Type Directory -ErrorAction SilentlyContinue    
    $TargetFile = "powershell"
    $ShortcutFile = "C:\Users\jenkins\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Phase4.lnk"
    $WScriptShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
    $Shortcut.Arguments ="-command c:\packer\Phase4.ps1"
    $Shortcut.TargetPath = $TargetFile
    $Shortcut.Save()


}
Catch [Exception] {
    echo "$(date) Phase3.ps1 complete with Error '$_'" >> $env:SystemDrive\packer\configure.log
    exit 1
}
Finally {
    # Disable the scheduled task
    echo "$(date) Phase3.ps1 disabling scheduled task.." >> $env:SystemDrive\packer\configure.log
    $ConfirmPreference='none'
    Get-ScheduledTask 'Phase3' | Disable-ScheduledTask

    # Reboot
    echo "$(date) Phase3.ps1 completed. Rebooting" >> $env:SystemDrive\packer\configure.log
    shutdown /t 0 /r /f /c "Phase1"
    echo "$(date) Phase3.ps1 complete successfully at $(date)" >> $env:SystemDrive\packer\configure.log
} 

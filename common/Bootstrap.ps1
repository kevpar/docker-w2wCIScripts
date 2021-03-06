#-----------------------
# Bootstrap.ps1
#-----------------------

# This runs as a scheduled tasks after coming out of sysprep. At this point, we have the jenkins user
# so can schedule tasks as that user to do the post-sysprep configuration. This script itself though
# is running as Local System.
#
# Don't put anything in here apart from things that are required for launching the post sysprep tasks.

param(
    [Parameter(Mandatory=$false)][string]$ConfigSet,
    [Parameter(Mandatory=$false)][switch]$Doitanyway=$False
)

$ErrorActionPreference="stop"

function Test-Nano() {  
    $EditionId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID').EditionId  
    return (($EditionId -eq "ServerStandardNano") -or   
            ($EditionId -eq "ServerDataCenterNano") -or   
            ($EditionId -eq "NanoServer") -or   
            ($EditionId -eq "ServerTuva"))  
}  

function Copy-File {  
    [CmdletBinding()]  
    param(  
        [string] $SourcePath,  
        [string] $DestinationPath  
    )  

    if ($SourcePath -eq $DestinationPath) { return }  

    if (Test-Path $SourcePath) { 
        Copy-Item -Path $SourcePath -Destination $DestinationPath 
    } elseif (($SourcePath -as [System.URI]).AbsoluteURI -ne $null) {  
        if (Test-Nano) {
            $handler = New-Object System.Net.Http.HttpClientHandler  
            $client = New-Object System.Net.Http.HttpClient($handler)  
            $client.Timeout = New-Object System.TimeSpan(0, 30, 0)  
            $cancelTokenSource = [System.Threading.CancellationTokenSource]::new()   
            $responseMsg = $client.GetAsync([System.Uri]::new($SourcePath), $cancelTokenSource.Token)  
            $responseMsg.Wait()  

            if (!$responseMsg.IsCanceled) {  
                $response = $responseMsg.Result  
                if ($response.IsSuccessStatusCode) {  
                    $downloadedFileStream = [System.IO.FileStream]::new($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)  
                    $copyStreamOp = $response.Content.CopyToAsync($downloadedFileStream)  
                    $copyStreamOp.Wait()  
                    $downloadedFileStream.Close()  
                    if ($copyStreamOp.Exception -ne $null) {  
                        throw $copyStreamOp.Exception  
                    }        
                }  
            }    
        }  
        elseif ($PSVersionTable.PSVersion.Major -ge 5) {
            # We disable progress display because it kills performance for large downloads (at least on 64-bit PowerShell)  
            $ProgressPreference = 'SilentlyContinue'  
            wget -Uri $SourcePath -OutFile $DestinationPath -UseBasicParsing  
            $ProgressPreference = 'Continue'  
        } else {  
            $webClient = New-Object System.Net.WebClient  
            $webClient.DownloadFile($SourcePath, $DestinationPath)  
        }   
    } else {  
        throw "Cannot copy from $SourcePath"  
    }  
}  

echo "$(date) Bootstrap.ps1 starting..." >> $env:SystemDrive\packer\configure.log
if (-not (Test-Nano)) {
    echo $(date) > "c:\users\public\desktop\Bootstrap Start.txt"
}

try {

    # Delete the scheduled task. May not exist on local install
    $ConfirmPreference='none'
    $t = Get-ScheduledTask 'Bootstrap' -ErrorAction SilentlyContinue
    if ($t -ne $null) {
        echo "$(date) Bootstrap.ps1 deleting scheduled task.." >> $env:SystemDrive\packer\configure.log
        Unregister-ScheduledTask 'Bootstrap' -Confirm:$False -ErrorAction SilentlyContinue
    }

    # This is a semi-hack to avoid using packer and having two images in Azure which is just a time drain prepping/uploading etc.
    # We assume production machines are called jenkins*. If not, we just get out after the task has been deleted. Unless we are
    # told to do it anyway
    if ($Doitanyway -eq $False) {
        if (-not ($env:COMPUTERNAME.ToLower() -like "jenkins*")) { 
            echo "$(date) Bootstrap.ps1 computername doesn't start with jenkins.." >> $env:SystemDrive\packer\configure.log
            if (-not (Test-Nano)) {
                echo $(date) > "c:\users\public\desktop\Bootstrap not jenkins.txt"
            }


            # If we are running as system, we are coming out of sysprep. In which case we are currently
            # running as local system, so we need to schedule a task to run Install-DevVM as the administrator account,
            # and reboot
            #
            # If we are running as the administrator account, we don't need to do anything as chances our we were 
            # called directly from Install-DevVM anyway (yes, it's circular)
            if ((($env:USERNAME).ToLower()) -eq (($env:COMPUTERNAME).ToLower()+"$")) {
                echo "$(date) Bootstrap.ps1 running as local system - scheduling Install-DevVM as administrator.." >> $env:SystemDrive\packer\configure.log
                echo $(date) > "c:\users\public\desktop\Bootstrap scheduling Install-DevVM.txt"
                $configset = Get-Content c:\packer\configset.txt -raw
                $debugport = Get-Content c:\packer\debugport.txt -raw
                $pass = Get-Content c:\packer\password.txt -raw


                # Create the shortcut so that it can be interactive - I really can't figure interactive even using schtasks and /TI
                New-Item "C:\Users\administrator\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup" -Type Directory -ErrorAction SilentlyContinue    
                $TargetFile = "powershell"
                $ShortcutFile = "C:\Users\administrator\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\launch.lnk"
                $WScriptShell = New-Object -ComObject WScript.Shell
                $Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
                $Shortcut.Arguments ="`"cd c:\w2w\Install-DevVM; echo 'Sleeping for network to come up'; start-sleep -seconds 30; .\Install-DevVM.ps1 -ConfigSet $configset -DebugPort $debugport`""
                $Shortcut.TargetPath = $TargetFile
                $Shortcut.Save()
                shutdown /t 0 /r
                exit 0
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($ConfigSet)) {
        $ConfigSet=""
        
        # Get config.txt
        echo "$(date) Bootstrap.ps1 Downloading config.txt..." >> $env:SystemDrive\packer\configure.log
        Copy-File -SourcePath "https://raw.githubusercontent.com/jhowardmsft/docker-w2wCIScripts/master/config/config.txt" -DestinationPath "$env:SystemDrive\packer\config.txt"

        $hostname=$env:COMPUTERNAME.ToLower()
        echo "$(date) Bootstrap.ps1 Matching $hostname for a configset..." >> $env:SystemDrive\packer\configure.log
        
        foreach ($line in Get-Content $env:SystemDrive\packer\config.txt) {
            $line=$line.Trim()
            if (($line[0] -eq "#") -or ($line -eq "")) {
                continue
            }
            $elements=$line.Split(",")
            if ($elements.Length -ne 2) {
                continue
            }
            if (($elements[0].Length -eq 0) -or ($elements[1].Length -eq 0)) {
                continue
            }
            if ($hostname -match $elements[0]) {
                $configSet=$elements[1]
                Write-Host $hostname matches $elements[0]
                break
            }
        }
        if ($ConfigSet.Length -eq 0) { Throw "ConfigSet not supplied and $hostname regex match not found in configuration" }
        echo "$(date) Bootstrap.ps1 ConfigSet matches $ConfigSet through "$elements[0] >> $env:SystemDrive\packer\configure.log
    }

    # Store the configset
    echo "$(date) Bootstrap.ps1 ConfigSet is $ConfigSet..." >> $env:SystemDrive\packer\configure.log
    setx "ConfigSet" "$ConfigSet" /M
    $env:ConfigSet=$ConfigSet

    # Create the scripts and packer directories
    echo "$(date) Bootstrap.ps1 Creating scripts directory..." >> $env:SystemDrive\packer\configure.log
    mkdir c:\\scripts -ErrorAction SilentlyContinue 2>&1 | Out-Null
    echo "$(date) Bootstrap.ps1 Creating packer directory..." >> $env:SystemDrive\packer\configure.log
    mkdir c:\\packer -ErrorAction SilentlyContinue 2>&1 | Out-Null

    # Delete Phase0.ps1 if it already exists
    if (Test-Path "c:\packer\Phase0.ps1") {
        Remove-Item "c:\packer\Phase0.ps1" -ErrorAction SilentlyContinue 2>&1 | Out-Null
    }

    # Get Phase0.ps1
    echo "$(date) Bootstrap.ps1 Downloading Phase0.ps1..." >> $env:SystemDrive\packer\configure.log
    Copy-File -SourcePath "https://raw.githubusercontent.com/jhowardmsft/docker-w2wCIScripts/master/common/Phase0.ps1" -DestinationPath "$env:SystemDrive\packer\Phase0.ps1"

    # Execute Phase0 passing the configset as a parameter
    echo "$(date) Bootstrap.ps1 Executing Phase0.ps1..." >> $env:SystemDrive\packer\configure.log
    . "$env:SystemDrive\packer\Phase0.ps1" -ConfigSet $ConfigSet
}
Catch [Exception] {
    echo "$(date) Bootstrap.ps1 Error '$_'" >> $env:SystemDrive\packer\configure.log
    if (-not (Test-Nano)) {
        echo $(date) > "c:\users\public\desktop\ERROR Bootstrap.txt"
    }
    exit 1
}
Finally {
    echo "$(date) Bootstrap.ps1 completed..." >> $env:SystemDrive\packer\configure.log
    if (-not (Test-Nano)) {
        echo $(date) > "c:\users\public\desktop\Bootstrap End.txt"
    }
}  

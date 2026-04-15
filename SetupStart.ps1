function AddToStatus([string]$line, [string]$color = "Gray") {
    ("<font color=""$color"">" + [DateTime]::Now.ToString([System.Globalization.DateTimeFormatInfo]::CurrentInfo.ShortTimePattern.replace(":mm",":mm:ss")) + " $line</font>") | Add-Content -Path "c:\demo\status.txt" -Force -ErrorAction SilentlyContinue
}

function Download-File([string]$sourceUrl, [string]$destinationFile)
{
    AddToStatus "Downloading $destinationFile"
    Remove-Item -Path $destinationFile -Force -ErrorAction Ignore
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    (New-Object System.Net.WebClient).DownloadFile($sourceUrl, $destinationFile)
}

function Register-NativeMethod([string]$dll, [string]$methodSignature)
{
    $script:nativeMethods += [PSCustomObject]@{ Dll = $dll; Signature = $methodSignature; }
}

function Add-NativeMethods()
{
    $nativeMethodsCode = $script:nativeMethods | % { "
        [DllImport(`"$($_.Dll)`")]
        public static extern $($_.Signature);
    " }

    Add-Type @"
        using System;
        using System.Text;
        using System.Runtime.InteropServices;
        public class NativeMethods {
            $nativeMethodsCode
        }
"@
}

AddToStatus "SetupStart, User: $env:USERNAME"

. (Join-Path $PSScriptRoot "settings.ps1")

$ComputerInfo = Get-ComputerInfo
$WindowsInstallationType = $ComputerInfo.WindowsInstallationType
$WindowsProductName = $ComputerInfo.WindowsProductName

if ($nchBranch -eq "preview") {
    AddToStatus "Installing Latest BcContainerHelper preview from PowerShell Gallery"
    Install-Module -Name bccontainerhelper -Force -AllowPrerelease
    Import-Module -Name bccontainerhelper -DisableNameChecking
    AddToStatus ("Using BcContainerHelper version "+(get-module BcContainerHelper).Version.ToString())
}
elseif ($nchBranch -eq "") {
    AddToStatus "Installing Latest Business Central Container Helper from PowerShell Gallery"
    Install-Module -Name bccontainerhelper -Force
    Import-Module -Name bccontainerhelper -DisableNameChecking
    AddToStatus ("Using BcContainerHelper version "+(get-module BcContainerHelper).Version.ToString())
} else {
    if ($nchBranch -notlike "https://*") {
        $nchBranch = "https://github.com/Microsoft/navcontainerhelper/archive/$($nchBranch).zip"
    }
    AddToStatus "Using BcContainerHelper from $nchBranch"
    Download-File -sourceUrl $nchBranch -destinationFile "c:\demo\bccontainerhelper.zip"
    [Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.Filesystem") | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory("c:\demo\bccontainerhelper.zip", "c:\demo")
    $module = Get-Item -Path "C:\demo\*\BcContainerHelper.psm1"
    AddToStatus "Loading BcContainerHelper from $($module.FullName)"
    Import-Module $module.FullName -DisableNameChecking
}

# Install PowerShell modules in parallel (saves ~10-15 min vs sequential)
$modulesToInstall = @()
if (-not (Get-InstalledModule Az -ErrorAction SilentlyContinue)) { $modulesToInstall += "Az" }
if (-not (Get-InstalledModule AzureAD -ErrorAction SilentlyContinue)) { $modulesToInstall += "AzureAD" }
if (-not (Get-InstalledModule "Microsoft.Graph" -ErrorAction SilentlyContinue)) { $modulesToInstall += "Microsoft.Graph" }
if (-not (Get-InstalledModule SqlServer -ErrorAction SilentlyContinue)) { $modulesToInstall += "SqlServer" }

if ($modulesToInstall.Count -gt 1) {
    AddToStatus "Installing PowerShell modules in parallel: $($modulesToInstall -join ', ')"
    $moduleJobs = @{}
    foreach ($mod in $modulesToInstall) {
        $moduleJobs[$mod] = Start-Job -ScriptBlock {
            param($moduleName)
            Install-Module $moduleName -Force
        } -ArgumentList $mod
    }
    # Wait for all module installs to complete
    foreach ($mod in $moduleJobs.Keys) {
        try {
            Receive-Job -Job $moduleJobs[$mod] -Wait -ErrorAction Stop | Out-Null
            AddToStatus "Module $mod installed successfully"
        }
        catch {
            AddToStatus -color Red "Failed to install module ${mod}: $($_.Exception.Message)"
            # Retry sequentially as fallback
            AddToStatus "Retrying $mod installation sequentially"
            Install-Module $mod -Force
        }
        finally {
            Remove-Job -Job $moduleJobs[$mod] -Force -ErrorAction SilentlyContinue
        }
    }
}
elseif ($modulesToInstall.Count -eq 1) {
    AddToStatus "Installing $($modulesToInstall[0]) module"
    Install-Module $modulesToInstall[0] -Force
}

$securePassword = ConvertTo-SecureString -String $adminPassword -Key $passwordKey
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword))

if ($requestToken) {
    if (!(Get-ScheduledTask -TaskName request -ErrorAction Ignore)) {
        AddToStatus "Registering request task"
        $xml = [System.IO.File]::ReadAllText("c:\demo\RequestTaskDef.xml")
        Register-ScheduledTask -TaskName request -User $vmadminUsername -Password $plainPassword -Xml $xml
    }
}

if ("$createStorageQueue" -eq "yes") {
    if (-not (Get-InstalledModule AzTable -ErrorAction SilentlyContinue)) {
        AddToStatus "Installing AzTable Module"
        Install-Module AzTable -Force
    
        $taskName = "RunQueue"
        $startupAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy UnRestricted -File c:\demo\RunQueue.ps1"
        $startupTrigger = New-ScheduledTaskTrigger -AtStartup
        $startupTrigger.Delay = "PT5M"
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -DontStopOnIdleEnd
        $task = Register-ScheduledTask -TaskName $taskName `
                               -Action $startupAction `
                               -Trigger $startupTrigger `
                               -Settings $settings `
                               -RunLevel Highest `
                               -User $vmAdminUsername `
                               -Password $plainPassword
        
        $task.Triggers.Repetition.Interval = "PT5M"
        $task | Set-ScheduledTask -User $vmAdminUsername -Password $plainPassword | Out-Null
    
        Start-ScheduledTask -TaskName $taskName
    }
}

$taskName = "RestartContainers"
if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction Ignore)) {
    AddToStatus "Register RestartContainers Task to start container delayed"
    $startupAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy UnRestricted -file c:\demo\restartcontainers.ps1"
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $startupTrigger.Delay = "PT5M"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -DontStopOnIdleEnd
    $task = Register-ScheduledTask -TaskName $taskName `
                           -Action $startupAction `
                           -Trigger $startupTrigger `
                           -Settings $settings `
                           -RunLevel Highest `
                           -User $vmadminUsername `
                           -Password $plainPassword
}

if ($WindowsInstallationType -eq "Server") {

    if (Get-ScheduledTask -TaskName SetupVm -ErrorAction Ignore) {
        schtasks /DELETE /TN SetupVm /F | Out-Null
    }

    AddToStatus "Launch SetupVm"
    $onceAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy UnRestricted -File c:\demo\setupVm.ps1"
    Register-ScheduledTask -TaskName SetupVm `
                           -Action $onceAction `
                           -RunLevel Highest `
                           -User $vmAdminUsername `
                           -Password $plainPassword | Out-Null
    
    Start-ScheduledTask -TaskName SetupVm
}
else {
    
    if (Get-ScheduledTask -TaskName SetupStart -ErrorAction Ignore) {
        schtasks /DELETE /TN SetupStart /F | Out-Null
    }
    
    $startupAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy UnRestricted -File c:\demo\SetupVm.ps1"
    $startupTrigger = New-ScheduledTaskTrigger -AtStartup
    $startupTrigger.Delay = "PT1M"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -DontStopOnIdleEnd -WakeToRun
    Register-ScheduledTask -TaskName "SetupVm" `
                           -Action $startupAction `
                           -Trigger $startupTrigger `
                           -Settings $settings `
                           -RunLevel "Highest" `
                           -User $vmAdminUsername `
                           -Password $plainPassword | Out-Null
    
    AddToStatus -color Yellow "Restarting computer. After restart, please Login to computer using RDP in order to resume the installation process. This is not needed for Windows Server."
    
    Shutdown -r -t 60

}

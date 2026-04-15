if (!(Test-Path function:AddToStatus)) {
    function AddToStatus([string]$line, [string]$color = "Gray") {
        ("<font color=""$color"">" + [DateTime]::Now.ToString([System.Globalization.DateTimeFormatInfo]::CurrentInfo.ShortTimePattern.replace(":mm",":mm:ss")) + " $line</font>") | Add-Content -Path "c:\demo\status.txt" -Force -ErrorAction SilentlyContinue
        Write-Host -ForegroundColor $color $line 
    }
}

if (Test-Path -Path "C:\demo\*\BcContainerHelper.psm1") {
    $module = Get-Item -Path "C:\demo\*\BcContainerHelper.psm1"
    Import-module $module.FullName -DisableNameChecking
} else {
    Import-Module -name bccontainerhelper -DisableNameChecking
}

. (Join-Path $PSScriptRoot "settings.ps1")

AddToStatus -color Green "Setting up Desktop Experience"

$codeCmd = "C:\Program Files\Microsoft VS Code\bin\Code.cmd"
$codeExe = "C:\Program Files\Microsoft VS Code\Code.exe"
$firsttime = (!(Test-Path $codeExe))
$disableVsCodeUpdate = $false

if ($firsttime) {
    $Folder = "C:\DOWNLOAD\VSCode"
    $Filename = "$Folder\VSCodeSetup-stable.exe"
    $samplesFolder = "C:\DOWNLOAD"
    $samplesFilename = "$samplesFolder\samples.zip"

    New-Item $Folder -itemtype directory -ErrorAction ignore | Out-Null

    # Download VS Code and AL samples in parallel
    AddToStatus "Downloading Visual Studio Code and AL samples in parallel"
    $vscodeJob = Start-Job -ScriptBlock {
        param($sourceUrl, $destinationFile)
        Remove-Item -Path $destinationFile -Force -ErrorAction Ignore
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        (New-Object System.Net.WebClient).DownloadFile($sourceUrl, $destinationFile)
    } -ArgumentList "https://go.microsoft.com/fwlink/?Linkid=852157", $Filename

    $samplesJob = Start-Job -ScriptBlock {
        param($sourceUrl, $destinationFile)
        Remove-Item -Path $destinationFile -Force -ErrorAction Ignore
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        (New-Object System.Net.WebClient).DownloadFile($sourceUrl, $destinationFile)
    } -ArgumentList "https://www.github.com/Microsoft/AL/archive/master.zip", $samplesFilename

    $vscodeJob, $samplesJob | Wait-Job | Out-Null
    Receive-Job $vscodeJob -ErrorAction Stop; Remove-Job $vscodeJob -Force
    Receive-Job $samplesJob -ErrorAction Stop; Remove-Job $samplesJob -Force
    
    AddToStatus "Installing Visual Studio Code (this might take a few minutes)"
    $setupParameters = “/VerySilent /CloseApplications /NoCancel /LoadInf=""c:\demo\vscode.inf"" /MERGETASKS=!runcode"
    Start-Process -FilePath $Filename -WorkingDirectory $Folder -ArgumentList $setupParameters -Wait -Passthru | Out-Null

    AddToStatus "Extracting samples"

    Remove-Item -Path "$samplesFolder\AL-master" -Force -Recurse -ErrorAction Ignore | Out-null
    [Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.Filesystem") | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($samplesFilename, $samplesFolder)
    
    $alFolder = "$([Environment]::GetFolderPath("MyDocuments"))\AL"
    Remove-Item -Path "$alFolder\Samples" -Recurse -Force -ErrorAction Ignore | Out-Null
    New-Item -Path "$alFolder\Samples" -ItemType Directory -Force -ErrorAction Ignore | Out-Null
    Copy-Item -Path "$samplesFolder\AL-master\samples\*" -Destination "$alFolder\samples" -Recurse -ErrorAction Ignore
    Copy-Item -Path "$samplesFolder\AL-master\snippets\*" -Destination "$alFolder\snippets" -Recurse -ErrorAction Ignore
}

$codeProcess = get-process Code -ErrorAction SilentlyContinue
if ($codeProcess) {
    AddToStatus "WARNING: VS Code is running, skipping .vsix installation"
}
elseif (Test-Path "C:\ProgramData\bccontainerhelper\Extensions\$containerName\*.vsix") {
    $vsixFileName = (Get-Item "C:\ProgramData\bccontainerhelper\Extensions\$containerName\*.vsix").FullName
    if ($vsixFileName -ne "") {
    
        AddToStatus "Installing .vsix"
        try { & $codeCmd @('--install-extension', $VsixFileName) | Out-Null } catch {}
    
        $username = [Environment]::UserName
        if (Test-Path -path "c:\Users\Default\.vscode" -PathType Container -ErrorAction Ignore) {
            if (!(Test-Path -path "c:\Users\$username\.vscode" -PathType Container -ErrorAction Ignore)) {
                Copy-Item -Path "c:\Users\Default\.vscode" -Destination "c:\Users\$username\" -Recurse -Force -ErrorAction Ignore
            }
        }
    }
}

if ($disableVsCodeUpdate) {
    $vsCodeSettingsFile = Join-Path ([Environment]::GetFolderPath("ApplicationData")) "Code\User\settings.json"
    '{
        "update.channel": "none"
    }' | Set-Content $vsCodeSettingsFile
}

AddToStatus "Creating Desktop Shortcuts"
if ($AddTraefik -eq "Yes") {
    $landingPageUrl = "http://${publicDnsName}:8180"
}
else {
    $landingPageUrl = "http://${publicDnsName}"
}
New-DesktopShortcut -Name "Landing Page" -TargetPath $landingPageUrl -IconLocation "C:\Program Files\Internet Explorer\iexplore.exe, 3"
New-DesktopShortcut -Name "Visual Studio Code" -TargetPath $codeExe
New-DesktopShortcut -Name "PowerShell ISE" -TargetPath "C:\Windows\system32\WindowsPowerShell\v1.0\powershell_ise.exe" -WorkingDirectory "c:\demo"
New-DesktopShortcut -Name "Command Prompt" -TargetPath "C:\Windows\system32\cmd.exe" -WorkingDirectory "c:\demo"
New-DesktopShortcut -Name "Nav Container Helper" -TargetPath "c:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -Arguments "-noexit ""& { Write-BcContainerHelperWelcomeText }""" -WorkingDirectory "C:\ProgramData\bccontainerhelper"

AddToStatus -color Green "Desktop setup complete!"

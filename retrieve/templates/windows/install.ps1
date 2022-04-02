#======================================================================================================================
#
#          FILE: rport-windows-installer.ps1
#
#   DESCRIPTION: Bootstrap Rport installation for Windows
#
#          BUGS: https://github.com/cloudradar-monitoring/rport/issues
#
#     COPYRIGHT: (c) 2021 by the CloudRadar Team,
#
#       LICENSE: MIT
#  ORGANIZATION: cloudradar GmbH, Potsdam, Germany (cloudradar.io)
#       CREATED: 25/02/2021
#        EDITED: 07/12/2021
#======================================================================================================================
<#
        .SYNOPSIS
        Installs the rport clients and connects it to the server

        .DESCRIPTION
        This script will download the latest version of the rport client,
        create the configuration and connect to the server.
        You can change the configuration by editing C:\Program Files\rport\rport.conf
        Rport runs as a service with a local system account.

        .PARAMETER x
        Enable the execution of scripts via rport.

        .PARAMETER t
        Use the latest unstable development release. Dangerous!

        .PARAMETER i
        Install Tascoscript along with the RPort Client

        .INPUTS
        None. You cannot pipe objects.

        .OUTPUTS
        System.String. Add-Extension returns success banner or a failure message.

        .EXAMPLE
        PS> powershell -ExecutionPolicy Bypass -File .\rport-installer.ps1 -x
        Install and connext with script execution enabled.

        .EXAMPLE
        PS> powershell -ExecutionPolicy Bypass -File .\rport-installer.ps1
        Install and connect with script execution disabled.

        .LINK
        Online help: https://kb.rport.io/connecting-clients#advanced-pairing-options
#>
# Definition of command line parameters
Param(
# Enable remote commands yes/no
    [switch]$x,
# Use unstable version yes/no
    [switch]$t,
# Install tacoscript
    [switch]$i
)

$release = If ($t) { "unstable" }
Else { "stable" }
$myLocation= (Get-Location).path
$url = "https://downloads.rport.io/rport/$( $release )/latest.php?arch=Windows_x86_64"
$downloadFile = "C:\Windows\temp\rport_$( $release )_Windows_x86_64.zip"
$installDir = "$( $Env:Programfiles )\rport"
$dataDir = "$( $installDir )\data"
# Test the connection to the RPort server first
if (Test-NetConnection -ComputerName $server.split(":")[0] -Port $server.split(":")[1] -InformationLevel Quiet) {
    Write-Host "Connection to RPort server tested successfully."
}
else {
    Write-Host "Connection to RPort server failed."
    Write-Host "Check your internet connection and firewall rules."
    Exit 1;
}
Write-Host ""
# Download the package from GitHub
if (-not(Test-Path $downloadFile -PathType leaf)) {
    Write-Host "* Downloading  $( $url ) ."
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $downloadFile
    Write-Host "* Download finished and stored to $( $downloadFile ) ."
}

# Create a directory
if (-not(Test-Path $installDir)) {
    mkdir $installDir| Out-Null
}
# Create the data directory
if (-not(Test-Path $dataDir)) {
    mkdir $dataDir| Out-Null
}

# Extract the ZIP file
Write-Host ""
Expand-Zip -Path $downloadFile -DestinationPath $installDir
$targetVersion = (& "$( $installDir )/rport.exe" --version) -replace "version ",""
Write-Host "* RPort Client version $targetVersion installed."
$configFile = "$( $installDir )\rport.conf"
if (Test-Path $configFile -PathType leaf) {
    Write-Host "* Configuration file $( $configFile ) found."
    Write-Host "* Your configuration will not be changed."
}
else {
    # Create a config file from the example
    $configContent = Get-Content "$( $installDir )\rport.example.conf" -Raw
    Write-Host "* Creating new configuration file $( $configFile )."
    # Put variables into the config
    $logFile = "$( $installDir )\rport.log"
    $configContent = $configContent -replace 'server = .*', "server = `"$( $server )`""
    $configContent = $configContent -replace '.*auth = .*', "auth = `"$( $client_id ):$( $password )`""
    $configContent = $configContent -replace '#id = .*', "id = `"$( (Get-CimInstance -Class Win32_ComputerSystemProduct).UUID )`""
    $configContent = $configContent -replace '#fingerprint = .*', "fingerprint = `"$( $fingerprint )`""
    $configContent = $configContent -replace 'log_file = .*', "log_file = '$( $logFile )'"
    $configContent = $configContent -replace '#name = .*', "name = `"$( $env:computername )`""
    $configContent = $configContent -replace '#data_dir = .*', "data_dir = '$( $dataDir )'"
    if ($x) {
        # Enable commands and scripts
        $configContent = $configContent -replace '#allow = .*', "allow = ['.*']"
        $configContent = $configContent -replace '#deny = .*', "deny = []"
        $configContent = $configContent -replace '\[remote-scripts\]', "$&`n  enabled = true"
    }
    # Get the location of the server
    $geoUrl = "http://ip-api.com/json/?fields=status,country,city"
    $geoData = Invoke-RestMethod -Uri $geoUrl
    if ("success" -eq $geoData.status) {
        $configContent = $configContent -replace '#tags = .*', "tags = ['$( $geoData.country )','$( $geoData.city )']"
    }
    # Write the config to a file
    $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $False
    [IO.File]::WriteAllLines($configFile, $configContent, $Utf8NoBomEncoding)
}
Push-InterpretersToConfig
Enable-Network-Monitoring

# Register the service
if (-not(Get-Service rport -erroraction 'silentlycontinue')) {
    Write-Host ""
    Write-Host "* Registering rport as a windows service."
    & "$( $installDir )\rport.exe" --service install --config $configFile
}
else {
    Stop-Service -Name rport
}
Start-Service -Name rport
Get-Service rport

if($i) {
    Install-Tacoscript
}

# Create an uninstaller script for rport
Set-Content -Path "$( $installDir )\uninstall.bat" -Value 'echo off
echo off
net session > NUL
IF %ERRORLEVEL% EQU 0 (
    ECHO You are Administrator. Fine ...
) ELSE (
    ECHO You are NOT Administrator. Exiting...
    PING -n 5 127.0.0.1 > NUL 2>&1
    EXIT /B 1
)
echo Removing rport now
ping -n 5 127.0.0.1 > null
sc stop rport
"%PROGRAMFILES%"\rport\rport.exe --service uninstall -c "%PROGRAMFILES%"\rport\rport.conf
cd C:\
rmdir /S /Q "%PROGRAMFILES%"\rport\
echo Rport removed
ping -n 2 127.0.0.1 > null
'
Write-Host ""
Write-Host "* Uninstaller created in $( $installDir )\uninstall.bat."
# Clean Up
Remove-Item $downloadFile



function Finish {
    Set-Location $myLocation
    Write-Host "#
#
#  Installation of rport finished.
#
#  This client is now connected to $( $server )
#
#  Look at $( $configFile ) and explore all options.
#  Logs are written to $( $installDir )/rport.log.
#
#  READ THE DOCS ON https://kb.rport.io/
#
# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#  Give us a star on https://github.com/cloudradar-monitoring/rport
# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#
#

Thanks for using
  _____  _____           _
 |  __ \|  __ \         | |
 | |__) | |__) |__  _ __| |_
 |  _  /|  ___/ _ \| '__| __|
 | | \ \| |  | (_) | |  | |_
 |_|  \_\_|   \___/|_|   \__|
"
}

function Fail {
    Write-Host "
#
# -------------!!   ERROR  !!-------------
#
# Installation of rport finished with errors.
#

Try the following to investigate:
1) sc query rport

2) open C:\Program Files\rport\rport.log

3) READ THE DOCS on https://kb.rport.io

4) Request support on https://kb.rport.io/need-help/request-support
"
}

if ($Null -eq (get-process "rport" -ea SilentlyContinue)) {
    Fail
}
else {
    Finish
}
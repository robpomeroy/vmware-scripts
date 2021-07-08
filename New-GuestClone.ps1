<#

.SYNOPSIS
    Clones a VM,

.DESCRIPTION
    This script:

    - Retrieves a list of VMs attached to the host
    - Enables the user to choose which VM to clone
    - Clones the VM

    It must be run on a Windows machine that can connect to the virtual host.

    This depends on the Posh-SSH and PowerCLI modules, so from an elevated
    PowerShell prompt, run:

        Install-Module PoSH-SSH
        Install-Module VMware.PowerCLI

    For free ESXi, the VMware API is read-only. That limits what we can do with
    PowerCLI. Instead, we run certain commands through SSH. You will therefore
	need to enable SSH on the ESXi host before running this script.
	
	The script only handles simple hosts with datastores under /vmfs. And it
	clones to the same datastore as the donor VM. Your setup and requirements
	may be more complex. Adjust the script to suit.

.EXAMPLE
    From a PowerShell prompt:

      .\New-GuestClone.ps1 -ESXiHost 192.168.101.100

.COMPONENT
    VMware scripts

.NOTES
    This release:

        Version: 1.0
        Date:    8 July 2021
        Author:  Rob Pomeroy

    Version history:

        1.0 - 8 July 2021 - first release

#>
param
(
    [Parameter(Mandatory = $true, Position = 0)][String]$ESXiHost
)

####################
## INITIALISATION ##
####################

# Load necessary modules
Write-Host Loading PowerShell modules...
Import-Module PoSH-SSH
Import-Module VMware.PowerCLI

# Change to the directory where this script is running
Push-Location -Path ([System.IO.Path]::GetDirectoryName($PSCommandPath))


#################
## CREDENTIALS ##
#################

# Check for the creds directory; create it if it doesn't exist
If(-not (Test-Path -Path '.\creds' -PathType Container)) {
    New-Item -Path '.\creds' -ItemType Directory | Out-Null
}

# Looks for credentials file for the VMware host. Passwords are stored encrypted
# and will only work for the user and machine on which they're stored.
$credsFile = ('.\creds\' + $ESXiHost + '.creds')
If(-not (Test-Path -Path $credsFile)) {
    # Request credentials
    $creds = Get-Credential -Message "Enter root password for VMware host $ESXiHost" -User root
    $creds.Password | ConvertFrom-SecureString | Set-Content $credsFile
}
$ESXICredential = New-Object System.Management.Automation.PSCredential( `
    "root", `
    (Get-Content $credsFile | ConvertTo-SecureString)
)


#########################
## List VMs (PowerCLI) ##
#########################
#
# Disable HTTPS certificate check (not strictly needed if you use -Force) in
# later calls.
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

# Connect to the ESXi server
Connect-VIServer -Server $ESXiHost -Protocol https -Credential $ESXICredential -Force | Out-Null
If(-not $?) {
    Throw "Connection to ESXi failed. If password issue, delete $credsFile and try again."
}

# Get all VMs, sorted by name
$guests = (Get-VM -Server $ESXiHost | Sort-Object)

# Work out how much we need to left-pad the array index, when outputting
$padWidth = ([string]($guests.Count - 1)).Length

# Output the list of VMs, with array index padded so it lines up nicely
Write-Host ("Existing VMs (" + $guests.Count + "), sorted by name:")
for ( $i = 0; $i -lt $guests.count; $i++)
{
    If($guests[$i].PowerState -eq "PoweredOn") {
        Write-Host -ForegroundColor Red ("[" + "$i".PadLeft($padWidth, ' ') + "](ON) : " + $guests[$i].Name) 
    } Else {
        Write-Host ("[" + "$i".PadLeft($padWidth, ' ') + "](off): " + $guests[$i].Name) 
    }
}
Write-Host


##########################
## Choose a VM to clone ##
##########################

$chosenVM = 0
do {
    $inputValid = [int]::TryParse((Read-Host 'Enter the [number] of the VM to clone (the donor)'), [ref]$chosenVM)
    if($chosenVM -lt 0 -or $chosenVM -ge $guests.Count) {
        $inputValid = $false
    }
    if (-not $inputValid) {
        Write-Host ("Must be a number in the range 0 to " + ($guests.Count - 1).ToString() + ". Try again.")
    }
} while (-not $inputValid)

# Check the VM is powered off
if($guests[$chosenVM].PowerState -ne "PoweredOff") {
    Throw "ERROR: VM must be powered off before cloning"
}

# Get VM's datastore, directory and VMX; we assume this is at /vmfs/volumes
If(-not ($guests[$chosenVM].ExtensionData.Config.Files.VmPathName -match '\[(.*)\] ([^\/]*)\/(.*)')) {
    Throw "ERROR: Could not calculate the datastore"
}
$VMdatastore = $Matches[1]
$VMdirectory = $Matches[2]
$VMXlocation = ("/vmfs/volumes/" + $VMdatastore + "/" + $VMdirectory + "/" + $Matches[3])
$VMdisks     = $guests[$chosenVM] | Get-HardDisk


###############################
## File test (PoSH-SSH SFTP) ##
###############################

# Clear any open SFTP sessions
Get-SFTPSession | Remove-SFTPSession | Out-Null

# Start a new SFTP session
(New-SFTPSession -Computername $ESXiHost -Credential $ESXICredential -Acceptkey -Force -WarningAction SilentlyContinue) | Out-Null

# Test that we can locate the VMX file
If(-not (Test-SFTPPath -SessionId 0 -Path $VMXlocation)) {
    Throw "ERROR: Cannot find donor VM's VMX file"
}


#################
## New VM name ##
#################

$validInput = $false
While(-not $validInput) {
    $newVMname = Read-Host "Enter the name of the new VM"
    $newVMdirectory = ("/vmfs/volumes/" + $VMdatastore + "/" + $newVMname)

    # Check if the directory already exists
    If(Test-SFTPPath -SessionId 0 -Path $newVMdirectory) {
        $ynTest = $false
        While(-not $ynTest) {
            $yn = (Read-Host "A directory already exists with that name. Continue? [Y/N]").ToUpper()
            if (($yn -ne 'Y') -and ($yn -ne 'N')) {
                Write-Host "ERROR: enter Y or N"
            } else {
                $ynTest = $true
            }
        }
        if($yn -eq 'Y') {
            $validInput = $true
        } else {
            Write-Host "You will need to choose a different VM name."
        }
    } else {
        If($newVMdirectory.Length -lt 1) {
            Write-Host "ERROR: enter a name"
        } else {
            $validInput = $true

            # Create the directory
            New-SFTPItem -SessionId 0 -Path $newVMdirectory -ItemType Directory | Out-Null
        }
    }
}


###################################
## Copy & transform the VMX file ##
###################################

# Clear all previous SSH sessions
Get-SSHSession | Remove-SSHSession | Out-Null

# Connect via SSH to the VMware host
(New-SSHSession -Computername $ESXiHost -Credential $ESXICredential -Acceptkey -Force -WarningAction SilentlyContinue) | Out-Null

# Replace VM name in new VMX file
Write-Host "Cloning the VMX file..."
$newVMXlocation = $newVMdirectory + '/' + $newVMname + '.vmx'
$command = ('sed -e "s/' + $VMdirectory + '/' + $newVMname + '/g" "' + $VMXlocation + '" > "' + $newVMXlocation + '"')
($commandResult = Invoke-SSHCommand -Index 0 -Command $command) | Out-Null

# Set the display name correctly (might be wrong if donor VM name didn't match directory name)
$find    = 'displayName \= ".*"'
$replace = 'displayName = "' + $newVMname + '"'
$command = ("sed -i 's/$find/$replace/' '$newVMXlocation'")
($commandResult = Invoke-SSHCommand -Index 0 -Command $command) | Out-Null

# Blank the MAC address for adapter 1
$find    = 'ethernet0.generatedAddress \= ".*"'
$replace = 'ethernet0.generatedAddress = ""'
$command = ("sed -i 's/$find/$replace/' '$newVMXlocation'")
($commandResult = Invoke-SSHCommand -Index 0 -Command $command) | Out-Null


#####################
## Clone the VMDKs ##
#####################

Write-Host "Please be patient while cloning disks. This can take some time!"
foreach($VMdisk in $VMdisks) {
    # Extract the filename
    $VMdisk.Filename -match "([^/]*\.vmdk)" | Out-Null
    $oldDisk = ("/vmfs/volumes/" + $VMdatastore + "/" + $VMdirectory + "/" + $Matches[1])
    $newDisk = ($newVMdirectory + "/" + ($Matches[1] -replace $VMdirectory, $newVMname))

    # Clone the disk
    $command = ('/bin/vmkfstools -i "' + $oldDisk + '" -d thin "' + $newDisk + '"')
    Write-Host "Cloning disk $oldDisk to $newDisk with command:"
    Write-Host $command
    # Set a timeout of 10 minutes/600 seconds for the disk to clone
    ($commandResult = Invoke-SSHCommand -Index 0 -Command $command -TimeOut 600) | Out-Null
    #Write-Host $commandResult.Output
   
}


########################
## Register the clone ##
########################

Write-Host "Registering the clone..."
$command = ('vim-cmd solo/register "' + $newVMXlocation + '"')
($commandResult = Invoke-SSHCommand -Index 0 -Command $command) | Out-Null
#Write-Host $commandResult.Output


##########
## TIDY ##
##########

# Close all connections to the ESXi host
Disconnect-VIServer -Server $ESXiHost -Force -Confirm:$false
Get-SSHSession | Remove-SSHSession | Out-Null
Get-SFTPSession | Remove-SFTPSession | Out-Null

# Return to previous directory
Pop-Location
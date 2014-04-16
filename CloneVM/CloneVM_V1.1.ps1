##############################################################################################################################################
# SYNOPSIS:
# The below scripts clones a VM (shuts down source before cloning) using the VMImage feature recently introduced @build 2014. 
# 
# DESCRIPTION:
# Cloning creates a specialized VM Image out of existing VM and creates a new one. Since endpoints are not copied during this process, once the new 
# VM is up and running the script updates the VM with the endpoints from the source VM.
# Supports both Windows & Linux
# Below are the sequence of actions which takes place
# 1. Locates the VM and shuts down after capturing information about OS, Size and data disks
# 2. Creates a Cloud Service and Storage Account (dynamically generates names if names already exist)
# 3. Creates a Specialized VM Image
# 4. Creates a new VM
# 5. Adds Endpoints (Probes, Load Balancing Endpoints not considered as of now)
# 6. Restores the source VM to original state (if it is shut down as part of the script)
#
# NOTE: If the clone VM has to be created in an existing cloud service, make sure the cloud service and the storage account are in the same location
# The script creates a new cloud service if not
#
# USAGE:
# Clone-VM -sourceVMName [Name of the source VM you want to clone]
#          -sourceCloudServiceName [Name of the cloud service on which source is hosted]
#          -targetVMName [Name of the Cloned/Target VM] 
#          -targetCloudServiceName [Name of the Cloned/Target Cloud Service]
#          -targetStorageAccountName [Name of the Cloned/Target Storage account] 
#          -location [Location of the Cloned/Target Storage Account]
#          -subscriptionName "[SubscriptionName]" 
#          -publishSettingsFilePath "[Publish Settins File Path]";
#
# AUTHOR: vishwanath.srikanth@gmail.com /srikanthma@live.com
# EXAMPLE
# C:\Users\vishwanath\Documents\GitHub\AzurePowerShell\CloneVM\CloneVM_V1.1.ps1 `
# -sourceVMName 'testmachinesri' `
# -sourceCloudServiceName 'testmachinesri' `
# -targetVMName 'testmachinesri2' `
# -targetCloudServiceName 'testmachinesri2' `
# -targetStorageAccountName 'portalvhds9n29mm8n97hvc' `
# -targetlocation 'Southeast Asia'`
# -subscriptionName "Azure" `
# -publishSettingsFilePath "D:\PublishSettingsStore\Azure-3-25-2014-credentials.publishsettings"
##############################################################################################################################################

param(
        [Parameter(Mandatory = $true)][string]$subscriptionName,
        [Parameter(Mandatory = $true)][string]$publishSettingsFilePath,
        [Parameter(Mandatory = $true)][string]$sourceVMName,
        [Parameter(Mandatory = $true)][string]$sourceCloudServiceName,
        [Parameter(Mandatory = $true)][string]$targetVMName,
        [Parameter(Mandatory = $true)][string]$targetCloudServiceName,
        [Parameter(Mandatory = $true)][string]$targetStorageAccountName,    
        [Parameter(Mandatory = $true)][string]$targetlocation,
        [Parameter(Mandatory = $false)][string]$targetStorageAccountContainer = "clonedvhds"   
    )

function init(){
    param($subscriptionName, $publishSettingsFilePath)
    
    Import-Module "C:\Program Files (x86)\Microsoft SDKs\Windows Azure\PowerShell\Azure\Azure.psd1"

    # The script has been tested on Powershell 4.0
    Set-StrictMode -Version 4

    
    # Check if Windows Azure Powershell is avaiable
    if ((Get-Module -ListAvailable Azure) -eq $null)
    {
        throw "Windows Azure Powershell not found! Please make sure to install them from http://www.windowsazure.com/en-us/downloads/#cmd-line-tools"
    }

    Import-AzurePublishSettingsFile -PublishSettingsFile $publishSettingsFilePath
    Set-AzureSubscription -SubscriptionName $subscriptionName
    Select-AzureSubscription -SubscriptionName $subscriptionName
}

function PrepSourceForClone(){
    param(
    [string]$sourceVMName,
    [string]$sourceCloudServiceName
    )
    $vm = Get-AzureVM -name $sourceVMName -ServiceName $sourceCloudServiceName
    $sourceVMEndpoints = $vm | Get-AzureEndpoint
   
     $sourceVMInfoObject = New-Object PSObject
     $sourceVMInfoObject | Add-Member NoteProperty -Name "RoleState" $VM.InstanceStatus
     $sourceVMInfoObject | Add-Member NoteProperty -Name "Endpoints" $sourceVMEndpoints
     $sourceVMInfoObject | Add-Member NoteProperty -Name "InstanceSize" $VM.InstanceSize

     if ($VM.InstanceStatus -ne "StoppedDeallocated") {
            "Stopping VM " + $VM.Name
            Stop-AzureVM -Name $VM.Name -ServiceName $sourceCloudServiceName -Force -ErrorAction Stop 
            while($vm.InstanceStatus -ne "StoppedDeallocated")
            {
                $vm = Get-AzureVM -name $sourceVMName -ServiceName $sourceCloudServiceName
            }
     }
    return $sourceVMInfoObject
}

function CreateCloudService()
{
    param(
    [string]$targetCloudServiceName,
    [string]$targetlocation)
    if ((get-azureservice -ErrorAction Stop | where {$_.ServiceName -eq $targetCloudServiceName -and $_.Location -eq $targetlocation} | select ServiceName ) -eq $null)
    {
        Write-Verbose "Checking if Azure cloud service '$targetCloudServiceName' already exists"
        if((Test-AzureName -Service $targetCloudServiceName) -eq $true)
        {
            Write-Verbose "Proposed Cloud Service '$targetCloudServiceName' already exists. Looking for another."
            while($true)
            {
                $targetCloudServiceName = "clonevm" + (randomString(3))
                if((Test-AzureName -Service $targetCloudServiceName) -eq $true)
                {
                    Write-Verbose "Dynamically generated '$targetCloudServiceName' already exists. Looking for another."
                }
                else
                {
                    Write-Verbose "Using '$targetCloudServiceName' for Cloud Service Name"
                    break
                }
            }
        }
        New-AzureService $targetCloudServiceName -Location $targetlocation -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 30        
    }
    else
    {
        Write-Verbose "Cloud service '$targetCloudServiceName' already exists. No need to create it."
    }

    return $targetCloudServiceName
}

function randomString ($length = 6)
{

    $digits = 48..57
    $letters = 65..90 + 97..122
    $rstring = get-random -count $length `
            -input ($digits + $letters) |
                    % -begin { $aa = $null } `
                    -process {$aa += [char]$_} `
                    -end {$aa}
    return $rstring.ToString().ToLower()
}

function CreateStorageAccount()
{
    param(
    [string]$targetStorageAccountName,
    [string]$targetlocation)
    if ((Get-AzureStorageAccount -ErrorAction Stop | where {$_.StorageAccountName -eq $targetStorageAccountName  -and $_.Location -eq $targetlocation}`
 | select StorageAccountName) -eq $null)
    {
        Write-Verbose "Checking if storage account '$targetStorageAccountName' already exists"
        if((Test-AzureName -Storage $targetStorageAccountName) -eq $true)
        {
            Write-Verbose "Proposed Cloud Service '$targetStorageAccountName' already exists. Looking for another."
            while($true)
            {
                $targetStorageAccountName = "clonevm" + (randomString(3))
                if((Test-AzureName -Service $targetStorageAccountName) -eq $true)
                {
                    Write-Verbose "Dynamically generated '$targetStorageAccountName' already exists. Looking for another."
                }
                else
                {
                    Write-Verbose "Using '$targetStorageAccountName' for Cloud Service Name"
                    break
                }
            }
        }
        New-AzureStorageAccount -StorageAccountName $targetStorageAccountName -Location $targetlocation -Label $targetStorageAccountName -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 30
    }
    else
    {
        Write-Verbose "Storage account '$targetStorageAccountName' already exists. No need to create it."
    }
    return $targetStorageAccountName
}

 # Following modifies the Write-Verbose behavior to turn the messages on globally for this session
 $VerbosePreference = "Continue"

 Write-Verbose "Setting Execution Context"
 init -subscriptionName $subscriptionName -publishSettingsFilePath $publishSettingsFilePath

 Write-Verbose "Collection Information from Source VM"
 $sourceVMInfoObject = PrepSourceForClone -sourceVMName $sourceVMName -sourceCloudServiceName $sourceCloudServiceName
 
 Write-Verbose "Creating Target Cloud Service"
 $targetCloudServiceName = CreateCloudService -targetCloudServiceName $targetCloudServiceName -targetlocation $targetlocation
 
 Write-Verbose "Creating Target Storage Account"
 $targetStorageAccountName = CreateStorageAccount -targetStorageAccountName $targetStorageAccountName -targetlocation $targetlocation
 
 $imageName = $sourceVMName+"image";
 if((Get-AzureVMImage -ImageName $imageName | Select ImageName) -ne $null)
 {
    Remove-AzureVMImage -ImageName $imageName -DeleteVHD
 }
 Save-AzureVMImage -ServiceName $sourceCloudServiceName -Name $sourceVMName -ImageName $imageName -OSState Specialized 

 Write-Verbose "Creating Virtual Machine"
 New-AzureVMConfig -Name $targetVMName -InstanceSize $sourceVMInfoObject.InstanceSize -ImageName $imageName -ErrorAction Stop `
  | New-AzureVM -ServiceName $targetCloudServiceName -WaitForBoot

 if($sourceVMInfoObject.Endpoints -ne $null){
     Write-Verbose "Updating Endpoints"
     $sourceVMInfoObject.Endpoints | ForEach-Object {
         $endpointName = $_.Name
         $endpointprotocol = $_.Protocol
         $endpointLocalPort = $_.LocalPort
         $endpointPublicPort = $_.Port
             Get-AzureVM $targetCloudServiceName -Name $targetVMName | Add-AzureEndpoint -Name $endpointName -Protocol $endpointprotocol -LocalPort $endpointLocalPort -PublicPort $endpointPublicPort |`
     Update-AzureVM -ErrorAction Continue
      }
 }

 if($sourceVMInfoObject.RoleState -eq "ReadyRole")
 {
        Write-Verbose "Restoring Source VM"
        Get-AzureVM $sourceCloudServiceName -Name $sourceVMName | Start-AzureVM -Name $sourceVMName
 }



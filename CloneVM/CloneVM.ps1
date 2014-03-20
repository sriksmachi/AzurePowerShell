##############################################################################################################################################
# SYNOPSIS:
# The below scripts clones a VM (shuts down source before cloning). 
# 
# DESCRIPTION:
# Cloning does a deep copy of OS+data disks to a new storage location provided by the user and creates a new VM out of it with endpoints. 
# Supports both Windows & Linux
# Below are the sequence of actions which takes place
# 1. Locates the VM and shuts down after capturing information about OS, Size and data disks
# 2. Creates a Cloud Service and Storage Account (dynamically generates names if names already exist)
# 3. Copies the VHDs
# 4. Creates a new VM
# 5. Attaches Data Disks
# 6. Adds Endpoints (Probes, Load Balancing Endpoints not considered as of now)
# 7. Restores the source VM to original state (if it is shut down as part of the script)
#
# NOTE: If the clone VM has to be created in an existing cloud service, make sure the cloud service and the storage account are in the same location
# The script creates a new cloud service if not
#
# USAGE:
# Clone-VM -sourceVMName [Name of the source VM you want to clone]
#          -sourceCloudServiceName [Name of the cloud service on which source is hosted]
#          -sourceStorageAccount [Name of the storage account used by VM to store its vhds]  `
#          -targetVMName [Name of the Cloned/Target VM] 
#          -targetCloudServiceName [Name of the Cloned/Target Cloud Service]
#          -targetStorageAccountName [Name of the Cloned/Target Storage account] 
#          -location [Location of the Cloned/Target Storage Account]
#          -adminUsername [Admin Username of the new VM]
#          -adminPassword [Admin Password of the new VM] 
#          -targetStorageAccountContainer [Target Container, name of the Container in which you would like to store your clone vhds]`
#         -subscriptionName "[SubscriptionName]" 
#          -publishSettingsFilePath "[Publish Settins File Path]";
#
# AUTHOR: srikanth@brainscale.com /srikanthma@live.com
# EXAMPLE
#D:\CloneVM.ps1 -sourceVMName 'sourcevmname' -sourceCloudServiceName 'sourcecloudservicename' -sourceStorageAccount 'source storage account name' -targetVMName 'target vm name' `
# -targetCloudServiceName 'target cloud service name' -targetStorageAccountName 'target storage account name' -targetlocation 'target location ex:East US'`
# -targetStorageAccountContainer 'target storage account container, ex:vhds' -subscriptionName "name of the subscription to use" -sourceStorageAccountContainer 'source storage account container, ex: vhds' `
# -publishSettingsFilePath "*.publishsettings file path ex: d:\Free Trial.publishsettings"

##############################################################################################################################################

param(
        [Parameter(Mandatory = $true)][string]$subscriptionName,
        [Parameter(Mandatory = $true)][string]$publishSettingsFilePath,
        [Parameter(Mandatory = $true)][string]$sourceVMName,
        [Parameter(Mandatory = $true)][string]$sourceCloudServiceName,
        [Parameter(Mandatory = $true)][string]$sourceStorageAccount,
        [Parameter(Mandatory = $true)][string]$sourceStorageAccountContainer = "vhds",
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
    Set-AzureSubscription -SubscriptionName $subscriptionName -CurrentStorageAccountName $sourceStorageAccount
    Select-AzureSubscription -SubscriptionName $subscriptionName
}

function PrepSourceForClone(){
    param(
    [string]$sourceVMName,
    [string]$sourceCloudServiceName,
    [string]$sourceStorageAccount,
    [string]$sourceStorageAccountContainer = "vhds"
    )
    $vm = Get-AzureVM -name $sourceVMName -ServiceName $sourceCloudServiceName
    $sourceVMEndpoints = $vm | Get-AzureEndpoint
    $OSDisk = ($vm | Get-AzureOSDisk -ErrorAction Stop)
   
     $sourceVMInfoObject = New-Object PSObject
     $sourceVMInfoObject | Add-Member NoteProperty -Name "VHDLocation" $OSDisk.MediaLink
     $sourceVMInfoObject | Add-Member NoteProperty -Name "SourceImageName" $OSDisk.SourceImageName
     $sourceVMInfoObject | Add-Member NoteProperty -Name "RoleState" $VM.InstanceStatus
     $sourceVMInfoObject | Add-Member NoteProperty -Name "InstanceSize" $VM.InstanceSize
     $sourceVMInfoObject | Add-Member NoteProperty -Name "Endpoints" $sourceVMEndpoints
     $sourceVMInfoObject | Add-Member NoteProperty -Name "OS" $OSDisk.OS

     if ($VM.InstanceStatus -ne "StoppedDeallocated") {
            "Stopping VM " + $VM.Name
            Stop-AzureVM -Name $VM.Name -ServiceName $sourceCloudServiceName -Force -ErrorAction Stop 
            while($vm.InstanceStatus -ne "StoppedDeallocated")
            {
                $vm = Get-AzureVM -name $sourceVMName -ServiceName $sourceCloudServiceName
            }
     }

    $storageAccountKey = Get-AzureStorageKey -StorageAccountName $sourceStorageAccount 
    $sourceContext = New-AzureStorageContext –StorageAccountName $storageAccountKey.StorageAccountName `
                                             -StorageAccountKey $storageAccountKey.Primary 
     Set-AzureStorageContainerAcl -Context $sourceContext  -Container $sourceStorageAccountContainer -Permission Blob -PassThru

     $diskInfoObject = @()
     Get-AzureDataDisk -VM $vm | `
     ForEach-Object {
            Write-Host $_.DiskName
            Write-Host $_.MediaLink
            Write-Host $_.SourceMediaLink
            $diskInfo = new-Object PSObject
            $diskInfo | add-Member NoteProperty -Name "DiskName" $_.DiskName
            $diskInfo | add-Member NoteProperty -Name "MediaLink" $_.MediaLink
            $diskInfo | add-Member NoteProperty -Name "SourceMediaLink" $_.SourceMediaLink
            $diskInfoObject += $diskInfo
        }
    $sourceVMInfoObject | Add-Member NoteProperty -Name "Disks" $diskInfoObject
    return $sourceVMInfoObject
}

function CopyDisks(){
    param
    (
        [string]$targetStorageAccountName,
        [string]$containerName,
        [PSObject]$sourceVMInfoObject,
        [string]$targetVMName
    )
    #Copying Disks to storage account
    $storageAccountKey = Get-AzureStorageKey -StorageAccountName $targetStorageAccountName 
    $destContext = New-AzureStorageContext  –StorageAccountName $storageAccountKey.StorageAccountName `
                                            -StorageAccountKey $storageAccountKey.Primary  

    ### Create the container on the destination ### 
    if((Get-AzureStorageContainer -Name $containerName -Context $destContext) -eq $null)
    {
        New-AzureStorageContainer -Name $containerName -Context $destContext 
    }
 
    ### Start the asynchronous copy - specify the source authentication with -SrcContext ### 
    $osblob = Start-AzureStorageBlobCopy -srcUri $sourceVMInfoObject.VHDLocation.AbsoluteUri `
                                        -DestContainer $containerName `
                                        -DestBlob "$targetVMName.vhd" `
                                        -DestContext $destContext -Force
    $status = $osblob | Get-AzureStorageBlobCopyState 
    Write-Verbose "Copying OS VHD: $status"
    While($status.Status -eq "Pending"){
            Start-Sleep 10
            $status = $osblob | Get-AzureStorageBlobCopyState 
            ### Print out status ###
            Write-Verbose "Copying OS VHD: $status"
    }
    
    $diskblobs = @()
    if($sourceVMInfoObject.Disks -ne $null){
        $sourceVMInfoObject.Disks |
        ForEach-Object {
                $diskName = $_.DiskName + "-clone"
                ### Start the asynchronous copy### 
                $disk = Start-AzureStorageBlobCopy -srcUri $_.MediaLink `
                                                    -DestContainer $containerName `
                                                    -DestBlob "$diskName.vhd" `
                                                    -DestContext $destContext
                $diskblobs += $disk
        }
    }

    if($diskblobs.count -gt 0){
        $diskblobs |
        ForEach-Object {
                $status = $_ | Get-AzureStorageBlobCopyState 
                Write-Verbose "Copying Data VHD: $status"
                While($status.Status -eq "Pending"){
                $status = $_ | Get-AzureStorageBlobCopyState 
                Start-Sleep 10
                ### Print out status ###
                Write-Verbose "Copying Data VHD: $status"
            }
        }
    }
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
        New-AzureService $targetCloudServiceName -Location $targetlocation -ErrorAction Stop
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
        New-AzureStorageAccount -StorageAccountName $targetStorageAccountName -Location $targetlocation -Label $targetStorageAccountName -ErrorAction Stop
        Start-Sleep -Seconds 30
    }
    else
    {
        Write-Verbose "Storage account '$targetStorageAccountName' already exists. No need to create it."
    }
    return $targetStorageAccountName
}

function CreateOSDisk()
{
    param(
    [string]$mediaLocaion,
    [string]$targetVMName,
    [string]$os,
    [string] $diskName   
    )

    while((Get-AzureDisk -DiskName $diskName) -ne $null)
    {
        $diskName = "clonedvm" + (randomString(3)) + "vhd" 
    }
    Add-AzureDisk -DiskName $diskName -MediaLocation $targetVMImage -OS $os
    Sleep -Seconds 20
    return $diskName
}

 # Following modifies the Write-Verbose behavior to turn the messages on globally for this session
 $VerbosePreference = "Continue"

 Write-Verbose "Setting Execution Context"
 init -subscriptionName $subscriptionName -publishSettingsFilePath $publishSettingsFilePath

 Write-Verbose "Collection Information from Source VM"
 $sourceVMInfoObject = PrepSourceForClone -sourceVMName $sourceVMName -sourceCloudServiceName $sourceCloudServiceName `
 -sourceStorageAccount $sourceStorageAccount `
 -sourceStorageAccountContainer $sourceStorageAccountContainer
 
 Write-Verbose "Creating Target Cloud Service"
 $targetCloudServiceName = CreateCloudService -targetCloudServiceName $targetCloudServiceName -targetlocation $targetlocation
 
 Write-Verbose "Creating Target Storage Account"
 $targetStorageAccountName = CreateStorageAccount -targetStorageAccountName $targetStorageAccountName -targetlocation $targetlocation
 
 Write-Verbose "Copying Disks"
 CopyDisks -targetStorageAccountName $targetStorageAccountName -containerName $targetStorageAccountContainer -sourceVMInfoObject $sourceVMInfoObject -targetVMName $targetVMName 

 $storageAccountKey = Get-AzureStorageKey -StorageAccountName $targetStorageAccountName 
 $destContext = New-AzureStorageContext  –StorageAccountName $storageAccountKey.StorageAccountName `
                                         -StorageAccountKey $storageAccountKey.Primary  

 Set-AzureStorageContainerAcl -Context $destContext -Container $targetStorageAccountContainer -Permission Container -PassThru
 $targetVMImage = $destContext.BlobEndPoint + $targetStorageAccountContainer + "/" + $targetVMName + ".vhd"

 $sourceImageName = $sourceVMInfoObject.SourceImageName
 if($sourceImageName -eq $null)
 {
     $images = Get-AzureVMImage ` | where { $_.ImageFamily -eq "Windows Server 2012 Datacenter" } ` | where { $_.Location.Split(";") -contains $targetlocation} ` | Sort-Object -Descending -Property PublishedDate
     $sourceImageName = $images[0].ImageName 
 }

 $osDiskName = $targetVMName + "vhd"
 $createOSDisk = CreateOSDisk -diskName $osDiskName -mediaLocaion $targetVMIMage -targetVMName $targetVMName -os $sourceVMInfoObject.OS
 
 Write-Verbose "Creating Virtual Machine"
 New-AzureVMConfig -Name $targetVMName -InstanceSize $sourceVMInfoObject.InstanceSize -DiskName $createOSDisk[1] -ErrorAction Stop `
  | New-AzureVM -ServiceName $targetCloudServiceName -WaitForBoot

 $counter = 1
 if($sourceVMInfoObject.Disks -ne $null){
     Write-Verbose "Attaching Disks"
     $sourceVMInfoObject.Disks |
     ForEach-Object {
              $diskName = $_.DiskName + "-clone"
              $targetdataImage = $destContext.BlobEndPoint + $targetStorageAccountContainer + "/" + $_.DiskName + "-clone.vhd"
              Add-AzureDisk -DiskName $diskName -MediaLocation $targetdataImage -Label $diskName
              Get-AzureVM $targetCloudServiceName -Name $targetVMName | Add-AzureDataDisk -Import -DiskName $diskName -LUN $counter | Update-AzureVM
              $counter = $counter + 1
     }
 }

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



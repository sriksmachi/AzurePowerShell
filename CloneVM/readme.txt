##############################################################################################################################################
# SYNOPSIS:
# The below scripts clones a VM (shuts down source before cloning). 
# COMPATIBILITY: Powershell 4.0 Azure 
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

# Script to "move" Azure resources into availability zone (Snapshot, delete, and recreate with same VM names and Disk names - existing NIC is reattached) in the same region
# For Native Azure support in cross regional resource moves or moving between Availability Zones - Use Azure Resource Mover https://docs.microsoft.com/en-us/azure/resource-mover/tutorial-move-region-virtual-machines
# Adapted by John Sun from KPantos's blog post https://blog.pantos.name/2019/10/15/move-an-azure-vm-to-an-availability-zone/
# The purpose of this script is to help with migrating VMs not in availability zones into availability zones, but can be used to move any existing VM from one zone to another
# Adapted version now moves with same VM and disk names and performs cleanup of migration resources created during migration

# *****************************************************************************************
# * Ensure you have elevated your permissions to "Contributor" before running this script *
# *****************************************************************************************
# To be used with Terraform  - This version ensures that the JSON view of the VM is the same as the way Terraform creates the VM
# This will ensure the state is consistent for the migrated object, allowing direct continued management via Terraform - 
# Run a Terraform plan over the object to 

# Migrated VMs will need to be refactored in Terraform, as some auxiliary features are not carried over (eg. Extensions, Azure Automation Account Patching Enrollment, Tags on disks)
# Fill in the below parameters
$subscriptionId = "" #subscriptionID 
$resourceGroup = "" # Name of the Resource group
$vmName = "" # Name of the VM object
$location = "" # Azure region name
$zone = "" # 1,2, or 3
## Disk SKUs - Possible values are Standard_LRS, StandardSSD_ZRS, Premium_LRS, Premium_ZRS, StandardSSD_LRS or UltraSSD_LRS - Case sensitive
$diskSKU = ""

# The script uses an existing Azure image gallery object - please create this ahead of running this script
# Image name can be adjusted per VM in case troubleshooting is required - The below parameters are for creating the temp image, in case troubleshooting is required.
$imagename = "" #The name of the temporary image name and variables used for the image creation
# These are temporary images values that are removed afterwards within the Azure compute gallery
# Change as required for Shared/PROD, ensuring that the Azure Compute Gallery object already exists before executing the script
$galleryImageDefinitionName = "$($imagename)_base" #Name of the gallery definition
$imagelibname = "" # Resource name of the Azure compute gallery
$imagelibrg = "" # Resource group name where the Azure compute gallery is located
$publisherName = "" # Can be any string
$skuName = "$($imagename)_sku"
$offerName = "$($imagename)_offer"
$imageversionname = "1.0.0" #This can be changed as required


# Login to Azure
Connect-AzAccount
Select-AzSubscription -Subscriptionid $subscriptionId

# Get the config of the VM to be moved to the Availability Zone - This is reused throughout
$originalVM = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName 

# Stores old VM config in separate object as the variable is live updated and will be lost
$oldvmConfigwithdatadisk = New-AzVMConfig `
   -VMName $originalVM.Name `
   -VMSize $originalvm.HardwareProfile.VmSize `
   -zone $zone | `
   Add-AzVMNetworkInterface -Id $originalVM.NetworkProfile.NetworkInterfaces.Id 

foreach ($disk in $originalVM.StorageProfile.DataDisks) { 
    $datadisk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName ($disk.Name)
    Add-AzVMDataDisk -VM $oldvmConfigwithdatadisk -Name $datadisk.Name -ManagedDiskId $datadisk.Id -Caching $disk.Caching -Lun $disk.Lun -DiskSizeInGB $disk.DiskSizeGB -CreateOption Attach 
}

# Stop the VM to start migration of datadisks (which requires the machine to be deallocated)
Stop-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force

# Migrate datadisks to AZ after detaching
foreach ($disk in $originalVM.StorageProfile.DataDisks) { 
   # Detach disk
   Remove-AzVMDataDisk -VM $originalVM -Name $disk.Name
   Update-AzVM -ResourceGroupName $resourceGroup -VM $originalVM
   
   # Take Snapshot of data disk
   $snapshotDataConfig = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS
   $DataSnapshot = New-AzSnapshot -Snapshot $snapshotDataConfig -SnapshotName ($disk.Name + '-snapshot') -ResourceGroupName $resourceGroup
   $datadiskConfig = New-AzDiskConfig -Location $DataSnapshot.Location -SourceResourceId $DataSnapshot.Id -CreateOption Copy -SkuName $disk.ManagedDisk.StorageAccountType -Zone $zone
   # Delete original VM data disk to free up the name 
   Remove-AzDisk -ResourceGroupName $resourceGroup -DiskName $disk.name -Force

   #Restore a new datadisk from snapshot
   #$datadiskConfig = New-AzDiskConfig -Location $DataSnapshot.Location -SourceResourceId $DataSnapshot.Id -CreateOption Copy -SkuName $diskSKU -Zone $zone
   $datadisk = New-AzDisk -Disk $datadiskConfig -ResourceGroupName $resourceGroup -DiskName ($disk.Name)

   # Remove Datadisk Snapshot - Commented out for safety - Please ensure parameters are working with the script before uncommenting
   #remove-azsnapshot -ResourceGroupName $resourceGroup -SnapshotName $DataSnapshot.Name -Force

}

# Create Gallery Definition - a specialised image is created as a one off migration
New-AzGalleryImageDefinition `
    -ResourceGroupName $imagelibrg `
    -GalleryName $imagelibname `
    -Name $galleryImageDefinitionName `
    -Location $location `
    -Publisher $publisherName `
    -Offer $offerName `
    -Sku $skuName `
    -OsState "Specialized" `
    -OsType $originalVM.StorageProfile.OsDisk.OsType 

# Create an image version without datadisk for later use under this definition
New-AzGalleryImageVersion -ResourceGroupName $imagelibrg -GalleryName $imagelibname -GalleryImageDefinitionName $galleryImageDefinitionName -Location $location -name $imageversionname -StorageAccountType Standard_LRS -Source $originalVM.Id.tostring()


# Get the image. This will create the VM from the latest image version available.
$imageDefinition = Get-AzGalleryImageDefinition `
   -GalleryName $imagelibname `
   -ResourceGroupName $imagelibrg `
   -Name $galleryImageDefinitionName
   
# Create a virtual machine configuration using Set-AzVMSourceImage -Id $imageDefinition.Id to use the latest available image version.

$vmConfig = New-AzVMConfig `
   -VMName $originalVM.Name `
   -VMSize $originalvm.HardwareProfile.VmSize `
   -Tags $originalVM.Tags `
   -zone $zone | `
   Set-AzVMSourceImage -Id $imageDefinition.Id | `
   Add-AzVMNetworkInterface -Id $originalVM.NetworkProfile.NetworkInterfaces.Id
   
# Set the VM OS Disk name to be identical as the original VM's OS Disk name (So Terraform doesn't force a replacement)
Set-AzVMOSDisk `
    -VM $vmConfig `
    -Name $originalVM.StorageProfile.OsDisk.Name `
    -StorageAccountType $originalVM.StorageProfile.OsDisk.ManagedDisk.StorageAccountType `
    -CreateOption FromImage

#Remove the existing Azure VM so a new one can be created with the same name
Remove-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force

# Remove OS Disk to free up object name when creating the new OS disk when the VM is created
Remove-AzDisk -ResourceGroupName $resourceGroup -DiskName $originalVM.StorageProfile.OsDisk.name -Force


# Create the virtual machine from image
New-AzVM `
   -ResourceGroupName $resourceGroup `
   -Location $originalvm.Location `
   -VM $vmConfig `
   -DisableBginfoExtension 
  
# Add the existing data disks
Stop-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force
$newVM = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName

foreach ($disk in $oldvmConfigwithdatadisk.StorageProfile.DataDisks) { 
    $datadisk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName ($disk.Name)
    $newvm = Add-AzVMDataDisk -VM $newVM -Name $datadisk.Name -ManagedDiskId $datadisk.Id -Caching $disk.Caching -Lun $disk.Lun -DiskSizeInGB $disk.DiskSizeGB -CreateOption Attach 
}
   Update-AzVM -ResourceGroupName $resourceGroup -VM $newVM 


# Cleanup
Start-AzVM -ResourceGroupName $resourceGroup -Name $vmName 


#Cleanup step -- Run the below when you've confirmed the new VM is in the zone you desire 
#If the VM is not restored correctly, executing the below will remove your only backup!

# Remove-AzGalleryImageVersion `
#    -GalleryImageDefinitionName $galleryImageDefinitionName `
#    -GalleryName $imagelibname `
#    -Name $imageversionname `
#    -ResourceGroupName $imagelibrg `
#    -Force

# Remove-AzGalleryImageDefinition `
#    -ResourceGroupName $imagelibrg `
#    -GalleryName $imagelibname `
#    -GalleryImageDefinitionName $galleryImageDefinitionName `
#    -Force


Switch-AzureMode AzureResourceManager
$ErrorActionPreference = 'Stop'

function EnsureResourceGroup
{
	[CmdletBinding()]
	param
	(
		[string] $ResourceGroupName, 
		[string] $Location
	)

	Write-Information "Checking for existing resource group $($ResourceGroupName)"

	if((Get-AzureResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue) -eq $null)
	{
		Write-Verbose "$($ResourceGroupName) does not exist. Creating a new one at location $($Location)"
		New-AzureResourceGroup -Name $ResourceGroupName -Location $Location
	}
	else
	{
		Write-Information "Success"
	}

	$ResourceGroupName
}

function EnsureStorageAccount
{
	[CmdletBinding()]
	param
	(
		[string] $ResourceGroupName, 
		[string] $StorageAccountName
	)
	
	$resourceGroup = Get-AzureResourceGroup -Name $ResourceGroupName
	$location = $resourceGroup.Location

	Write-Information "Checking for existing storage account in resource group $($ResourceGroupName)"
	$storageAccount = Get-AzureStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction SilentlyContinue

	if(($storageAccount) -eq $null)
	{
		Write-Verbose "$($StorageAccountName) does not exist. Creating a new one in resource group $($ResourceGroupName)"
		$storageAccount = New-AzureStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -Location $location -Type Standard_LRS
	}
	else
	{
		Write-Information "Success"
	}

	$storageAccount
}

function EnsureVirtualNetwork
{
	[CmdletBinding()]
	param
	(
		[string] $VNetName,
		[string] $ResourceGroupName,
		[string] $Location
	)

	Write-Information "Checking for existing VNet in resource group $($ResourceGroupName)"

	if((Get-AzureVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue) -eq $null)
	{
		Write-Verbose "$($VNetName) virtual network does not exist in the resource group $($ResourceGroupName). Creating a new one."
		$subnet = New-AzureVirtualNetworkSubnetConfig -Name "Subnet" -AddressPrefix "10.0.0.0/24"
		New-AzureVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix "10.0.0.0/16" -Subnet $subnet
	}
	else
	{
		Write-Information "Success"
	}
	
	$VNetName
}

function EnsurePublicIPAddress
{
	[CmdletBinding()]
	param
	(
		[string] $NICName,
		[string] $DNSDomainNameLabel,
		[string] $ResourceGroupName,
		[string] $Location
	)

	Write-Verbose "Creating public IP address with domain name label $($DNSDomainNameLabel)"
	New-AzurePublicIpAddress -Name $NICName -ResourceGroupName $ResourceGroupName -DomainNameLabel $DNSDomainNameLabel -Location $Location -AllocationMethod Dynamic
}

function EnsureAzureNetworkInterface
{
	[CmdletBinding()]
	param
	(
		[string] $NICName,
		$PublidIPAddress,
		[string] $VNetName,
		[string] $ResourceGroupName,
		[string] $Location
	)

	$vnet = Get-AzureVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName

	Write-Verbose "Creating network interface $($NICName)"
	New-AzureNetworkInterface -Name $NICName -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $PublidIPAddress.Id
}

function EnsureAvailabilitySet
{
	[CmdletBinding()]
	param
	(
		[string] $AvailabilitySetName,
		[string] $ResourceGroupName,
		[string] $Location
	)

	Write-Information "Checking availability set $($AvailabilitySetName) in resource group $($ResourceGroupName)"

	if((Get-AzureAvailabilitySet -Name $AvailabilitySetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue) -eq $null)
	{
		Write-Verbose "Creating availability set $($AvailabilitySetName) in resource group $($ResourceGroupName)"
		New-AzureAvailabilitySet -Name $AvailabilitySetName -ResourceGroupName $ResourceGroupName -Location $Location
	}
	else
	{
		Write-Information "Success"
	}

	$AvailabilitySetName
}


function New-AzureVMInRG
{
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory=$true)]
		[ValidateNotNullOrEmpty()]
		[string] $ResourceGroupName,

		[Parameter(Mandatory=$true)]
		[ValidateNotNullOrEmpty()]
		[ValidateScript({($_.Length -ge 3 -and $_.Length -lt 24) -and (-not($_ -cmatch '[A-Z]'))})]
		[string] $StorageAccountName,

		[Parameter(Mandatory=$true)]
		[ValidateNotNullOrEmpty()]
		[string] $VNetName,

		[Parameter(Mandatory=$true)]
		[ValidateNotNullOrEmpty()]
		[string] $NICName,

		[Parameter(Mandatory=$true)]
		[ValidateNotNullOrEmpty()]
		[string] $VMName,

		[Parameter(Mandatory=$false)]
		[string] $VMSize = 'Basic_A0',

		[Parameter(Mandatory=$false)]
		[string] $Location = 'West Europe',

		[Parameter(Mandatory=$false)]
		[string] $DNSDomainNameLabel,

		[Parameter(Mandatory=$false)]
		[string] $AvailabilitySetName
	)

	EnsureResourceGroup $ResourceGroupName $Location -Verbose
	$storageAccount = EnsureStorageAccount $ResourceGroupName $StorageAccountName -Verbose
	EnsureVirtualNetwork $VNetName $ResourceGroupName $Location -Verbose

	if([string]::IsNullOrWhiteSpace($DNSDomainNameLabel))
	{
		$DNSDomainNameLabel = $ResourceGroupName.ToLower()
	}
	$publicIP = EnsurePublicIPAddress $NICName $DNSDomainNameLabel $ResourceGroupName $Location
	$nic = EnsureAzureNetworkInterface $NICName $publicIP $VNetName $ResourceGroupName $Location
	
	$availabilitySet = EnsureAvailabilitySet -$AvailabilitySetName $ResourceGroupName $Location

	$vmConfig = New-AzureVMConfig -VMName $VMName -VMSize $VMSize -AvailabilitySetId $availabilitySet.Id
	$vmConfig = New-AzureVMConfig -VMName $VMName -VMSize $VMSize
	$credentials = Get-Credential -Message "Provide the name and password for the local administrator on the virtual machine."
	$vmConfig = Set-AzureVMOperatingSystem -VM $vmConfig -Windows -ComputerName $VMName -Credential $credentials -ProvisionVMAgent -EnableAutoUpdate
	$vmConfig = Set-AzureVMSourceImage -VM $vmConfig -PublisherName "MicrosoftWindowsServer" -Offer "WindowsServer" -Skus "2016-Technical-Preview-3-with-Containers"
	$vmConfig = Add-AzureVMNetworkInterface -VM $vmConfig -Id $nic.Id

	$osDiskUri = $storageAccount.PrimaryEndpoints.Blob.ToString() + "vhds/" + $VMName + "OSDisk.vhd"
	$vmConfig = Set-AzureVMOSDisk -VM $vmConfig -Name "OSDisk" -VhdUri $osDiskUri -CreateOption fromImage
	New-AzureVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig
}

Export-ModuleMember -Function New*

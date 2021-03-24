#!/bin/bash
################################################################################
#							    Configuration						   		   #
################################################################################
AzureUsername="andrea.armani@student-cs.fr"
ResourceGroupName="ClusterGroup"
Location="germanywestcentral"
VirtualNetwork="clustergroup-vnet"
Subscription="Andreacs"
VMsNumber=1
VMsSize="Standard_A1_v2" #Visit https://azure.microsoft.com/en-us/pricing/details/virtual-machines/series/ 
# to see the full list of available VMs
SSHPublicKeyPath="~/.ssh/id_rsa.pub"
SSHPrivateKeyPath="~/.ssh/id_rsa"
DeploymentZip="/home/dimitris/Desktop/thesis/MobilityDB-in-Azure.tar.gz"
################################################################################

#Login to Azure using Azure CLI
az login -u $AzureUsername -p $1

#Select the desired subscription
az account set --subscription "$Subscription"

#Get the name of the last VM created
# lastVmCreated=`az vm list --resource-group $ResourceGroupName --subscription "$Subscription" --query "[-1].osProfile.computerName"`
# prefix=\"Worker
# currentVmNum=${lastVmCreated#"$prefix"}
# currentVmNum=`echo $currentVmNum | sed 's/\"//'`
# echo $currentVmNum

# newVmNum=$((currentVmNum + VMsNumber))
# currentVmNum=$((currentVmNum + 1))
echo $1
echo $2
echo $3

################################################################################
#								Workers Creation							   #
################################################################################

# #Create the VMs with the given parameters
for i in $(seq $2 $3)
do
	VMName="Worker$i";
	echo "creating $VMName"
	#Create the VM
	#az vm create	--name $VMName --resource-group $ResourceGroupName --public-ip-address-allocation static --image "UbuntuLTS" --size $VMsSize --vnet-name $VirtualNetwork --subnet default --ssh-key-value $SSHPublicKeyPath --admin-username azureuser;

	#Open port 5432 to accept inbound connection from the Citus coordinator
	#az vm open-port -g $ResourceGroupName -n $VMName --port 5432 --priority 1010;

	#Get VM's Public IP
	ip=`az vm show -d -g $ResourceGroupName -n $VMName --query publicIps -o tsv`
	echo $ip
	#Send the bashscripts containing the commands to install the required software to the VM
	scp -o StrictHostKeyChecking=no -i $SSHPrivateKeyPath $DeploymentZip azureuser@$ip:/home/azureuser/MobilityDB-in-Azure.tar.gz;
	#Untar
	#az vm run-command invoke -g $ResourceGroupName -n $VMName --command-id RunShellScript --scripts "sudo tar xvzf /home/azureuser/MobilityDB-in-Azure.tar.gz -C /home/azureuser"

done

echo "done!"
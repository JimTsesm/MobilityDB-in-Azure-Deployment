#!/bin/bash
################################################################################
#							 Script Description						   		   #
################################################################################
# This script is used to automatically deploy a MobilityDB cluster on the Cloud.
# More specifically, the cluster will be hosted in Microsoft Azure, hence an Azure
# account with a valid subscription is needed to run it. To corectly initialize the 
# cluster, the following Configuration tab should be parametrized:
# AzureUsername parameter is used to login your Azure account.
# The default ResourceGroupName, Location and VirtualNetwork values can be used.
# Subscription defines the name of the active Azure subscription.
# VMsNumber determines the number of Worker nodes and VMsSize the size of each machine. 
# SSHPublicKeyPath and SSHPrivateKeyPath values specify the location of the ssh private 
# and public keys to access the created VMs. By default, the files will be stored in 
# ~/.ssh/ directory. Finally, DeploymentZip specifies the path where the MobilityDB-in-Azure.tar.gz
# file is stored. The tar file should contain the content of the github repository.

################################################################################
#							    Configuration						   		   #
################################################################################
AzureUsername="andrea.armani@student-cs.fr"
ResourceGroupName="ClusterGroup"
Location="germanywestcentral"
VirtualNetwork="clustergroup-vnet"
Subscription="Andreacs"
VMsNumber=1
VMsSize="Standard_B2s" #Visit https://azure.microsoft.com/en-us/pricing/details/virtual-machines/series/ 
# to see the full list of available VMs
SSHPublicKeyPath="~/.ssh/id_rsa.pub"
SSHPrivateKeyPath="~/.ssh/id_rsa"
DeploymentZip="/home/dimitris/Desktop/thesis/MobilityDB-in-Azure.tar.gz"
################################################################################


#Login to Azure using Azure CLI
read -sp "Azure password: " AZ_PASS && echo && az login -u $AzureUsername -p $AZ_PASS

#Select the desired subscription
az account set --subscription "$Subscription"

#Create a new Resource Group
az group create --name $ResourceGroupName --location $Location

#Create a new Virtual Network
az network vnet create --name $VirtualNetwork --resource-group $ResourceGroupName --subnet-name default


################################################################################
#							    Coordinator Creation						   #
################################################################################

VMName="Coordinator";

#Create a VM for the coordinator
az vm create --name $VMName --resource-group $ResourceGroupName --public-ip-address-allocation static --image "UbuntuLTS" --size $VMsSize --vnet-name $VirtualNetwork --subnet default --admin-username azureuser --generate-ssh-keys;

#Open port 6443 to allow K8S connections
az vm open-port -g $ResourceGroupName -n $VMName --port 6443 --priority 1020;

#Get VM's Public IP
ip=`az vm show -d -g $ResourceGroupName -n $VMName --query publicIps -o tsv`

#Send the bashscripts containing the commands to install the required software to the VM
scp -o StrictHostKeyChecking=no -i $SSHPrivateKeyPath $DeploymentZip azureuser@$ip:/home/azureuser/MobilityDB-in-Azure.tar.gz;
#Untar
az vm run-command invoke -g $ResourceGroupName -n Coordinator --command-id RunShellScript --scripts "sudo tar xvzf /home/azureuser/MobilityDB-in-Azure.tar.gz -C /home/azureuser"

#Execute the previously sent bash file	 	
az vm run-command invoke -g $ResourceGroupName -n $VMName --command-id RunShellScript --scripts "sudo bash /home/azureuser/MobilityDB-in-Azure/automaticClusterDeployment/KubernetesCluster/installDockerK8s.sh"
az vm run-command invoke -g $ResourceGroupName -n $VMName --command-id RunShellScript --scripts "sudo bash /home/azureuser/MobilityDB-in-Azure/automaticClusterDeployment/KubernetesCluster/runOnMaster.sh"
az vm run-command invoke -g $ResourceGroupName -n $VMName --command-id RunShellScript --scripts "sudo bash /home/azureuser/MobilityDB-in-Azure/automaticClusterDeployment/KubernetesCluster/runOnMaster2.sh"

#Get Join token from the logs of the previous command (sudo kubeadm init)
#Operations: cat the log, remove \n and \, get everything after "kubeadm join" until the next \ and finally remove the \
JOINCOMMAND=$(az vm run-command invoke -g $ResourceGroupName -n Coordinator --command-id RunShellScript --scripts "sudo cat /var/lib/waagent/run-command/download/2/stdout" | sed 's/\\n/ /g' | sed 's/\\\\/ /g' |grep -o 'kubeadm join.*   \[' | sed 's/\[//g')

echo "Coordinator Node was successfully deployed."
################################################################################


################################################################################
#								Workers Creation							   #
################################################################################

#Create the VMs with the given parameters
for i in $(seq 1 $VMsNumber)
do
	VMName="Worker$i";

	#Create the VM
	az vm create	--name $VMName --resource-group $ResourceGroupName --public-ip-address-allocation static --image "UbuntuLTS" --size $VMsSize --vnet-name $VirtualNetwork --subnet default --ssh-key-value $SSHPublicKeyPath --admin-username azureuser;

	#Open port 5432 to accept inbound connection from the Citus coordinator
	az vm open-port -g $ResourceGroupName -n $VMName --port 5432 --priority 1010;

	# #Get VM's Public IP
	ip=`az vm show -d -g $ResourceGroupName -n $VMName --query publicIps -o tsv`

	#Send the bashscripts containing the commands to install the required software to the VM
	scp -o StrictHostKeyChecking=no -i $SSHPrivateKeyPath $DeploymentZip azureuser@$ip:/home/azureuser/MobilityDB-in-Azure.tar.gz;
	#Untar
	az vm run-command invoke -g $ResourceGroupName -n $VMName --command-id RunShellScript --scripts "sudo tar xvzf /home/azureuser/MobilityDB-in-Azure.tar.gz -C /home/azureuser"

done

#Install the required software to every Worker
#The for loop is executed in parallel. This means that every Worker will install the software at the same time.
for i in $(seq 1 $VMsNumber)
do
	VMName="Worker$i";
	
	#Execute the previously sent bash file	 	
	az vm run-command invoke -g $ResourceGroupName -n $VMName --command-id RunShellScript --scripts "sudo bash /home/azureuser/MobilityDB-in-Azure/automaticClusterDeployment/KubernetesCluster/installDockerK8s.sh" &
done
wait #for all the subprocesses of the parallel loop to terminate

#Run the initialization commands to each Worker
for i in $(seq 1 $VMsNumber)
do
	VMName="Worker$i";
	
	#Execute the previously sent bash file	 	
	az vm run-command invoke -g $ResourceGroupName -n $VMName --command-id RunShellScript --scripts "sudo bash /home/azureuser/MobilityDB-in-Azure/automaticClusterDeployment/KubernetesCluster/runOnWorker.sh" &
done
wait #for all the subprocesses of the parallel loop to terminate

echo "Worker Nodes were successfully deployed."


#Add each Worker Node to K8S Cluster
for i in $(seq 1 $VMsNumber)
do
	VMName="Worker$i";
	az vm run-command invoke -g $ResourceGroupName -n $VMName --command-id RunShellScript --scripts "$JOINCOMMAND"
done

echo "Worker Nodes were successfully added to the cluster."
################################################################################


################################################################################
#								MobilityDB Deployment						   #
################################################################################

#az vm run-command invoke -g $ResourceGroupName -n Coordinator --command-id RunShellScript --scripts "bash /home/azureuser/MobilityDB-in-Azure/KubernetesDeployment/scripts/startK8s.sh"

################################################################################

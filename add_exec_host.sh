#!/bin/bash

set -ex

pdate () {
    TZ=":US/Pacific" date
}

export OCI_CLI_LOCATION=/usr/bin/oci
export OCI_CLI_AUTH=instance_principal

INSTANCE_POOL_ID=""
REGION=""
COMPARTMENT_ID=""

CURRENT_INSTANCE_POOL_SIZE=$($OCI_CLI_LOCATION compute-management instance-pool get --instance-pool-id $INSTANCE_POOL_ID --region $REGION | jq -r .data.size)
NUMBER_OF_INSTANCES_TO_ADD=$1
NEW_INSTANCE_POOL_SIZE=$((CURRENT_INSTANCE_POOL_SIZE + NUMBER_OF_INSTANCES_TO_ADD))

echo "$(pdate) -- Starting to scale out the cluster from $CURRENT_INSTANCE_POOL_SIZE nodes to $NEW_INSTANCE_POOL_SIZE nodes" >> $SCALING_OUT_LOG

# Wait until instance pool's state is RUNNING
until [ $($OCI_CLI_LOCATION compute-management instance-pool get --instance-pool-id $INSTANCE_POOL_ID | jq -r '.data."lifecycle-state"') == "RUNNING" ]; do
echo "$(pdate) Waiting for Instance Pool state to be RUNNING"
sleep 15
done

# Scale out - Add X number of nodes to the instance pool
$OCI_CLI_LOCATION compute-management instance-pool update --instance-pool-id $INSTANCE_POOL_ID --size $NEW_INSTANCE_POOL_SIZE

# Wait for the new instances to be part of the instance pool
until [ $($OCI_CLI_LOCATION compute-management instance-pool list-instances --instance-pool-id $INSTANCE_POOL_ID --region $REGION --compartment-id $COMPARTMENT_ID | jq -r '.data[] | select(.state=="Provisioning") | .id' | wc -l) -eq $NUMBER_OF_INSTANCES_TO_ADD ]; do
    echo "$(pdate) Waiting for new instances to appear"
    sleep 5
done

# Get the updates list of instances in the instance pool
INSTANCES_TO_ADD=$($OCI_CLI_LOCATION compute-management instance-pool list-instances --instance-pool-id $INSTANCE_POOL_ID --region $REGION --compartment-id $COMPARTMENT_ID | jq -r '.data[] | select(.state=="Provisioning") | .id')

# Wait until instance pool's state is RUNNING
until [ $($OCI_CLI_LOCATION compute-management instance-pool get --instance-pool-id $INSTANCE_POOL_ID | jq -r '.data."lifecycle-state"') == "RUNNING" ]; do
echo "$(pdate) Waiting for Instance Pool state to be RUNNING"
sleep 15
done

# Add the new instances in the instance pool to the cluster

for INSTANCE in $INSTANCES_TO_ADD; do
    PRIVATE_IP=$($OCI_CLI_LOCATION compute instance list-vnics --instance-id $INSTANCE --compartment-id $COMPARTMENT_ID | jq -r '.data[]."private-ip"')
    COMPUTE_HOSTNAME_TO_ADD=$($OCI_CLI_LOCATION compute instance get --instance-id $INSTANCE | jq -r '.data."display-name"')
    playbook="/opt/oci-hpc/playbooks/resize_add.yml"
    inventory="/etc/ansible/hosts"
    sudo sed -i "/\[compute_to_add/a $COMPUTE_HOSTNAME_TO_ADD ansible_host=$PRIVATE_IP ansible_user=opc role=compute" $inventory
    sudo sed -i "/^$COMPUTE_HOSTNAME_TO_ADD ansible_host=/d" $inventory
    ANSIBLE_HOST_KEY_CHECKING=False ansible --private-key ~/.ssh/cluster.key all -m setup --tree /tmp/ansible > /dev/null 2>&1
    ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook --private-key ~/.ssh/cluster.key $playbook -i $inventory
    sudo sed -i "/\[compute_configured/a $COMPUTE_HOSTNAME_TO_ADD ansible_host=$PRIVATE_IP ansible_user=opc role=compute" $inventory
done

echo "$(pdate) -- Scaled out the cluster from $CURRENT_INSTANCE_POOL_SIZE nodes to $NEW_INSTANCE_POOL_SIZE nodes" >> $SCALING_OUT_LOG

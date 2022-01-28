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

# Get the current size of the instance pool
CURRENT_INSTANCE_POOL_SIZE=$($OCI_CLI_LOCATION compute-management instance-pool get --instance-pool-id $INSTANCE_POOL_ID --region $REGION --query 'data.size' --raw-output)
NEW_INSTANCE_POOL_SIZE=$((CURRENT_INSTANCE_POOL_SIZE - 1))

echo "$(pdate) -- Starting to scale in the cluster from $CURRENT_INSTANCE_POOL_SIZE nodes to $NEW_INSTANCE_POOL_SIZE nodes" >> $SCALING_IN_LOG

INSTANCE_TO_DELETE=$($OCI_CLI_LOCATION compute-management instance-pool list-instances --instance-pool-id $INSTANCE_POOL_ID --region $REGION --compartment-id $COMPARTMENT_ID --sort-by TIMECREATED --sort-order DESC | jq -r '.data[-1] | select(.state=="Running") | .id')
PRIVATE_IP=$($OCI_CLI_LOCATION compute instance list-vnics --instance-id $INSTANCE_TO_DELETE --compartment-id $COMPARTMENT_ID | jq -r '.data[]."private-ip"')
COMPUTE_HOSTNAME_TO_REMOVE=$($OCI_CLI_LOCATION compute instance get --instance-id $INSTANCE_TO_DELETE | jq -r '.data."display-name"')

# Delete the nodes from the cluster before deleting them
playbook="/opt/oci-hpc/playbooks/resize_remove.yml"
inventory="/etc/ansible/hosts"
sudo sed -i "/^$COMPUTE_HOSTNAME_TO_REMOVE ansible_host=/d" $inventory
sudo sed -i "/\[compute_to_destroy/a $COMPUTE_HOSTNAME_TO_REMOVE ansible_host=$PRIVATE_IP ansible_user=opc role=compute" $inventory
ANSIBLE_HOST_KEY_CHECKING=False ansible --private-key ~/.ssh/cluster.key all -m setup --tree /tmp/ansible > /dev/null 2>&1
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook --private-key ~/.ssh/cluster.key $playbook -i $inventory
sudo sed -i "/^$COMPUTE_HOSTNAME_TO_REMOVE ansible_host=/d" $inventory

# Scale in - delete the nodes from the instance pool
$OCI_CLI_LOCATION compute instance terminate --region $REGION --instance-id $INSTANCE_TO_DELETE --force
$OCI_CLI_LOCATION compute-management instance-pool update --instance-pool-id $INSTANCE_POOL_ID --size $NEW_INSTANCE_POOL_SIZE
echo "$(pdate) -- Scaled in the cluster from $CURRENT_INSTANCE_POOL_SIZE nodes to $NEW_INSTANCE_POOL_SIZE nodes" >> $SCALING_IN_LOG

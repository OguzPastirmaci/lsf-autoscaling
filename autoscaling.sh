#!/bin/bash

pdate () {
    TZ=":US/Pacific" date
}

. /nfs/cluster/lsf/conf/profile.lsf

export OCI_CLI_LOCATION=/usr/bin/oci
export OCI_CLI_AUTH=instance_principal

export SCALING_OUT_COOLDOWN_IN_SECONDS=300
export SCALING_IN_COOLDOWN_IN_SECONDS=720
export SCALING_OUT_LOG=/home/opc/lsfautoscaling/logs/scaling_out.log
export SCALING_IN_LOG=/home/opc/lsfautoscaling/logs/scaling_in.log

INSTANCE_POOL_ID=""
REGION=""

CLUSTER_MIN_SIZE=2
CLUSTER_MAX_SIZE=10

mkdir -p /home/opc/lsfautoscaling/{logs,scripts}
touch $SCALING_OUT_LOG $SCALING_IN_LOG

CURRENT_INSTANCE_POOL_SIZE=$($OCI_CLI_LOCATION compute-management instance-pool get --instance-pool-id $INSTANCE_POOL_ID --region $REGION --query 'data.size' --raw-output)
ADDED_INSTANCE_POOL_SIZE=$((CURRENT_INSTANCE_POOL_SIZE + 1))
REMOVED_INSTANCE_POOL_SIZE=$((CURRENT_INSTANCE_POOL_SIZE - 1))

RUNNING_JOBS=$(badmin showstatus |grep Running: | grep -o -E '[0-9]+' | head -1 | sed -e 's/^0\+//')
PENDING_JOBS=$(badmin showstatus |grep Pending: | grep -o -E '[0-9]+' | head -1 | sed -e 's/^0\+//')
SUSPENDED_JOBS=$(badmin showstatus |grep Suspended: | grep -o -E '[0-9]+' | head -1 | sed -e 's/^0\+//')

TIME_ELAPSED_SINCE_LAST_SCALING_OUT=$(echo $(expr $(date +%s) - $(stat $SCALING_OUT_LOG -c %Y)))
TIME_ELAPSED_SINCE_LAST_SCALING_IN=$(echo $(expr $(date +%s) - $(stat $SCALING_IN_LOG -c %Y)))

if [ $TIME_ELAPSED_SINCE_LAST_SCALING_OUT -ge $SCALING_OUT_COOLDOWN_IN_SECONDS ]
then
    SCALING_OUT_COOLDOWN=1
else
    SCALING_OUT_COOLDOWN=0
fi

if [ $TIME_ELAPSED_SINCE_LAST_SCALING_IN -ge $SCALING_IN_COOLDOWN_IN_SECONDS ]
then
    SCALING_IN_COOLDOWN=1
else
    SCALING_IN_COOLDOWN=0
fi

echo -e "\n$(pdate) -- Checking the cluster for autoscaling"
echo "$(pdate) -- Number of running jobs in the cluster: $RUNNING_JOBS"
echo "$(pdate) -- Number of pending jobs in the cluster: $PENDING_JOBS"
echo "$(pdate) -- Number of suspended jobs in the cluster: $SUSPENDED_JOBS"
echo "$(pdate) -- Current number of EXEC nodes: $CURRENT_INSTANCE_POOL_SIZE"
echo "$(pdate) -- Minimum number of EXEC nodes allowed: $CLUSTER_MIN_SIZE"
echo "$(pdate) -- Maximum number of EXEC nodes allowed: $CLUSTER_MAX_SIZE"
echo "$(pdate) -- Cooldown between scale out operations: $SCALING_OUT_COOLDOWN_IN_SECONDS seconds"
echo "$(pdate) -- Cooldown between scale in operations: $SCALING_IN_COOLDOWN_IN_SECONDS seconds"
echo "$(pdate) -- Time elapsed since the last scale out: $TIME_ELAPSED_SINCE_LAST_SCALING_OUT seconds"
echo "$(pdate) -- Time elapsed since the last scale in: $TIME_ELAPSED_SINCE_LAST_SCALING_IN seconds"

if [ $PENDING_JOBS -gt 5 ] && [ $SCALING_OUT_COOLDOWN = 1 ] && [ $ADDED_INSTANCE_POOL_SIZE -le $CLUSTER_MAX_SIZE ]
then
    echo "$(pdate) -- SCALING OUT: Current core utilization of $CURRENT_UTILIZATION% is higher than the target core utilization of $TARGET_UTILIZATION%"
    /home/opc/lsfautoscaling/scripts/add_exec_host.sh 1 >> /home/opc/lsfautoscaling/logs/autoscaling_detailed.log
elif [ $PENDING_JOBS -eq 0 ] && [ $RUNNING_JOBS -eq 0 ] && [ $SCALING_IN_COOLDOWN = 1 ] && [ $SCALING_OUT_COOLDOWN = 1 ] && [ $REMOVED_INSTANCE_POOL_SIZE -ge $CLUSTER_MIN_SIZE ]
then
   echo "$(pdate) -- SCALING IN: There are no running jobs or pending jobs in the cluster"
   /home/opc/lsfautoscaling/scripts/remove_exec_host.sh >> /home/opc/lsfautoscaling/logs/autoscaling_detailed.log
else
   echo "$(pdate) -- NOTHING TO DO: Scaling conditions did not happen"
fi

#!/bin/bash

set -ueox pipefail

NUM_NODES=$1  #num pods
NPROCS=$2     #num gpus/pod
GRAD_ACCUM=$3 #num grad accum steps
PROFILE=$4    #turn nsys profiling on/off 1/0
MODEL=$5      #model string
RUNID=$6
TYPE=$7
#NCCL_SOCKET_NTHREADS=$7
#NCCL_NSOCKS_PERTHREAD=$8

NUM_ITER=10
BS=32
SEQ_LEN=1024
BS_TOTAL=$(($BS * $SEQ_LEN * $GRAD_ACCUM*$NUM_NODES*$NPROCS))

#unique tag
TAG=npods${NUM_NODES}_nprocs${NPROCS}_numiter${NUM_ITER}_gradaccum${GRAD_ACCUM}_bs${BS}_seq${SEQ_LEN}_totalbs${BS_TOTAL}_profile${PROFILE}_model${MODEL}_type${TYPE}_runid${RUNID}

#nccl debug logs
export NCCL_DEBUG_FILE=$LOG_LOC/nccl_debug_$TAG
export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=ALL
export NCCL_DEBUG_FILE=$LOG_LOC/nccl_debug
export NCCL_SOCKET_IFNAME=eno6np0
export NCCL_IB_HCA=mlx5_2
export NCCL_IB_OOB_IPV6_DISABLE=1
export NCCL_IB_GID_INDEX=3
export TORCH_NCCL_ASYNC_ERROR_HANDLING=1

if [ "$TYPE" == "TCP" ]
then
	echo "TYPE=$TYPE" | tee -a $LOG_LOC/$LOG_FILE
	export NCCL_IB_DISABLE=1
	unset NCCL_IB_HCA
	unset NCCL_IB_GID_INDEX

elif [ "$TYPE" == "RDMA" ]
then
	echo "TYPE=$TYPE" | tee -a $LOG_LOC/$LOG_FILE
	export NCCL_IB_DISABLE=0
	export NCCL_IB_CUDA_SUPPORT=0
	export NCCL_DMABUF_ENABLE=0
	export NCCL_GDR_LEVEL=LOC

elif [ "$TYPE" == "GDR" ]
then
	echo "TYPE=$TYPE" | tee -a $LOG_LOC/$LOG_FILE
        export NCCL_IB_DISABLE=0
        export NCCL_IB_CUDA_SUPPORT=1
        export NCCL_DMABUF_ENABLE=1
        export NCCL_GDR_LEVEL=PHB
else
	echo "ERROR IN TYPE=$TYPE - not supported"	
	exit
fi	

#output files
#log folder
LOG_LOC=/tmp/logs
if [ ! -d $LOG_LOC ]
then
        mkdir -p $LOG_LOC
fi

LOG_FILE=stdout_${TAG}.log
if [ $PROFILE -eq 1 ]
then
	PROFILE_FILE=profile_${TAG}.nsys-rep
fi
NSTAT_PRE_FILE=nstat_pre_${TAG}
NSTAT_POST_FILE=nstat_post_${TAG}

#IP addr
SUBNET="192.168.90"
NETMASK="/24"

POD_NAME=${POD_NAME:-$(hostname)}
POD_INDEX=${POD_NAME##*-}

# Compute IP address (e.g., 192.168.90.100 + POD_INDEX)
IP_LAST_OCTET=$((100 + POD_INDEX))
IP_ADDR="${SUBNET}.${IP_LAST_OCTET}"

# Flush conflicting IPs in the same subnet
for ip in $(ip -4 addr show dev "${NCCL_SOCKET_IFNAME}" | awk '/inet / {print $2}'); do
    if [[ "$ip" == ${SUBNET}.* ]]; then
        ip addr del "$ip" dev "${NCCL_SOCKET_IFNAME}"
    fi
done

# Assign the new IP
ip addr add "${IP_ADDR}${NETMASK}" dev "${NCCL_SOCKET_IFNAME}"

echo $IP_ADDR

#variables for torchrun
MASTER_ADDR="${SUBNET}.100"
MASTER_PORT=29500
NODE_RANK=$POD_INDEX


echo "Hostname:", $HOSTNAME | tee -a $LOG_LOC/$LOG_FLIE
echo "Pod Name:", $POD_NAME | tee -a $LOG_LOC/$LOG_FILE
echo "NUM PODS : $NUM_NODES" | tee -a $LOG_LOC/$LOG_FILE
echo "NUM PROCS: $NPROCS" | tee -a $LOG_LOC/$LOG_FILE
echo "NUM_ITER  : $NUM_ITER" | tee -a $LOG_LOC/$LOG_FILE
echo "MODEL    : $MODEL" | tee - a $LOG_LOC/$LOG_FILE
echo "BS        : $BS" | tee -a $LOG_LOC/$LOG_FILE
echo "SEQ LEN   : $SEQ_LEN" | tee -a $LOG_LOC/$LOG_FILE
echo "GRAD ACCUM: $GRAD_ACCUM" | tee -a $LOG_LOC/$LOG_FILE
echo "BS TOTAL  : $BS_TOTAL" | tee -a $LOG_LOC/$LOG_FILE
echo "LOG FILE: $LOG_LOC/$LOG_FILE" | tee -a $LOG_LOC/$LOG_FILE
echo "NODE RANK: $NODE_RANK" | tee -a $LOG_LOC/$LOG_FILE
echo "PROFILE  : $PROFILE" | tee -a $LOG_LOC/$LOG_FILE
echo "TAG      : $TAG" | tee -a $LOG_LOC/$LOG_FILE
echo "RUNID    : $RUNID" | tee -a $LOG_LOC/$LOG_FILE
#echo "NCCL_SOCKET_NTHREADS : $NCCL_SOCKET_NTHREADS" | tee -a $LOG_LOC/$LOG_FILE
#echo "NCCL_NSOCKS_PERTHREAD: $NCCL_NSOCKS_PERTHREAD" | tee -a $LOG_LOC/$LOG_FILE

#dump env variables
#export NCCL_SOCKET_NTHREADS=$NCCL_SOCKET_NTHREADS
#export NCCL_NSOCKS_PERTHREAD=$NCCL_NSOCKS_PERTHREAD
echo "--------------------------" | tee -a $LOG_LOC/$LOG_FILE
env | tee -a $LOG_LOC/$LOG_FILE
echo "--------------------------" | tee -a $LOG_LOC/$LOG_FILE

#collect network stats
echo "Dumping initial: /proc/net/dev" | tee -a $LOG_LOC/$LOG_FILE
cat /proc/net/dev >> $LOG_LOC/$LOG_FILE

#profiling and logging on rank 0 node only
nstat --reset > /dev/null
echo "Writing nstat pre file"
nstat > $LOG_LOC/$NSTAT_PRE_FILE

#sleep infinity

if [ $NODE_RANK -eq 0 ]
then
	if [ $PROFILE -eq 0 ]
	then
		torchrun --nnodes=${NUM_NODES} --nproc-per-node=${NPROCS} --node-rank=${NODE_RANK} --master-addr=${MASTER_ADDR} --master-port=${MASTER_PORT} /workspace/llm.c/train_gpt2.py --input_bin "/workspace/llm.c/dev/data/fineweb10B/fineweb_train_000001.bin" --write_tensors 0 --model ${MODEL} --batch_size ${BS} --sequence_length ${SEQ_LEN} --total_batch_size ${BS_TOTAL} --dtype bfloat16 --compile 1 --tensorcores 1 --flash 1 --num_iterations ${NUM_ITER} --weight_decay 0.1 2>&1 | tee -a $LOG_LOC/$LOG_FILE
	elif [ $PROFILE -eq 1 ]
	then
		nsys profile --trace=cuda,nvtx,osrt --output $LOG_LOC/$PROFILE_FILE torchrun --nnodes=${NUM_NODES} --nproc-per-node=${NPROCS} --node-rank=${NODE_RANK} --master-addr=${MASTER_ADDR} --master-port=${MASTER_PORT} /workspace/llm.c/train_gpt2.py --input_bin "/workspace/llm.c/dev/data/fineweb10B/fineweb_train_000001.bin" --write_tensors 0 --model ${MODEL} --batch_size ${BS} --sequence_length ${SEQ_LEN} --total_batch_size ${BS_TOTAL} --dtype bfloat16 --compile 1 --tensorcores 1 --flash 1 --num_iterations ${NUM_ITER} --weight_decay 0.1 2>&1 | tee -a $LOG_LOC/$LOG_FILE
	else
		echo "invalid profile option: $PROFILE"
	fi

	#collect network stats
        echo "Dumping final: /proc/net/dev" | tee -a $LOG_LOC/$LOG_FILE
        cat /proc/net/dev >> $LOG_LOC/$LOG_FILE

else
	torchrun --nnodes=${NUM_NODES} --nproc-per-node=${NPROCS} --node-rank=${NODE_RANK} --master-addr=${MASTER_ADDR} --master-port=${MASTER_PORT} /workspace/llm.c/train_gpt2.py --input_bin "/workspace/llm.c/dev/data/fineweb10B/fineweb_train_000001.bin" --write_tensors 0 --model ${MODEL} --batch_size ${BS} --sequence_length ${SEQ_LEN} --total_batch_size ${BS_TOTAL} --dtype bfloat16 --compile 1 --tensorcores 1 --flash 1 --num_iterations ${NUM_ITER} --weight_decay 0.1

fi

echo "Writing nstat out file"
nstat > $LOG_LOC/$NSTAT_POST_FILE

sleep infinity

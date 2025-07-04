#!/bin/bash
#set -x
dir=$1
dir=${dir%/}

[[ -z $dir ]] && {
    echo "USAGE: $0 <datadir>" > /dev/stderr
    echo "  Very crude script to parse iperf3 logs in a data directory and create a csv file." > /dev/stderr
    echo "  Assumes that the file names of the logs conform with _ seperated fields with no commas" > /dev/stderr
    echo "  The fields and their order are hardcoded :-(" > /dev/stderr
    exit -1
}

resfile=${dir}.csv
echo path,trial,server,client,protocol,role,srvip,mtu,bufsize,winsize,bitrate,par,affin,bw,units > $resfile
ls $dir/iperf_* | while read file; do
    name=${file%%.log}
    IFS=_ read pgm prot role srvip mtu bufsize winsize bitrate par affin srv clt trial <<< $name
    if [[ $role == srv ]]; then
	res=$(tail -1 $file)
    else
	res=$(grep 'sec.*sender$' $file | tail -1)
    fi
    res=${res##*Bytes}
    res=${res%%/sec*}
    read bw units <<< $res
    units=${units}/sec
    echo $file,$trial,$srv,$clt,$prot,$role,$srvip,$mtu,$bufsize,$winsize,$bitrate,$par,$affin,$bw,$units
done >> $resfile



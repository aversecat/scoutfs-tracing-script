#!/bin/bash

# This script will continuously trace a full system with both trace-cmd and
# tcpdump (for the selected scoutfs instance) until it encounters the event
# in journalctl that we are looking for. All collected data is automatically
# cycled by tcpdump and trace-cmd. We collect everything in a subfolder, and
# tar it up after letting the jobs wrap up.

export TZ=UTC

die() { echo $@; exit 1; }

: ${COMPRESS_ARGS:=--zstd}
: ${COMPRESS_EXT:=zst}

# basic sanity checks
test $(id -u) -eq 0 || die "Please run this program as root"
rpmquery tcpdump > /dev/null || die "Please do 'sudo dnf install tcpdump'"
rpmquery trace-cmd > /dev/null || die "Please do 'sudo dnf install trace-cmd'"
rpmquery zstd > /dev/null || {
	echo "Consider installing the 'zstd' package for faster compression,"
	echo "falling back to 'xz'."
	COMPRESS_ARGS="--xz"
	COMPRESS_EXT="xz"
}
grep -qw scoutfs /proc/modules || die "Kernel module scoutfs not loaded"
grep -qw scoutfs /proc/mounts || die "Scoutfs filesystem not mounted?"

test_tcpdump() {
	# quickly see if we detect heartbeat UDP packets. This should take only 1sec
	# but we wait 5s just in case.
	echo "[ Checking scoutfs server at $IPADDR:$PORT ]"
	tcpdump -i any -p -c 10 host $IPADDR and udp port $PORT > /dev/null 2>&1 &
	P=$(jobs -p)
	sleep 5
	kill $P > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		die "tcpdump test failed: no hearbeat detected on ${IPADDR}:${PORT}"
	fi
}

start_tcpdump() {
	echo "+tcpdump -p -i any host $IPADDR and tcp port $PORT or udp port $PORT -w $OUTDIR/tcpdump.pcap -W 2 -Z root -C $CHUNKSIZE" > $OUTDIR/tcpdump.log
	tcpdump -p -i any host $IPADDR and tcp port $PORT or udp port $PORT -w $OUTDIR/tcpdump.pcap -W 2 -Z root -C $CHUNKSIZE >> $OUTDIR/tcpdump.log 2>&1 &
	TCPDUMP_PID=$!
	echo "[ Started tcpdump (${TCPDUMP_PID}) ]"
}

start_tracecmd() {
	echo "+trace-cmd record -b 10240 -e "scoutfs:*" -m $(( CHUNKSIZE * 1024 )) -o $OUTDIR/trace.dat" > $OUTDIR/trace.log
	trace-cmd record -b 10240 -e "scoutfs:*" -m $(( CHUNKSIZE * 1024 )) -o $OUTDIR/trace.dat >> $OUTDIR/trace.log 2>&1 &
	TRACECMD_PID=$!
	echo "[ Started trace-cmd (${TRACECMD_PID}) ]"
}

# we can tail the journald to capture fencing messages.
wait_for_client_fence() {
	# This will start tailing the journal from the current timestamp only,
	# outputting the first matching event, and then exit immediately
	EVENT_FILE=${OUTDIR}/event.log
	echo "[ Waiting for trigger event in the journal ]"
	journalctl -t kernel -g 'client.*reconnect timed out, fencing' -f -S now -n 1 > $EVENT_FILE &
	JOURNAL_PID=$!

	SPINNER="\|/-"
	S=0
	while sleep 1; do
		S=$(( ++S % 4 ))
		test -s $EVENT_FILE && break
		echo -ne "\r${SPINNER:${S}:1}"
	done
}

stop_tail() {
	echo
	echo "<< Interrupted by user >>" >> $EVENT_FILE
	# INT doesn't terminate journalctl, and we want to use `wait` for the
	# other bg jobs...
	kill -TERM $JOURNAL_PID > /dev/null 2>&1
}

if [ ${#} -ne 2 ]; then
	cat <<USAGE
Usage ${0} <ip address> <port>

    The IP address and port values are needed to configure tcpdump to correctly
    and efficiently capture packets that only go to the scoutfs server that we
    want to trace.

    You can inspect the output from this command to see what possible IP/port
    combinations are valid:
      \`journalctl -t kernel -g 'scoutfs.*server starting at'\`
    The output should list the valid IP/port combinations.

USAGE
	exit 1
fi

# our "chunk" size for both tcpdump and trace-cmd, in miB (million bytes)
# Because we're allocating one of these per CPU, aim these not to be too
# large. We'll use the same size for tcpdump.
CHUNKSIZE=50

# take these at face value
IPADDR=$1
PORT=$2

test_tcpdump

OUTDIR=scoutfs-trace.$(hostname).$(date +%Y-%m%d-%H%M)
mkdir -p $OUTDIR

# always stop bg tasks on exit
trap stop_tail SIGINT

echo "[ Tracing scoutfs server listening on ${IPADDR}:${PORT} ]"

# Mark start time of trace with full context
echo "START   time=$(date '+%Y-%m-%d %H:%M:%S'), boottime=$(uptime -s), uptime=$(cat /proc/uptime |awk '{print $1}')" > $OUTDIR/time.log

# fork trace utils and event catching job
start_tcpdump
start_tracecmd

# wait for the specific journal message, or ^C
wait_for_client_fence

echo "[ Event found in journal, or received SIGINT, wrapping up tracing ]"

# debatable how much extra tracing we need or want here. I'm going to go
# very short by default just in case the system produces enough data
# to rollover the traces every few seconds, which is highly likely
# in production scale setups.
sleep 1

# and close threads
kill -INT $TRACECMD_PID > /dev/null 2>&1
kill -INT $TCPDUMP_PID > /dev/null 2>&1

# we have to wait for our spawned jobs to finish collating
wait

# mark end of tracing time
echo "FINISH  time=$(date '+%Y-%m-%d %H:%M:%S'), boottime=$(uptime -s), uptime=$(cat /proc/uptime |awk '{print $1}')" >> $OUTDIR/time.log

# capture a few quick things now for context
journalctl -b | tail -n 1000 > ${OUTDIR}/journal.log
dmesg | tail -n 1000 > ${OUTDIR}/dmesg

# xz is way too slow, stop using it!
tar $COMPRESS_ARGS -cvf ${OUTDIR}.tar.${COMPRESS_EXT} ${OUTDIR}/
echo "[ Wrote ${OUTDIR}.tar.${COMPRESS_EXT} ]"


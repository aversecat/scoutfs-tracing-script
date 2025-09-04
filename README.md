
# Scoutfs Tracing Scripts


## Introduction

The script(s) in this repository are meant to help catch traces
for users of the scoutfs filesystem, with as much system context
as possible.

The scripts are designed to "complete" tracing and will naturally
exit if an event is encountered that we want to collect tracing
information from. In general, therefore, users will want to "start"
and "wait for the script to exit by itself", and then proceed to
collect the output tarball, and send it for analysis.

These scripts use `trace-cmd` on the system to handle the ftrace
buffers. These are system wide. Therefore, only a single instance
of the script should be running at all times.


## Requirements

The script needs to be run as root. The script will require several
gigabytes of free disk space in the current working directory to
capture traces and misc system information. The script should not be
used from a scoutfs directory, as tracing a filesystem while at the
same time writing trace data to that filesystem will cause a feedback
loop. Therefore, the best place to run the script from is from within
the /root homedirectory on a standard xfs, ext4, or btrfs filesystem.

The script itself will invoke several sysadmin tools and has tests to
make sure these are installed and available. If the script encounters
any of them missing it will point it out with clear instructions on
how to resolve these missing dependencies.


## Invocation

 `./scoutfs-tracing-script <ip> <port>`

The script requires the `<ip>` and `<port>` from the listening
server that we want to focus on. These parameters are used by the
part of the script that captures scoutfs network traffic between
scoutfs nodes. The script also captures ftrace events on the system,
and these are captured for all active scoutfs filesystems. For this
reason, the script should only be invoked once per system, and not
multiple times for each mounted scoutfs filesystem.


## During operation

While the script is executing, it will perform a few basic tests and
then start collecting trace event data continuously. The system will
allocate a buffer and delete the oldest events when the buffer is
full. All the collected data is in a temporary format. To make sense
of this data, the script needs to terminate properly to convert the
data into readable output format data files.


## Termination

The script can be stopped in 2 ways:

 1) Let the script terminate naturally - preferred. The script has
    a programmed termination event that it will look for. Once the
    script encounters this specific event, it will self-terminate
    and process all the intermediate data into a exported, compressed
    tarball that can be sent for analysis.

 2) Issuing a Control-C keypress. This stops trace collection and
    processes all intermediate data into a compressed tarball format
    file as well.


## Collection

The script will, once terminating, create a compressed tarball. Please
send this file to us, or make it available in some fashion.


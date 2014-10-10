#!/bin/bash -u

# Configuration options
# The prod master that will be used to capture the prod workload
master_host=

# The host that will use the tcpdump data
target_host=

# The amount of seconds up to which tcpdump must be run to capture the queries
tcpdump_time_limit_sec=

# The directory on the target host where tcpdump data will be temporarily
# stored
tmp_dir=

# The directory on the host running the script, that will store the tcpdump data
output_dir=


mysql_interface=eth0
mysql_port=3306
nc_port=7778

# Setup file prefixes
tcpdump_filename=mysql.tcp

# Setup tools
tcpdump_bin="/usr/sbin/tcpdump"
nc_bin="/usr/bin/nc"

# Function definitions
function vlog() {
    datetime=$(date "+%Y-%m-%d %H:%M:%S")
    msg="[${datetime}] $1"

    echo ${msg}
}

function show_error_n_exit() {
    error_msg=$1
    echo "ERROR: ${error_msg}"
    exit 1
}

function cleanup() {
    vlog "Doing cleanup before exiting"

    # Cleanup any outstanding netcat sockets
    cleanup_nc ${nc_port} ${target_host}

    # Cleanup the temporary directory on the target host
    ssh ${target_host} "rm -rf ${tmp_dir}"

    #TODO: add cleanup code to cleanup any running tcpdump processes
}

function get_nc_pid() {
#    set -x
    local port=$1
    local remote_host=$2

    local pid=$(ssh ${remote_host} "ps -aef" | grep nc | grep -v bash | grep ${port} | awk '{ print $2 }')
    echo ${pid}
#    set +x
}

function cleanup_nc() {
    local port=$1
    local remote_host=$2

    local pid=$(get_nc_pid ${port} ${remote_host})
    vlog "Killing nc pid ${pid}"

    [[ "${pid}" != '' && "${pid}" != 0 ]] && ssh ${remote_host} "kill ${pid} && (kill ${pid} && kill -9 ${pid})" || :
}

function check_pid() {
#    set -x
    local pid=$1
    local remote_host=$2
    [[ "${pid}" != 0 && "${pid}" != '' ]] && ssh ${remote_host} "ps -p ${pid}" >/dev/null 2>&1

    echo $?
#    set +x
}

# waits ~10 seconds for nc to open the port and then reports ready
function wait_for_nc()
{
#    set -x
    local port=$1
    local remote_host=$2

    for i in $(seq 1 50); do
        ssh ${remote_host} "netstat -nptl 2>/dev/null" | grep '/nc\s*$' | awk '{ print $4 }' | \
        sed 's/.*://' | grep \^${port}\$ >/dev/null && break
        sleep 0.2
    done

    vlog "ready ${remote_host}:${port}"
#    set +x
}

function setup_directories() {
    vlog "Initializing directories"

    # Initialize temp directories on target host
    ssh -q ${target_host} "mkdir -p ${tmp_dir}"

    # Initialize directory that will store the tcpdump data
    mkdir -p ${output_dir}
}

function get_tcpdump_from_master() {
#    set -x

    local tcpdump_args="-i ${mysql_interface} -s 65535 -x -n -q -tttt 'port ${mysql_port} and tcp[1] & 7 == 2 and tcp[3] & 7 == 2'"
    local tcpdump_file="${tmp_dir}/${tcpdump_filename}"

    vlog "Starting to capture production queries via tcpdump on the master ${master_host}"

    # Cleanup old sockets
    vlog "Cleaning up old netcat sockets"
    cleanup_nc ${nc_port} ${target_host}

    wait_for_nc ${nc_port} ${target_host} &

    # Create receiving socket on target_host
    vlog "Creating receiving socket on ${target_host}"
    ssh ${target_host} "nohup bash -c \"($nc_bin -dl $nc_port > ${tcpdump_file}) &\" > /dev/null 2>&1"

    wait %% # join wait_for_nc thread

    # check if nc is running, if not then it errored out
    local nc_pid=$(get_nc_pid ${nc_port} ${target_host})
    (( $(check_pid ${nc_pid} ${target_host} ) != 0 )) && display_error_n_exit "Could not create a socket on ${target_host}"

    vlog "Capturing MySQL workload on ${master_host} via tcpdump for ${tcpdump_time_limit_sec} seconds"
    vlog "Executing ${tcpdump_bin} ${tcpdump_args} on ${master_host}"
    ssh ${master_host} "timeout ${tcpdump_time_limit_sec} ${tcpdump_bin} ${tcpdump_args} 2> /dev/null | ${nc_bin} ${target_host} ${nc_port}"

    scp ${target_host}:${tcpdump_file} ${output_dir}/${tcpdump_filename} &> /dev/null

    vlog "Tcpdump successfully streamed from ${master_host} to ${output_dir}/${tcpdump_filename}"

#    set +x
}

# Usage info
function show_help() {
cat << EOF
Usage: ${0##*/} --master-host MASTER_HOST --target-host TARGET_HOST --tcpdump-seconds TCPDUMP_TIME_LIMIT_SEC --target-tmpdir TARGET_TMPDIR --output-dir OUTPUTDIR [options]
Capture tcpdump output from MASTER_HOST and stream it to TARGET_HOST.

Options:

    --help                                   display this help and exit
    --master-host MASTER_HOST                the master host actively executing
                                             production traffic that will be
                                             used to capture queries via
                                             tcpdump
    --target-host TARGET_HOST                the host that will use the tcpdump
                                             captured data
    --target-tmpdir TARGET_TMPDIR            the directory on TARGET_HOST that
                                             will be used for temporary files
    --tcpdump-seconds TCPDUMP_TIME_LIMIT_SEC the number of seconds for which
                                             tcpdump will be run on MASTER_HOST
    --output-dir OUTPUTDIR                   the directory on that will be used
                                             for storing the tcpdump file
EOF
}

function show_help_and_exit() {
    show_help >&2
    exit 22 # Invalid parameters
}

# Command line processing
OPTS=$(getopt -o hm:T:l:t:o: --long help,master-host:,target-host:,tcpdump-seconds:,target-tmpdir:,output-dir: -n 'mysql_workload_capture.sh' -- "$@")
[ $? != 0 ] && show_help_and_exit

eval set -- "$OPTS"

while true; do
  case "$1" in
    -m | --master-host )
                                master_host="$2";
                                shift; shift
                                ;;
    -T | --target-host )
                                target_host="$2";
                                shift; shift
                                ;;
    -l | --tcpdump-seconds )
                                tcpdump_time_limit_sec="$2";
                                shift; shift
                                ;;
    -t | --target-tmpdir )
                                tmp_dir="$2";
                                shift; shift
                                ;;
    -o | --output-dir )
                                output_dir="$2";
                                shift; shift
                                ;;
    -h | --help )
                                show_help >&2
                                exit 1
                                ;;
    -- )                        shift; break
                                ;;
    * )
                                show_help >&2
                                exit 1
                                ;;
  esac
done


# Sanity checking of command line parameters
[[ -z ${master_host} ]] && show_help_and_exit >&2

[[ -z ${target_host} ]] && show_help_and_exit >&2

for host in ${master_host} ${target_host}; do
    ssh -q ${host} "exit"
    (( $? != 0 )) && show_error_n_exit "Could not SSH into ${host}"
done

[[ -z ${tcpdump_time_limit_sec} ]] && show_help_and_exit >&2

[[ -z ${tmp_dir} ]] && show_help_and_exit >&2

[[ -z ${output_dir} ]] && show_help_and_exit >&2

# Setup directory names
output_dir="${output_dir}/${master_host}"


# Test that all tools are available
if (( $(ssh ${master_host} "which $tcpdump_bin" &> /dev/null; echo $?) != 0 )); then
    echo "Can't find $tcpdump_bin on ${master_host}"
    exit 22 # OS error code  22:  Invalid argument
fi

for tool_bin in ${nc_bin}; do
    for host in ${master_host} ${target_host}; do
        if (( $(ssh ${host} "which $tool_bin" &> /dev/null; echo $?) != 0 ))
        then
            echo "Can't find $tool_bin on ${host}"
            exit 22 # OS error code  22:  Invalid argument
        fi
    done
done


# Do the actual stuff
trap cleanup HUP PIPE INT TERM

# Setup the directories needed on the source and target hosts
setup_directories

# Capture and transfer tcpdump from source to target host
get_tcpdump_from_master

# Do the cleanup
cleanup

exit 0

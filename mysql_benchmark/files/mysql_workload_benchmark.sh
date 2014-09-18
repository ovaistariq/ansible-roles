#!/bin/bash -ue

# Configuration options
script_root=$(dirname $(readlink -f $0))
current_date=$(date +%Y_%m_%d_%H_%M_%S)

# The prod master that will be used to capture the prod workload
master_host=

# The host that we want to compare the performance too
slave_host=

# The host that we want to benchmark to guage performance
target_host=

# The amount of seconds up to which tcpdump must be run to capture
# the queries
tcpdump_time_limit_sec=300

# The directory on the target host where benchmark data will
# be temporarily stored
tmp_dir="/tmp"

# The directory where the benchmark report will be stored
output_dir="/tmp"

# Run the benchmark against this many active schemas
num_db_benchmark=1

# In test only mode only netcat socket testing is performed
test_only=

# These should be read-only MySQL users
mysql_username=
mysql_password=

mysql_interface=eth0
mysql_port=3306
nc_port=7778

# The temporary directories names
master_tmp_dir=
slave_tmp_dir=
target_tmp_dir=

# Setup file prefixes
tcpdump_filename=mysql.tcp
ptqd_filename=ptqd.txt
ptqd_slowlog_name=ptqd.slow.log

# Setup tools
tcpdump_bin="/usr/sbin/tcpdump"
nc_bin="/usr/bin/nc"
mysqladmin_bin="/usr/bin/mysqladmin"
mysql_bin="/usr/bin/mysql"
pt_query_digest_bin="/usr/bin/pt-query-digest"
pt_log_player_bin="/usr/bin/pt-log-player"

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
    # Cleanup any outstanding netcat sockets
    cleanup_nc ${nc_port} ${target_host}

    # Cleanup the temp directories on target host
    ssh -q ${target_host} "rm -rf ${tmp_dir}"
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

    for i in $(seq 1 50)
    do
        ssh ${remote_host} "netstat -nptl 2>/dev/null" | grep '/nc\s*$' | awk '{ print $4 }' | \
        sed 's/.*://' | grep \^${port}\$ >/dev/null && break
        sleep 0.2
    done

    vlog "ready ${remote_host}:${port}"
#    set +x
}

function setup_directories() {
    vlog "Setting up directory ${tmp_dir} on target host"

    # Initialize temp directories to target host
    ssh -q ${target_host} "mkdir -p ${tmp_dir} ${master_tmp_dir} ${slave_tmp_dir} ${target_tmp_dir}"

    vlog "Setting up directory ${output_dir} on localhost"
    mkdir -p ${output_dir}
}

function test_remote_sockets() {
#    set -x

    vlog "Testing remote communication: ${master_host} <-> ${target_host}"

    wait_for_nc ${nc_port} ${target_host} &

    # Create a test socket to test to see if we can create and send to sockets
    ssh ${target_host} "nohup bash -c \"(${nc_bin} -dl ${nc_port} > /tmp/mysql_workload_benchmark_nc_hello.txt) &\" > /dev/null 2>&1"

    wait %% # join wait_for_nc thread

    # check if nc is running, if not then it errored out
    local nc_pid=$(get_nc_pid ${nc_port} ${target_host})
    (( $(check_pid ${nc_pid} ${target_host} ) != 0 )) && show_error_n_exit "Could not create a socket on ${target_host}"

    ssh ${master_host} "echo 'hello world' | ${nc_bin} ${target_host} ${nc_port}"
    if [[ $? != 0 ]]
    then
        cleanup_nc ${nc_port} ${target_host}
        show_error_n_exit "Could not connect to remote socket on ${target_host} from ${master_host}"
    fi

    vlog "${master_host} <-> ${target_host} can communicate on ${nc_port}"

#    set +x

    return $?
}

function test_mysql_access() {
#    set -x
    local mysqladmin_args=

    for host in ${master_host} ${slave_host} localhost
    do
        vlog "Testing MySQL access on ${host} from ${target_host}"
        mysqladmin_args="--user=${mysql_username} --password=${mysql_password} --host=${host}"

        if (( $(ssh ${target_host} "${mysqladmin_bin} ${mysqladmin_args} ping &> /dev/null; echo $?") != 0 ))
        then
            echo "Could not connect to MySQL on ${host}"
            exit 2003
        fi
    done

    return 0

#    set +x
}

function do_test() {
#    set -x
    local ret_code=

    # Test for remote sockets via netcat
    test_remote_sockets
    ret_code=$?
    (( ${ret_code} != 0 )) && exit ret_code

    # Test for MySQL access from the target host
    test_mysql_access
    ret_code=$?
    exit ${ret_code}
#    set +x
}

function get_tcpdump_from_master() {
#    set -x

    local tcpdump_args="-i ${mysql_interface} -s 65535 -x -n -q -tttt 'port ${mysql_port} and tcp[1] & 7 == 2 and tcp[3] & 7 == 2'"
    local tcpdump_file="${master_tmp_dir}/${tcpdump_filename}"

    vlog "Capturing production queries via tcpdump on the master ${master_host}"

    # Cleanup old sockets
    vlog "Cleaning up old netcat sockets"
    cleanup_nc ${nc_port} ${target_host}

    wait_for_nc ${nc_port} ${target_host} &

    # Create receiving socket on slave
    vlog "Creating receiving socket on ${target_host}"
    ssh ${target_host} "nohup bash -c \"($nc_bin -dl $nc_port > ${tcpdump_file}) &\" > /dev/null 2>&1"

    wait %% # join wait_for_nc thread

    # check if nc is running, if not then it errored out
    local nc_pid=$(get_nc_pid ${nc_port} ${target_host})
    (( $(check_pid ${nc_pid} ${target_host} ) != 0 )) && display_error_n_exit "Could not create a socket on ${target_host}"

    vlog "Capturing MySQL workload on ${master_host} via tcpdump for ${tcpdump_time_limit_sec} seconds"
    vlog "Executing ${tcpdump_bin} ${tcpdump_args} on ${master_host}"
    ssh ${master_host} "timeout ${tcpdump_time_limit_sec} ${tcpdump_bin} ${tcpdump_args} 2> /dev/null | ${nc_bin} ${target_host} ${nc_port}"

    vlog "Tcpdump successfully streamed from ${master_host} to ${target_host}:${tcpdump_file}"

#    set +x
}

function generate_slowlog_from_tcpdump() {
#    set -x

    local tcpdump_file="${master_tmp_dir}/${tcpdump_filename}"
    local slowlog_file="${master_tmp_dir}/${ptqd_slowlog_name}"

    ptqd_args="--type tcpdump ${tcpdump_file} --output slowlog --no-report --filter '(\$event->{fingerprint} =~ m/^select/i) && (\$event->{arg} !~ m/for update/i) && (\$event->{fingerprint} !~ m/users_online/i)'"

    vlog "Executing ${pt_query_digest_bin} ${ptqd_args} on ${target_host}"
    ssh ${target_host} "${pt_query_digest_bin} ${ptqd_args} > ${slowlog_file} 2> /dev/null"

    vlog "Slow log successfully generated and written to ${slowlog_file}"

#    set +x
}

function get_active_db_list() {
    # Get the name of the most active database
    local ignore_db_list="'mysql', 'information_schema', 'performance_schema'"
    local mysql_args=

    sql="SELECT db FROM processlist WHERE db IS NOT NULL AND db NOT in (${ignore_db_list}) GROUP BY db ORDER BY COUNT(*) DESC LIMIT ${num_db_benchmark}"
    mysql_args="--user=${mysql_username} --password=${mysql_password}"

    db_list=$(ssh ${master_host} "${mysql_bin} ${mysql_args} information_schema -e \"${sql}\" -NB")

    echo ${db_list}
}

function get_source_mysql_thd_conc() {
#    set -x

    local mysqladmin_args="--user=${mysql_username} --password=${mysql_password} -i 1 -c 30 extended-status"
    local awk_args='BEGIN {cnt=0; sum=0;} /Threads_running/ {cnt=cnt+1; sum=sum+$4} END {printf "%d\n", (sum/cnt)}'

    local thd_concurrency=$(ssh ${master_host} "${mysqladmin_bin} ${mysqladmin_args} | awk '${awk_args}'")
    echo ${thd_concurrency}

#    set +x
}

function run_benchmark() {
#    set -x

    # Estimate the MySQL thread concurrency on the production master.
    # This will be used as baseline concurrency when running benchmark
    vlog "Estimating MySQL threads concurrency on master ${master_host}"
    local mysql_thd_conc=$(get_source_mysql_thd_conc)

    local slowlog_file="${master_tmp_dir}/${ptqd_slowlog_name}"

    # Prepare the directories used by pt-log-player
    local master_sessions_dir="${master_tmp_dir}/sessions"
    local slave_results_dir="${slave_tmp_dir}/results"
    local target_results_dir="${target_tmp_dir}/results"

    local pt_log_player_args=

    ssh ${target_host} "mkdir -p ${master_sessions_dir} ${slave_results_dir} ${target_results_dir}"

    # Get list of active DBs
    vlog "Fetching the list of active DBs from the master ${master_host}"
    local active_db_list=$(get_active_db_list)
    if [[ "${active_db_list}" == "" ]]
    then
        echo "No database schemas found to run benchmark against"
        exit 22
    fi

    vlog "Preparing the session files for pt-log-player"
    ssh ${target_host} "${pt_log_player_bin} --split Thread_id --session-files ${mysql_thd_conc} --base-dir ${master_sessions_dir} ${slowlog_file}"

    vlog "The benchmarks will be run against the schemas:"
    echo "${active_db_list}"

    # Warm up the buffer pool on the slave and target hosts
    for host in ${slave_host} ${target_host}
    do
        vlog "Warming up the buffer pool on the host ${host}"
        for db in ${active_db_list}
        do
            echo "Warming up schema ${db}"
            pt_log_player_args="--play ${master_sessions_dir} --set-vars innodb_lock_wait_timeout=1 --only-select --threads ${mysql_thd_conc} --no-results --iterations=3 h=${host},u=${mysql_username},p=${mysql_password},D=${db}"

            ssh ${target_host} "${pt_log_player_bin} ${pt_log_player_args}"
        done
    done

    # Run the benchmark against the slave host
    vlog "Running the benchmark on the slave host ${slave_host} with a concurrency of ${mysql_thd_conc}"
    for db in ${active_db_list}
    do
        echo "Benchmarking the schema ${db}"
        pt_log_player_args="--play ${master_sessions_dir} --set-vars innodb_lock_wait_timeout=1 --base-dir ${slave_results_dir} --only-select --threads ${mysql_thd_conc} h=${slave_host},u=${mysql_username},p=${mysql_password},D=${db}"

        ssh ${target_host} "${pt_log_player_bin} ${pt_log_player_args}"
    done

    # Run the benchmark against the target host
    vlog "Running the benchmark on the target host ${target_host} with a concurrency of ${mysql_thd_conc}"
    for db in ${active_db_list}
    do
        echo "Benchmarking the schema ${db}"
        pt_log_player_args="--play ${master_sessions_dir} --set-vars innodb_lock_wait_timeout=1 --base-dir ${target_results_dir} --only-select --threads ${mysql_thd_conc} h=localhost,u=${mysql_username},p=${mysql_password},D=${db}"

        ssh ${target_host} "${pt_log_player_bin} ${pt_log_player_args}"
    done

    # Generating the pt-query-digest reports
    vlog "Generating the pt-query-digest reports on the benchmark runs"
    for dir in ${slave_tmp_dir} ${target_tmp_dir}
    do
        ssh ${target_host} "${pt_query_digest_bin} ${dir}/results/* --limit=100 > ${dir}/ptqd.txt"
    done

    vlog "Benchmarks completed."

#    set +x
}

function print_benchmark_results() {
    echo
    echo "###########################################################################"
    echo "Queries benchmark summary from the slave ${slave_host}"
    awk '/user time,/,/# Query size/' ${output_dir}/slave-${slave_host}-ptqd.txt | grep -v "# Files:" | grep -v "# Hostname:"

    echo
    echo "Queries benchmark summary from the target ${target_host}"
    awk '/user time,/,/# Query size/' ${output_dir}/target-${target_host}-ptqd.txt | grep -v "# Files:" | grep -v "# Hostname:"

    local slave_qps_95th=$(awk '/user time,/,/# Query size/' ${output_dir}/slave-${slave_host}-ptqd.txt | grep "# Exec time" | awk '{print $8}')
    local target_qps_95th=$(awk '/user time,/,/# Query size/' ${output_dir}/target-${target_host}-ptqd.txt | grep "# Exec time" | awk '{print $8}')

    echo
    echo "95th-per query exec time: ${slave_qps_95th} on ${slave_host} vs ${target_qps_95th} on ${target_host}"
    echo "Detailed reports are available at ${output_dir}"
    echo "###########################################################################"
}

function transfer_benchmark_reports() {
    vlog "Transfering benchmark reports to ${output_dir} on localhost"

    scp ${target_host}:${slave_tmp_dir}/ptqd.txt ${output_dir}/slave-${slave_host}-ptqd.txt &> /dev/null
    scp ${target_host}:${target_tmp_dir}/ptqd.txt ${output_dir}/target-${target_host}-ptqd.txt &> /dev/null
}

# Usage info
function show_help() {
cat << EOF
Usage: ${0##*/} --master-host MASTER_HOST --slave-host SLAVE_HOST --target-host TARGET_HOST --mysql-user MYSQL_USERNAME --mysql-password MYSQL_PASSWORD [options]
Capture tcpdump output from MASTER_HOST and replay it on SLAVE_HOST and TARGET_HOST and compare the query times.

Options:

    --help                                      display this help and exit
    --master-host MASTER_HOST                   the master host actively executing production
                                                traffic that will be used to capture
                                                queries via tcpdump
    --slave-host SLAVE_HOST                     the slave host which is to be benchmarked and
                                                which will be used as a baseline
    --target-host TARGET_HOST                   the host that has to be benchmarked
    --tcpdump-seconds TCPDUMP_TIME_LIMIT_SEC    (default= 300s) the number of seconds for
                                                which tcpdump will be run on SOURCE_HOST
    --target-tmpdir TARGET_TMPDIR               (default= /tmp) the directory on TARGET_HOST
                                                that will be used for temporary files needed
                                                during the benchmark
    --output-dir OUTPUT_DIR                     (default= /tmp) the directory that stores the
                                                benchmark reports
    --mysql-user MYSQL_USERNAME                 the name of the MySQL user that will be used to
                                                replay the benchmark queries on SLAVE_HOST and
                                                TARGET_HOST
    --mysql-password MYSQL_PASSWORD             the password for the MySQL user
EOF
}

function show_help_and_exit() {
    show_help >&2
    exit 22 # Invalid parameters
}

# Command line argument processing
#OPT_ARGS=":m:s:d:l:t"
#while getopts "$OPT_ARGS" opt
#do
#    case ${opt} in
#        m) master_host=$OPTARG;;
#        s) slave_host=$OPTARG;;
#        d) target_host=$OPTARG;;
#        l) tcpdump_time_limit_sec=$OPTARG;;
#        t) test_only=true;;
#        \?)
#            show_help >&2
#            exit 1
#            ;;
#        :)
#            show_help >&2
#            exit 2
#            ;;
#    esac
#done

# Command line processing
OPTS=$(getopt -o hm:s:T:l:t:o:u:p: --long help,master-host:,slave-host:,target-host:,tcpdump-seconds:,target-tmpdir:,output-dir:,mysql-user:,mysql-password: -n 'mysql_workload_benchmark.sh' -- "$@")
[ $? != 0 ] && show_help_and_exit

eval set -- "$OPTS"

while true; do
  case "$1" in
    -m | --master-host )
                                master_host="$2";
                                shift; shift
                                ;;
    -s | --slave-host )
                                slave_host="$2";
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
    -u | --mysql-user )
                                mysql_username="$2";
                                shift; shift
                                ;;
    -p | --mysql-password )     mysql_password="$2";
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

[[ -z ${slave_host} ]] && show_help_and_exit >&2

[[ -z ${target_host} ]] && show_help_and_exit >&2

for host in ${master_host} ${slave_host} ${target_host}
do
    ssh -q ${host} "exit"
    (( $? != 0 )) && show_error_n_exit "Could not SSH into ${host}"
done

[[ -z ${tcpdump_time_limit_sec} ]] && show_help_and_exit >&2

[[ -z ${mysql_username} ]] && show_help_and_exit >&2

[[ -z ${mysql_password} ]] && show_help_and_exit >&2

# Setup temporary directories
tmp_dir="${tmp_dir}/${current_date}"
master_tmp_dir="${tmp_dir}/master-${master_host}"
slave_tmp_dir="${tmp_dir}/slave-${slave_host}"
target_tmp_dir="${tmp_dir}/target-${target_host}"

# Setup output directories
output_dir="${output_dir}/${current_date}"

# Test that all tools are available
for tool_bin in ${tcpdump_bin} ${nc_bin} ${mysqladmin_bin} ${mysql_bin}
do
    for host in ${master_host} ${slave_host} ${target_host}
    do
        if (( $(ssh ${host} "which $tool_bin" &> /dev/null; echo $?) != 0 ))
        then
            echo "Can't find $tool_bin in PATH on ${host}"
            exit 22 # OS error code  22:  Invalid argument
        fi
    done
done

for tool_bin in ${pt_query_digest_bin} ${pt_log_player_bin}
do
    if (( $(ssh ${target_host} "which $tool_bin" &> /dev/null; echo $?) != 0 ))
    then
        echo "Can't find $tool_bin in PATH on ${target_host}"
        exit 22 # OS error code  22:  Invalid argument
    fi
done

# Test if nc based sockets work to/from source and target hosts
# and test for MySQL connectivity.
[[ ! -z ${test_only} ]] && do_test


# Do the actual stuff
trap cleanup HUP PIPE INT TERM

# Setup the directories needed on the source and target hosts
setup_directories

# Capture and transfer tcpdump from source to target host
get_tcpdump_from_master

# Parse the source host tcpdump and generate slow log from it
# This will be used by percona-playback
vlog "Generating slowlog file from tcpdump to be used for benchmarking"
generate_slowlog_from_tcpdump

# Do the benchmark run
run_benchmark

# Print the benchmark report at the end
transfer_benchmark_reports
print_benchmark_results

# Do the cleanup
cleanup

exit 0

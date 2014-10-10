#!/bin/bash -u

# Configuration options
# The prod master that was used to capture prod workload
master_host=

# The host that we want to compare the performance too
compare_host=

# The host that we want to benchmark to guage performance
target_host=

# The directory on the target host where benchmark data will be temporarily 
# stored
tmp_dir=

# The directory where the benchmark report will be stored
output_dir=

# Should the benchmark be run with cold InnoDB Buffer Pool cache. When this
# is enabled then the Buffer Pool is not warmed up before replaying the
# workload. This can be important in cases where you want to test MySQL
# performance with cold caches
benchmark_cold_run=0

# The temporary directories names
master_tmp_dir=
compare_host_tmp_dir=
target_tmp_dir=

# Setup file prefixes
tcpdump_filename=mysql.tcp
ptqd_filename=ptqd.txt
ptqd_slowlog_name=mysql.slow.log

# Setup tools
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
    vlog "Doing cleanup before exiting"

    #TODO: add code to cleanup any running ptqd and pt-log-player processes
}

function check_pid() {
#    set -x
    local pid=$1
    local remote_host=$2
    [[ "${pid}" != 0 && "${pid}" != '' ]] && ssh ${remote_host} "ps -p ${pid}" >/dev/null 2>&1

    echo $?
#    set +x
}

function setup_directories() {
    vlog "Setting up directories ${tmp_dir} ${compare_host_tmp_dir} ${target_tmp_dir} on target host"

    # Initialize temp directories to target host
    ssh -q ${target_host} "mkdir -p ${tmp_dir} ${compare_host_tmp_dir} ${target_tmp_dir}"

    vlog "Setting up directory ${output_dir} on localhost"
    mkdir -p ${output_dir}
}

function generate_slowlog_from_tcpdump() {
#    set -x

    vlog "Generating slowlog file from tcpdump to be used for benchmarking"

    local slowlog_file="${master_tmp_dir}/${ptqd_slowlog_name}"
    local tcpdump_file="${master_tmp_dir}/${tcpdump_filename}"

    ptqd_args="--type tcpdump ${tcpdump_file} --output slowlog --no-report --filter '(\$event->{fingerprint} =~ m/^select/i) && (\$event->{arg} !~ m/for update/i) && (\$event->{fingerprint} !~ m/users_online/i)'"

    vlog "Executing ${pt_query_digest_bin} ${ptqd_args} on ${target_host}"
    ssh ${target_host} "${pt_query_digest_bin} ${ptqd_args} > ${slowlog_file} 2> /dev/null"

    vlog "Slow log successfully generated and written to ${slowlog_file}"

#    set +x
}

function get_source_mysql_thd_conc() {
#    set -x

    local mysqladmin_args="-i 1 -c 30 extended-status"
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
    local compare_host_results_dir="${compare_host_tmp_dir}/results"
    local target_results_dir="${target_tmp_dir}/results"

    local pt_log_player_args=

    ssh ${target_host} "mkdir -p ${master_sessions_dir} ${compare_host_results_dir} ${target_results_dir}"

    vlog "Preparing the session files for pt-log-player"
    ssh ${target_host} "${pt_log_player_bin} --split Thread_id --session-files ${mysql_thd_conc} --base-dir ${master_sessions_dir} ${slowlog_file}"

    # Warm up the buffer pool on the compare_host and target hosts
    if [[ "${benchmark_cold_run}" == "0" ]]; then
        for host in ${compare_host} ${target_host}; do
            vlog "Warming up the buffer pool on the host ${host}"
            pt_log_player_args="--play ${master_sessions_dir} --set-vars innodb_lock_wait_timeout=1 --only-select --threads ${mysql_thd_conc} --no-results --iterations=3 h=${host}"
            ssh ${target_host} "${pt_log_player_bin} ${pt_log_player_args}" 2> /dev/null
        done
    fi

    # Run the benchmark against the compare_host
    vlog "Starting to run the benchmark on the host ${compare_host} with a concurrency of ${mysql_thd_conc}"

    pt_log_player_args="--play ${master_sessions_dir} --set-vars innodb_lock_wait_timeout=1 --base-dir ${compare_host_results_dir} --only-select --threads ${mysql_thd_conc} h=${compare_host}"
    ssh ${target_host} "${pt_log_player_bin} ${pt_log_player_args}" 2> /dev/null

    # Run the benchmark against the target host
    vlog "Starting to run the benchmark on the target host ${target_host} with a concurrency of ${mysql_thd_conc}"

    pt_log_player_args="--play ${master_sessions_dir} --set-vars innodb_lock_wait_timeout=1 --base-dir ${target_results_dir} --only-select --threads ${mysql_thd_conc} h=localhost"
    ssh ${target_host} "${pt_log_player_bin} ${pt_log_player_args}" 2> /dev/null

    # Generating the pt-query-digest reports
    vlog "Generating the pt-query-digest reports on the benchmark runs"
    for dir in ${compare_host_tmp_dir} ${target_tmp_dir}; do
        ssh ${target_host} "${pt_query_digest_bin} ${dir}/results/* --limit=100 > ${dir}/ptqd.txt"
    done

    vlog "Benchmarks completed."

#    set +x
}

function print_benchmark_results() {
    echo
    echo "###########################################################################"
    echo "Queries benchmark summary from the host ${compare_host}"
    awk '/user time,/,/# Query size/' ${output_dir}/${compare_host}-ptqd.txt | grep -v "# Files:" | grep -v "# Hostname:"

    echo
    echo "Queries benchmark summary from the target ${target_host}"
    awk '/user time,/,/# Query size/' ${output_dir}/${target_host}-ptqd.txt | grep -v "# Files:" | grep -v "# Hostname:"

    local compare_host_qps_95th=$(awk '/user time,/,/# Query size/' ${output_dir}/${compare_host}-ptqd.txt | grep "# Exec time" | awk '{print $8}')
    local target_qps_95th=$(awk '/user time,/,/# Query size/' ${output_dir}/${target_host}-ptqd.txt | grep "# Exec time" | awk '{print $8}')

    echo
    echo "95th-per query exec time: ${compare_host_qps_95th} on ${compare_host} vs ${target_qps_95th} on ${target_host}"
    echo "Detailed reports are available at ${output_dir}"
    echo "###########################################################################"
}

function transfer_benchmark_reports() {
    vlog "Transfering benchmark reports to ${output_dir} on localhost"

    scp ${target_host}:${compare_host_tmp_dir}/ptqd.txt ${output_dir}/${compare_host}-ptqd.txt &> /dev/null
    scp ${target_host}:${target_tmp_dir}/ptqd.txt ${output_dir}/${target_host}-ptqd.txt &> /dev/null
}

# Usage info
function show_help() {
cat << EOF
Usage: ${0##*/} --master-host MASTER_HOST --compare-host COMPARE_HOST --target-host TARGET_HOST --target-tmpdir TARGET_TMPDIR --output-dir OUTPUT_DIR [options]
Replay MySQL production workload in tcpdump format on SLAVE_HOST and TARGET_HOST and compare the query times.

Options:

    --help                          display this help and exit
    --master-host MASTER_HOST       the master host actively executing
                                    production traffic that will be used to
                                    capture queries via tcpdump
    --compare-host COMPARE_HOST     the host which is to be benchmarked
                                    and which will be used as a baseline to
                                    compare the performance of target_host
    --target-host TARGET_HOST       the host that has to be benchmarked
    --target-tmpdir TARGET_TMPDIR   the directory on TARGET_HOST that will be
                                    used for temporary files needed during
                                    the benchmark
    --output-dir OUTPUT_DIR         the directory that stores the benchmark
                                    reports
    --cold-run                      run the benchmark with cold InnoDB Buffer
                                    Pool cache, this is disabled by default
EOF
}

function show_help_and_exit() {
    show_help >&2
    exit 22 # Invalid parameters
}

# Command line processing
OPTS=$(getopt -o hcm:s:T:t:o: --long help,cold-run,master-host:,compare-host:,target-host:,target-tmpdir:,output-dir: -n 'mysql_workload_replay.sh' -- "$@")
[ $? != 0 ] && show_help_and_exit

eval set -- "$OPTS"

while true; do
  case "$1" in
    -m | --master-host )
                                master_host="$2";
                                shift; shift
                                ;;
    -s | --compare-host )
                                compare_host="$2";
                                shift; shift
                                ;;
    -T | --target-host )
                                target_host="$2";
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
    -c | --cold-run )           benchmark_cold_run=1
                                shift;
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

[[ -z ${compare_host} ]] && show_help_and_exit >&2

[[ -z ${target_host} ]] && show_help_and_exit >&2

for host in ${master_host} ${compare_host} ${target_host}; do
    ssh -q ${host} "exit"
    (( $? != 0 )) && show_error_n_exit "Could not SSH into ${host}"
done

[[ -z ${tmp_dir} ]] && show_help_and_exit >&2

[[ -z ${output_dir} ]] && show_help_and_exit >&2


# Setup temporary directories
master_tmp_dir="${tmp_dir}/${master_host}"
compare_host_tmp_dir="${tmp_dir}/${compare_host}"
target_tmp_dir="${tmp_dir}/${target_host}"

# Test that all tools are available
for tool_bin in ${mysqladmin_bin} ${mysql_bin}; do
    for host in ${master_host} ${compare_host} ${target_host}; do
        if (( $(ssh ${host} "which $tool_bin" &> /dev/null; echo $?) != 0 )); then
            echo "Can't find $tool_bin in PATH on ${host}"
            exit 22 # OS error code  22:  Invalid argument
        fi
    done
done

for tool_bin in ${pt_query_digest_bin} ${pt_log_player_bin}; do
    if (( $(ssh ${target_host} "which $tool_bin" &> /dev/null; echo $?) != 0 )); then
        echo "Can't find $tool_bin in PATH on ${target_host}"
        exit 22 # OS error code  22:  Invalid argument
    fi
done


# Do the actual stuff
trap cleanup HUP PIPE INT TERM

# Setup the directories needed on the source and target hosts
setup_directories

# Parse the source host tcpdump and generate slow log from it
# This will be used by percona-playback
generate_slowlog_from_tcpdump

# Do the benchmark run
run_benchmark

# Print the benchmark report at the end
transfer_benchmark_reports
print_benchmark_results

# Do the cleanup
cleanup

exit 0

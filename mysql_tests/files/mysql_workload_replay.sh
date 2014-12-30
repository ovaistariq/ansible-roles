#!/bin/bash -u

# Configuration options
# The prod master that was used to capture prod workload
master_host=

# The host that we want to benchmark to guage performance
target_host=

# The directory where the benchmark related data will be stored
output_dir=

# Read-only MySQL user credentials
mysql_username=
mysql_password=

# Should the benchmark be run with cold InnoDB Buffer Pool cache. When this
# is enabled then the Buffer Pool is not warmed up before replaying the
# workload. This can be important in cases where you want to test MySQL
# performance with cold caches
benchmark_cold_run=0

# The MySQL thread concurrency on the master. This is used to run the benchmark
# at the same concurrency as the workload running on the master.
master_mysql_thd_conc=6

# The temporary directories names
master_tmp_dir=
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

function test_mysql_access() {
#    set -x
    local host=$1
    [[ "${host}" != '' ]] && ${mysqladmin_bin} --host=${host} --user=${mysql_username} --password=${mysql_password} ping >/dev/null 2>&1

    echo $?
#    set +x
}

function setup_directories() {
    vlog "Setting up directory ${output_dir} ${target_tmp_dir} ${master_tmp_dir}"
    mkdir -p ${output_dir} ${target_tmp_dir} ${master_tmp_dir}
}

function generate_slowlog_from_tcpdump() {
#    set -x

    vlog "Generating slowlog file from tcpdump to be used for benchmarking"

    local tcpdump_file="${master_tmp_dir}/${tcpdump_filename}"
    local slowlog_file="${master_tmp_dir}/${ptqd_slowlog_name}"

    ${pt_query_digest_bin} --type tcpdump ${tcpdump_file} \
        --output slowlog --no-report \
        --filter '(defined $event->{db}) && ($event->{fingerprint} =~ m/^select/i) && ($event->{arg} !~ m/FOR UPDATE/i) && ($event->{arg} !~ m/LOCK IN SHARE MODE/i)' \
        > ${slowlog_file} 2> /dev/null

    # Below is a temp solution for the bug 
    # https://bugs.launchpad.net/percona-toolkit/+bug/1402776
    sed 's/\x0mysql_native_password//g' ${slowlog_file} > ${slowlog_file}.new
    mv ${slowlog_file}.new ${slowlog_file}

    vlog "Slow log successfully generated and written to ${slowlog_file}"

#    set +x
}

function warmup_host_for_benchmark() {
#    set -x

    if [[ "${benchmark_cold_run}" != "0" ]]; then
        return
    fi

    local host=$1
    local mysql_thd_conc=$2

    vlog "Warming up the buffer pool on the host ${host}"

    ${pt_log_player_bin} --user ${mysql_username} \
        --password ${mysql_password} --play ${master_sessions_dir} \
        --set-vars innodb_lock_wait_timeout=1 --only-select \
        --threads ${mysql_thd_conc} --no-results --iterations=3 \
        h=${host} &> /dev/null

#    set +x
}

function run_benchmark_on_host() {
#    set -x

    local host=$1
    local mysql_thd_conc=$2
    local host_results_dir=$3
    local host_tmp_dir=$4

    # Run the benchmark
    vlog "Starting to run the benchmark on the host ${host} with a concurrency of ${mysql_thd_conc}"

    ${pt_log_player_bin} --user ${mysql_username} \
        --password ${mysql_password} --play ${master_sessions_dir} \
        --set-vars innodb_lock_wait_timeout=1 \
        --base-dir ${host_results_dir} --only-select \
        --threads ${mysql_thd_conc} h=${host} \
        > ${host_tmp_dir}/pt_log_player.log \
        2> ${host_tmp_dir}/pt_log_player.err

#    set +x
}

function run_benchmark() {
#    set -x

    local slowlog_file="${master_tmp_dir}/${ptqd_slowlog_name}"

    # Prepare the directories used by pt-log-player
    local master_sessions_dir="${master_tmp_dir}/sessions"
    mkdir -p ${master_sessions_dir}

    # This will be used as baseline concurrency when running benchmark
    local mysql_thd_conc=${master_mysql_thd_conc}

    vlog "Preparing the session files for pt-log-player"
    ${pt_log_player_bin} --split-random --session-files ${mysql_thd_conc} \
        --base-dir ${master_sessions_dir} ${slowlog_file} \
        > ${master_tmp_dir}/pt_log_player.log \
        2> ${master_tmp_dir}/pt_log_player.err

    # Prepare the target host
    local target_results_dir="${target_tmp_dir}/results"
    mkdir -p ${target_results_dir}

    # Warm up the buffer pool on the target host
    warmup_host_for_benchmark ${target_host} ${mysql_thd_conc}

    # Run the benchmark against the target host
    vlog "Starting to run the benchmark on the target host ${target_host} with a concurrency of ${mysql_thd_conc}"
    run_benchmark_on_host ${target_host} ${mysql_thd_conc} ${target_results_dir} ${target_tmp_dir}

    # Generating the pt-query-digest reports
    vlog "Generating the pt-query-digest reports on the benchmark runs"
    ${pt_query_digest_bin} ${target_tmp_dir}/results/* --limit=100 > ${target_tmp_dir}/ptqd.txt

    vlog "Benchmarks completed."

#    set +x
}

function print_benchmark_results() {
    echo
    echo "Queries benchmark summary from the target ${target_host}"
    awk '/user time,/,/# Query size/' ${target_tmp_dir}/ptqd.txt | grep -v "# Files:" | grep -v "# Hostname:"

    echo
    echo "Detailed reports are available at ${output_dir}"
    echo "###########################################################################"
}

# Usage info
function show_help() {
cat << EOF
Usage: ${0##*/} --master-host MASTER_HOST --target-host TARGET_HOST --output-dir OUTPUT_DIR --mysql-user MYSQL_USER --mysql-password MYSQL_PASSWORD [options]
Replay MySQL production workload in tcpdump format on TARGET_HOST and compare the query times.

Options:

    --help                          display this help and exit
    --master-host MASTER_HOST       the master host actively executing
                                    production traffic that will be used to
                                    capture queries via tcpdump
    --target-host TARGET_HOST       the host that has to be benchmarked
    --output-dir OUTPUT_DIR         the directory that stores the benchmark
                                    reports
    --mysql-user MYSQL_USER         the MySQL read-only username that would
                                    be used to run the queries
    --mysql-password MYSQL_PASSWORD the MySQL read-only user password
    --concurrency CONCURRENCY       the MySQL thread concurrency at which to
    --cold-run                      run the benchmark (default 6)
                                    Pool cache, this is disabled by default
EOF
}

function show_help_and_exit() {
    show_help >&2
    exit 22 # Invalid parameters
}

# Command line processing
OPTS=$(getopt -o hcm:T:o:u:p:C: --long help,cold-run,master-host:,target-host:,output-dir:,mysql-user:,mysql-password:,concurrency: -n 'mysql_workload_replay.sh' -- "$@")
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
    -o | --output-dir )
                                output_dir="$2";
                                shift; shift
                                ;;
    -u | --mysql-user )
                                mysql_username="$2";
                                shift; shift
                                ;;
    -p | --mysql-password )
                                mysql_password="$2";
                                shift; shift
                                ;;

    -C | --concurrency)         master_mysql_thd_conc="$2";
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

[[ -z ${target_host} ]] && show_help_and_exit >&2

[[ -z ${output_dir} ]] && show_help_and_exit >&2

[[ -z ${mysql_username} ]] && show_help_and_exit >&2

[[ -z ${mysql_password} ]] && show_help_and_exit >&2

# Setup temporary directories
master_tmp_dir="${output_dir}/${master_host}"
target_tmp_dir="${output_dir}/${target_host}"

# Test that all tools are available
for tool_bin in ${pt_query_digest_bin} ${pt_log_player_bin}; do
    if (( $(which $tool_bin &> /dev/null; echo $?) != 0 )); then
        echo "Can't find $tool_bin"
        exit 22 # OS error code  22:  Invalid argument
    fi
done

# Test that MySQL credentials are correct
if (( $(test_mysql_access ${target_host}) != 0 )); then
    echo "Could not connect to MySQL on ${target_host}"
    exit 2003
fi

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
print_benchmark_results

# Do the cleanup
cleanup

exit 0

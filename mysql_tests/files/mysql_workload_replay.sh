#!/bin/bash -u

# Configuration options
# The prod master that was used to capture prod workload
master_host=

# The host that we want to compare the performance too
compare_host=

# The host that we want to benchmark to guage performance
target_host=

# The directory where the benchmark related data will be stored
output_dir=

# Run the benchmark against this many active schemas
num_db_benchmark=1

# Read-only MySQL user credentials
mysql_username=
mysql_password=

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

function test_mysql_access() {
#    set -x
    local host=$1
    [[ "${host}" != '' ]] && ${mysqladmin_bin} --host=${host} --user=${mysql_username} --password=${mysql_password} ping >/dev/null 2>&1

    echo $?
#    set +x
}

function setup_directories() {
    vlog "Setting up directory ${output_dir} ${target_tmp_dir} ${compare_host_tmp_dir} ${master_tmp_dir}"
    mkdir -p ${output_dir} ${target_tmp_dir} ${compare_host_tmp_dir} ${master_tmp_dir}
}

function generate_slowlog_from_tcpdump() {
#    set -x

    vlog "Generating slowlog file from tcpdump to be used for benchmarking"

    local tcpdump_file="${master_tmp_dir}/${tcpdump_filename}"
    local slowlog_file="${master_tmp_dir}/${ptqd_slowlog_name}"

    ${pt_query_digest_bin} --type tcpdump ${tcpdump_file} \
        --output slowlog --no-report \
        --filter '($event->{fingerprint} =~ m/^select/i) && ($event->{arg} !~ m/for update/i) && ($event->{fingerprint} !~ m/users_online/i)' \
        > ${slowlog_file} 2> /dev/null

    vlog "Slow log successfully generated and written to ${slowlog_file}"

#    set +x
}

function get_active_db_list() {
    # Get the name of the most active database
    local ignore_db_list="'mysql', 'information_schema', 'performance_schema'"
    local mysql_args=

    sql="SELECT db FROM processlist WHERE db IS NOT NULL AND db NOT in (${ignore_db_list}) GROUP BY db ORDER BY COUNT(*) DESC LIMIT ${num_db_benchmark}"
    mysql_args="--host=${master_host} --user=${mysql_username} --password=${mysql_password}"

    db_list=$(${mysql_bin} --host=${master_host} --user=${mysql_username} \
                --password=${mysql_password} information_schema -e "${sql}" -NB)

    echo ${db_list}
}

function get_source_mysql_thd_conc() {
#    set -x

    local thd_concurrency=$(${mysqladmin_bin} --host=${master_host} \
                            --user=${mysql_username} --password=${mysql_password} \
                            -i 1 -c 30 extended-status \
                            | awk 'BEGIN {cnt=0; sum=0;} /Threads_running/ {cnt=cnt+1; sum=sum+$4} END {printf "%d\n", (sum/cnt)}')
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

    mkdir -p ${master_sessions_dir} ${compare_host_results_dir} ${target_results_dir}

    # Get list of active DBs
    vlog "Fetching the list of active DBs from the master ${master_host}"
    local active_db_list=$(get_active_db_list)
    if [[ "${active_db_list}" == "" ]]
    then
        echo "No database schemas found to run benchmark against"
        exit 22
    fi

    vlog "Preparing the session files for pt-log-player"
    ${pt_log_player_bin} --split-random --session-files ${mysql_thd_conc} \
        --base-dir ${master_sessions_dir} ${slowlog_file} \
        > ${master_tmp_dir}/pt_log_player.log \
        2> ${master_tmp_dir}/pt_log_player.err

    # Warm up the buffer pool on the compare_host and target hosts
    if [[ "${benchmark_cold_run}" == "0" ]]; then
        for host in ${compare_host} ${target_host}; do
            vlog "Warming up the buffer pool on the host ${host}"
            for db in ${active_db_list}; do
                echo "Warming up schema ${db}"
                ${pt_log_player_bin} --user ${mysql_username} \
                    --password ${mysql_password} --play ${master_sessions_dir} \
                    --set-vars innodb_lock_wait_timeout=1 --only-select \
                    --threads ${mysql_thd_conc} --no-results --iterations=3 \
                    h=${host},D=${db} &> /dev/null
                done
        done
    fi

    # Run the benchmark against the compare_host
    vlog "Starting to run the benchmark on the host ${compare_host} with a concurrency of ${mysql_thd_conc}"

    for db in ${active_db_list}; do
        echo "Benchmarking the schema ${db}"
        ${pt_log_player_bin} --user ${mysql_username} \
            --password ${mysql_password} --play ${master_sessions_dir} \
            --set-vars innodb_lock_wait_timeout=1 \
            --base-dir ${compare_host_results_dir} --only-select \
            --threads ${mysql_thd_conc} h=${compare_host},D=${db} \
            > ${compare_host_tmp_dir}/pt_log_player.log \
            2> ${compare_host_tmp_dir}/pt_log_player.err
    done

    # Run the benchmark against the target host
    vlog "Starting to run the benchmark on the target host ${target_host} with a concurrency of ${mysql_thd_conc}"

    for db in ${active_db_list}; do
        echo "Benchmarking the schema ${db}"
        ${pt_log_player_bin} --user ${mysql_username} \
            --password ${mysql_password} --play ${master_sessions_dir} \
            --set-vars innodb_lock_wait_timeout=1 \
            --base-dir ${target_results_dir} --only-select \
            --threads ${mysql_thd_conc} h=${target_host},D=${db} \
            > ${target_tmp_dir}/pt_log_player.log \
            2> ${target_tmp_dir}/pt_log_player.err
    done

    # Generating the pt-query-digest reports
    vlog "Generating the pt-query-digest reports on the benchmark runs"
    for dir in ${compare_host_tmp_dir} ${target_tmp_dir}; do
        ${pt_query_digest_bin} ${dir}/results/* --limit=100 > ${dir}/ptqd.txt
    done

    vlog "Benchmarks completed."

#    set +x
}

function print_benchmark_results() {
    echo
    echo "###########################################################################"
    echo "Queries benchmark summary from the host ${compare_host}"
    awk '/user time,/,/# Query size/' ${compare_host_tmp_dir}/ptqd.txt | grep -v "# Files:" | grep -v "# Hostname:"

    echo
    echo "Queries benchmark summary from the target ${target_host}"
    awk '/user time,/,/# Query size/' ${target_tmp_dir}/ptqd.txt | grep -v "# Files:" | grep -v "# Hostname:"

    local compare_host_qps_95th=$(awk '/user time,/,/# Query size/' ${compare_host_tmp_dir}/ptqd.txt | grep "# Exec time" | awk '{print $8}')
    local target_qps_95th=$(awk '/user time,/,/# Query size/' ${target_tmp_dir}/ptqd.txt | grep "# Exec time" | awk '{print $8}')

    echo
    echo "95th-per query exec time: ${compare_host_qps_95th} on ${compare_host} vs ${target_qps_95th} on ${target_host}"
    echo "Detailed reports are available at ${output_dir}"
    echo "###########################################################################"
}

# Usage info
function show_help() {
cat << EOF
Usage: ${0##*/} --master-host MASTER_HOST --compare-host COMPARE_HOST --target-host TARGET_HOST --output-dir OUTPUT_DIR --mysql_user MYSQL_USER --mysql_password MYSQL_PASSWORD [options]
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
    --output-dir OUTPUT_DIR         the directory that stores the benchmark
                                    reports
    --mysql_user MYSQL_USER         the MySQL read-only username that would
                                    be used to run the queries
    --mysql_password MYSQL_PASSWORD the MySQL read-only user password
    --cold-run                      run the benchmark with cold InnoDB Buffer
                                    Pool cache, this is disabled by default
EOF
}

function show_help_and_exit() {
    show_help >&2
    exit 22 # Invalid parameters
}

# Command line processing
OPTS=$(getopt -o hcm:s:T:o:u:p: --long help,cold-run,master-host:,compare-host:,target-host:,output-dir:,mysql-user:,mysql-password: -n 'mysql_workload_replay.sh' -- "$@")
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

[[ -z ${output_dir} ]] && show_help_and_exit >&2

[[ -z ${mysql_username} ]] && show_help_and_exit >&2

[[ -z ${mysql_password} ]] && show_help_and_exit >&2

# Setup temporary directories
master_tmp_dir="${output_dir}/${master_host}"
compare_host_tmp_dir="${output_dir}/${compare_host}"
target_tmp_dir="${output_dir}/${target_host}"

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
    if (( $(which $tool_bin &> /dev/null; echo $?) != 0 )); then
        echo "Can't find $tool_bin"
        exit 22 # OS error code  22:  Invalid argument
    fi
done

# Test that MySQL credentials are correct
for host in ${master_host} ${compare_host} ${target_host}; do
    if (( $(test_mysql_access ${host}) != 0 )); then
        echo "Could not connect to MySQL on ${host}"
        exit 2003
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
print_benchmark_results

# Do the cleanup
cleanup

exit 0

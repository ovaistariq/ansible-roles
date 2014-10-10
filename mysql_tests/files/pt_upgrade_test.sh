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

# The temporary directories names
master_tmp_dir=
compare_host_tmp_dir=
target_tmp_dir=

# How many occurrences per query fingerprint
ptqd_samples_per_query=100

# Setup file prefixes
tcpdump_filename=mysql.tcp
ptqd_slowlog_name="mysql.slow.${ptqd_samples_per_query}_samples_per_query.log"

# Setup tools
mysqladmin_bin="/usr/bin/mysqladmin"
mysql_bin="/usr/bin/mysql"
pt_query_digest_bin="/usr/bin/pt-query-digest"
pt_upgrade_bin="/usr/bin/pt-upgrade"

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

    #TODO: add code to cleanup any running ptqd and pt-upgrade processes
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

    vlog "Generating slowlog file from tcpdump to be used by pt-upgrade"

    local slowlog_file="${master_tmp_dir}/${ptqd_slowlog_name}"
    local tcpdump_file="${master_tmp_dir}/${tcpdump_filename}"

    ptqd_args="--type tcpdump ${tcpdump_file} --output slowlog --no-report --sample ${ptqd_samples_per_query} --filter '(\$event->{fingerprint} =~ m/^select/i) && (\$event->{arg} !~ m/for update/i) && (\$event->{fingerprint} !~ m/users_online/i)'"

    vlog "Executing ${pt_query_digest_bin} ${ptqd_args} on ${target_host}"
    ssh ${target_host} "${pt_query_digest_bin} ${ptqd_args} > ${slowlog_file} 2> /dev/null"

    vlog "Slow log for pt-upgrade successfully generated and written to ${slowlog_file}"

#    set +x
}

function run_upgrade_test() {
#    set -x

    local slowlog_file="${master_tmp_dir}/${ptqd_slowlog_name}"
    local pt_upgrade_report="${target_tmp_dir}/pt_upgrade.log"

    ptupg_args="--run-time=1h --upgrade-table=percona.pt_upgrade --report=hosts,stats --charset=utf8 ${slowlog_file} h=${target_host} h=${compare_host}"

    vlog "Executing ${pt_upgrade_bin} ${ptupg_args} on ${target_host}"
    ssh ${target_host} "${pt_upgrade_bin} ${ptupg_args} > ${pt_upgrade_report}"

    scp ${target_host}:${pt_upgrade_report} ${output_dir}/${target_host}-pt_upgrade.log &> /dev/null

    local num_lines=$(wc -l ${output_dir}/${target_host}-pt_upgrade.log | awk '{print $1}')
    local stats_headline_line_num=$(grep -n "# Stats" ${output_dir}/${target_host}-pt_upgrade.log | awk -F: '{print $1}')

    echo
    echo "###########################################################################"
    echo "Queries summary from running pt-upgrade on ${target_host},${compare_host}"
    echo
    tail -$(( ${num_lines} - ${stats_headline_line_num} - 2 )) ${output_dir}/${target_host}-pt_upgrade.log
    echo "Detailed reports are available at ${output_dir}/${target_host}-pt_upgrade.log"
    echo "###########################################################################"

#    set +x
}

# Usage info
function show_help() {
cat << EOF
Usage: ${0##*/} --master-host MASTER_HOST --compare-host COMPARE_HOST --target-host TARGET_HOST --target-tmpdir TARGET_TMPDIR --output-dir OUTPUT_DIR [options]
Run pt-upgrade against MySQL production workload on SLAVE_HOST and TARGET_HOST and compare the query results.

Options:

    --help                          display this help and exit
    --master-host MASTER_HOST       the master host actively executing
                                    production traffic that will be used to
                                    capture queries via tcpdump
    --compare-host COMPARE_HOST     the compare host which is to be benchmarked
                                    and which will be used as a baseline
    --target-host TARGET_HOST       the host that has to be benchmarked
    --target-tmpdir TARGET_TMPDIR   the directory on TARGET_HOST that will be
                                    used for temporary files needed during
                                    the benchmark
    --output-dir OUTPUT_DIR         the directory that stores the benchmark
                                    reports
EOF
}

function show_help_and_exit() {
    show_help >&2
    exit 22 # Invalid parameters
}

# Command line processing
OPTS=$(getopt -o hm:s:T:t:o: --long help,master-host:,compare-host:,target-host:,target-tmpdir:,output-dir: -n 'pt_upgrade_test.sh' -- "$@")
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

for host in ${compare_host} ${target_host}; do
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

for tool_bin in ${pt_query_digest_bin} ${pt_upgrade_bin}; do
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
run_upgrade_test

# Do the cleanup
cleanup

exit 0

#!/bin/bash -u

# Configuration options
# The prod master that was used to capture prod workload
master_host=

# The host that we want to compare the performance too
compare_host=

# The host that we want to benchmark to guage performance
target_host=

# The directory where the pt-upgrade related data will be stored
output_dir=

# Read-only MySQL user credentials
mysql_username=
mysql_password=

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
    vlog "Setting up directory ${output_dir} ${target_tmp_dir} ${compare_host_tmp_dir} ${master_tmp_dir}"
    mkdir -p ${output_dir} ${target_tmp_dir} ${compare_host_tmp_dir} ${master_tmp_dir}
}

function generate_slowlog_from_tcpdump() {
#    set -x

    vlog "Generating slowlog file from tcpdump to be used by pt-upgrade"

    local slowlog_file="${master_tmp_dir}/${ptqd_slowlog_name}"
    local tcpdump_file="${master_tmp_dir}/${tcpdump_filename}"

    ${pt_query_digest_bin} --type tcpdump ${tcpdump_file} --output slowlog \
        --no-report --sample ${ptqd_samples_per_query} \
        --filter '($event->{fingerprint} =~ m/^select/i) && ($event->{arg} !~ m/for update/i) && ($event->{fingerprint} !~ m/users_online/i)' \
        > ${slowlog_file} 2> /dev/null

    vlog "Slow log for pt-upgrade successfully generated and written to ${slowlog_file}"

#    set +x
}

function run_upgrade_test() {
#    set -x

    local slowlog_file="${master_tmp_dir}/${ptqd_slowlog_name}"
    local pt_upgrade_report="${target_tmp_dir}/pt_upgrade.log"

    vlog "Executing ${pt_upgrade_bin}"
    ${pt_upgrade_bin} --user ${mysql_username} \
        --password ${mysql_password} --run-time=1h \
        --upgrade-table=percona.pt_upgrade --report=hosts,stats --charset=utf8 \
        ${slowlog_file} h=${target_host} h=${compare_host} > ${pt_upgrade_report}

    local num_lines=$(wc -l ${pt_upgrade_report} | awk '{print $1}')
    local stats_headline_line_num=$(grep -n "# Stats" ${pt_upgrade_report} | awk -F: '{print $1}')

    echo
    echo "###########################################################################"
    echo "Queries summary from running pt-upgrade on ${target_host},${compare_host}"
    echo
    tail -$(( ${num_lines} - ${stats_headline_line_num} - 2 )) ${pt_upgrade_report}
    echo "Detailed report is available at:"
    echo "${pt_upgrade_report}"
    echo "###########################################################################"

#    set +x
}

# Usage info
function show_help() {
cat << EOF
Usage: ${0##*/} --master-host MASTER_HOST --compare-host COMPARE_HOST --target-host TARGET_HOST --output-dir OUTPUT_DIR --mysql_user MYSQL_USER --mysql_password MYSQL_PASSWORD [options]
Run pt-upgrade against MySQL production workload on SLAVE_HOST and TARGET_HOST and compare the query results.

Options:

    --help                          display this help and exit
    --master-host MASTER_HOST       the master host actively executing
                                    production traffic that will be used to
                                    capture queries via tcpdump
    --compare-host COMPARE_HOST     the compare host which is to be benchmarked
                                    and which will be used as a baseline
    --target-host TARGET_HOST       the host that has to be benchmarked
    --output-dir OUTPUT_DIR         the directory that stores the pt-upgrade
                                    reports
    --mysql_user MYSQL_USER         the MySQL read-only username that would
                                    be used to run the queries
    --mysql_password MYSQL_PASSWORD the MySQL read-only user password
EOF
}

function show_help_and_exit() {
    show_help >&2
    exit 22 # Invalid parameters
}

# Command line processing
OPTS=$(getopt -o hm:s:T:o:u:p: --long help,master-host:,compare-host:,target-host:,output-dir:,mysql-user:,mysql-password: -n 'pt_upgrade_test.sh' -- "$@")
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

for tool_bin in ${pt_query_digest_bin} ${pt_upgrade_bin}; do
    if (( $(which ${tool_bin} &> /dev/null; echo $?) != 0 )); then
        echo "Can't find ${tool_bin}"
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

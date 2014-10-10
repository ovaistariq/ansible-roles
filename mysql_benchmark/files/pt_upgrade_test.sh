#!/bin/bash -u

# Configuration options
script_root=$(dirname $(readlink -f $0))
current_date=$(date +%Y_%m_%d_%H_%M_%S)

# The prod master that will be used to calculate thread concurrency and list
# of active databases that will be used during the benchmark queries run
master_host=

# The host that we want to compare the performance too
slave_host=

# The host that we want to benchmark to guage performance
target_host=

# The directory on the target host where benchmark data will be temporarily 
# stored
tmp_dir=

# The directory where the benchmark report will be stored
output_dir=

# In test only mode only MySQL access testing is performed
test_only=

# These should be read-only MySQL users
mysql_username=
mysql_password=

# The temporary directories names
master_tmp_dir=
slave_tmp_dir=
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
    vlog "Setting up directories ${tmp_dir} ${slave_tmp_dir} ${target_tmp_dir} on target host"

    # Initialize temp directories to target host
    ssh -q ${target_host} "mkdir -p ${tmp_dir} ${slave_tmp_dir} ${target_tmp_dir}"

    vlog "Setting up directory ${output_dir} on localhost"
    mkdir -p ${output_dir}
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

    # Test for MySQL access from the target host
    test_mysql_access
    ret_code=$?
    exit ${ret_code}
#    set +x
}

function generate_slowlog_from_tcpdump() {
#    set -x

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

    ptupg_args="--run-time=1h --upgrade-table=percona.pt_upgrade --report=hosts,stats --charset=utf8 --user=${mysql_username} --password=${mysql_password} ${slowlog_file} h=${target_host} h=${slave_host}"

    vlog "Executing ${pt_upgrade_bin} ${ptupg_args} on ${target_host}"
    ssh ${target_host} "${pt_upgrade_bin} ${ptupg_args} > ${pt_upgrade_report}"

    scp ${target_host}:${pt_upgrade_report} ${output_dir}/target-${target_host}-pt_upgrade.log &> /dev/null

    vlog "Pt-upgrade run completed. Detailed report is available at ${output_dir}/target-${target_host}-pt_upgrade.log"
#    set +x
}

# Usage info
function show_help() {
cat << EOF
Usage: ${0##*/} --master-host MASTER_HOST --slave-host SLAVE_HOST --target-host TARGET_HOST --target-tmpdir TARGET_TMPDIR --mysql-user MYSQL_USERNAME --mysql-password MYSQL_PASSWORD [options]
Run pt-upgrade against MySQL production workload on SLAVE_HOST and TARGET_HOST and compare the query results.

Options:

    --help                          display this help and exit
    --master-host MASTER_HOST       the master host actively executing
                                    production traffic that will be used to
                                    capture queries via tcpdump
    --slave-host SLAVE_HOST         the slave host which is to be benchmarked
                                    and which will be used as a baseline
    --target-host TARGET_HOST       the host that has to be benchmarked
    --target-tmpdir TARGET_TMPDIR   the directory on TARGET_HOST that will be
                                    used for temporary files needed during
                                    the benchmark
    --output-dir OUTPUT_DIR         the directory that stores the benchmark
                                    reports
    --mysql-user MYSQL_USERNAME     the name of the MySQL user that will be
                                    used to replay the benchmark queries on
                                    SLAVE_HOST and TARGET_HOST
    --mysql-password MYSQL_PASSWORD the password for the MySQL user
EOF
}

function show_help_and_exit() {
    show_help >&2
    exit 22 # Invalid parameters
}

# Command line processing
OPTS=$(getopt -o hm:s:T:t:o:u:p: --long help,master-host:,slave-host:,target-host:,target-tmpdir:,output-dir:,mysql-user:,mysql-password: -n 'pt_upgrade_test.sh' -- "$@")
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

for host in ${slave_host} ${target_host}; do
    ssh -q ${host} "exit"
    (( $? != 0 )) && show_error_n_exit "Could not SSH into ${host}"
done

[[ -z ${tmp_dir} ]] && show_help_and_exit >&2

[[ -z ${output_dir} ]] && show_help_and_exit >&2

[[ -z ${mysql_username} ]] && show_help_and_exit >&2

[[ -z ${mysql_password} ]] && show_help_and_exit >&2

# Setup temporary directories
master_tmp_dir="${tmp_dir}/master-${master_host}"
slave_tmp_dir="${tmp_dir}/slave-${slave_host}"
target_tmp_dir="${tmp_dir}/target-${target_host}"

# Test that all tools are available
for tool_bin in ${mysqladmin_bin} ${mysql_bin}; do
    for host in ${master_host} ${slave_host} ${target_host}; do
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

# Test if nc based sockets work to/from source and target hosts
# and test for MySQL connectivity.
[[ ! -z ${test_only} ]] && do_test


# Do the actual stuff
trap cleanup HUP PIPE INT TERM

# Setup the directories needed on the source and target hosts
setup_directories

# Parse the source host tcpdump and generate slow log from it
# This will be used by percona-playback
vlog "Generating slowlog file from tcpdump to be used by pt-upgrade"
generate_slowlog_from_tcpdump

# Do the benchmark run
run_upgrade_test

# Do the cleanup
cleanup

exit 0

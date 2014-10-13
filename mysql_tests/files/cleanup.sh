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
ptqd_slowlog_name=mysql.slow.log
ptqd_slowlog_name_pt_upgrade="mysql.slow.${ptqd_samples_per_query}_samples_per_query.log"

# Function definitions
function vlog() {
    datetime=$(date "+%Y-%m-%d %H:%M:%S")
    msg="[${datetime}] $1"

    echo ${msg}
}

function cleanup() {
    vlog "Cleaning up slow log files"

    local slowlog_file="${master_tmp_dir}/${ptqd_slowlog_name}"
    local slowlog_file_pt_upgrade="${master_tmp_dir}/${ptqd_slowlog_name_pt_upgrade}"
    local tcpdump_file="${master_tmp_dir}/${tcpdump_filename}"

    rm -rf ${slowlog_file} ${slowlog_file_pt_upgrade} ${tcpdump_file}

    vlog "Cleaning up temporary files created by pt-log-player"

    rm -rf ${master_tmp_dir}/sessions ${compare_host_tmp_dir}/results ${target_tmp_dir}/results

    vlog "Cleanup completed"
}

# Usage info
function show_help() {
cat << EOF
Usage: ${0##*/} --master-host MASTER_HOST --compare-host COMPARE_HOST --target-host TARGET_HOST --output-dir OUTPUT_DIR [options]
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
EOF
}

function show_help_and_exit() {
    show_help >&2
    exit 22 # Invalid parameters
}

# Command line processing
OPTS=$(getopt -o hm:s:T:o: --long help,master-host:,compare-host:,target-host:,output-dir: -n 'cleanup.sh' -- "$@")
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

# Setup temporary directories
master_tmp_dir="${output_dir}/${master_host}"
compare_host_tmp_dir="${output_dir}/${compare_host}"
target_tmp_dir="${output_dir}/${target_host}"

# Do the actual stuff
trap cleanup HUP PIPE INT TERM

# Do the cleanup
cleanup

exit 0

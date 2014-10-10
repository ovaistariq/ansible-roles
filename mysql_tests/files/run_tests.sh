#!/bin/bash -u

## Configuration options
test_scripts_root=$(dirname $(readlink -f $0))
workload_capture_script="${test_scripts_root}/mysql_workload_capture.sh"
workload_replay_script="${test_scripts_root}/mysql_workload_replay.sh"
pt_upgrade_test_script="${test_scripts_root}/pt_upgrade_test.sh"

current_datetime=$(date +%Y_%m_%d_%H_%M_%S)

# The prod master that was used to capture prod workload
master_host=

# The host that we want to compare the performance too
compare_host=

# The host that we want to benchmark to guage performance
target_host=

# The amount of seconds up to which tcpdump must be run to capture the queries
tcpdump_time_limit_sec=

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


# Function definitions
# Usage info
function show_help() {
cat << EOF
Usage: ${0##*/} --master-host MASTER_HOST --compare-host COMPARE_HOST --target-host TARGET_HOST --tcpdump-seconds TCPDUMP_TIME_LIMIT_SEC --target-tmpdir TARGET_TMPDIR --output-dir OUTPUT_DIR [options]
Replay MySQL production workload in tcpdump format on SLAVE_HOST and TARGET_HOST and compare the query times.

Options:

    --help                                   display this help and exit
    --master-host MASTER_HOST                the master host actively executing
                                             production traffic that will be
                                             used to capture queries via tcpdump
    --compare-host COMPARE_HOST              the host which is to be benchmarked
                                             and which will be used as a
                                             baseline to compare the performance
                                             of target_host
    --target-host TARGET_HOST                the host that has to be benchmarked
    --tcpdump-seconds TCPDUMP_TIME_LIMIT_SEC the number of seconds for which
                                             tcpdump will be run on MASTER_HOST
    --target-tmpdir TARGET_TMPDIR            the directory on TARGET_HOST that
                                             will be used for temporary files
                                             needed during the benchmark
    --output-dir OUTPUT_DIR                  the directory that stores the
                                             benchmark reports
    --cold-run                               run the benchmark with cold InnoDB
                                             Buffer Pool cache, this is disabled
                                             by default
EOF
}

function show_help_and_exit() {
    show_help >&2
    exit 22 # Invalid parameters
}

# Command line processing
OPTS=$(getopt -o hcm:s:T:l:t:o: --long help,cold-run,master-host:,compare-host:,target-host:,tcpdump-seconds:,target-tmpdir:,output-dir: -n 'run_tests.sh' -- "$@")
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

[[ -z ${tcpdump_time_limit_sec} ]] && show_help_and_exit >&2

${workload_capture_script} \
    --master-host ${master_host} \
    --target-host ${target_host} \
    --tcpdump-seconds ${tcpdump_time_limit_sec} \
    --output-dir ${tmp_dir}

${workload_replay_script} \
    --master-host ${master_host} \
    --compare-host ${compare_host} \
    --target-host ${target_host} \
    --target-tmpdir ${tmp_dir} \
    --output-dir ${output_dir} \
    --cold-run

${pt_upgrade_test_script} \
    --master-host ${master_host} \
    --compare-host ${compare_host} \
    --target-host ${target_host} \
    --target-tmpdir ${tmp_dir} \
    --output-dir ${output_dir}


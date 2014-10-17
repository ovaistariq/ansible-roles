#!/bin/bash -ux

# Configuration options
# The MySQL server that will be used as the source of the dump
backup_source_host=

# The host that will reload the dump and will be setup as slave
target_host=

# Is the backup_source_host a master?
# This is used when configuring replication.
# If the backup_source_host is master, then output of 'SHOW MASTER STATUS' is
# used to setup replication.
# If the backup_source_host is a slave, then output of 'SHOW SLAVE STATUS' is
# used to setup replication.
# By default backup_source_host is implied to be a slave
backup_source_is_master=false

# The directory on target_host where dump files will be temporarily stored
target_dump_dir=

# The directory where the dump and reload related logs will be stored
output_dir=

# Read-only MySQL user credentials that will be used to dump the MySQL data
mysql_username=
mysql_password=

# Replication MySQL users that will be used to setup replication
mysql_repl_username=
mysql_repl_password=

# Miscellaneous parameters
data_dump_dir=
mydumper_log=
myloader_log=
num_backup_dump_threads=16
num_backup_reload_threads=16

# Setup tools
mysqladmin_bin="/usr/bin/mysqladmin"
mysql_bin="/usr/bin/mysql"
mydumper_bin="/usr/bin/mydumper"
myloader_bin="/usr/bin/myloader"

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

    ssh ${target_host} "rm -rf ${target_dump_dir}"

    #TODO: add code to cleanup any running child processes
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

    local mysqladmin_args="--host=${backup_source_host} --user=${mysql_username} --password=${mysql_password}"
    local is_mysqld_alive=$(ssh ${target_host} "${mysqladmin_bin} ${mysqladmin_args} ping" 2> /dev/null)

    if [[ "${is_mysqld_alive}" != "mysqld is alive" ]]; then
        echo 2003 # MySQL error code for connection error
    else
        echo 0
    fi
#    set +x
}

function setup_directories() {
#    set -x

    vlog "Setting up directory ${target_dump_dir} ${data_dump_dir} on ${target_host}"
    ssh -q ${target_host} "mkdir -p ${target_dump_dir} ${data_dump_dir}"

    vlog "Setting up directory ${output_dir}"
    mkdir -p ${output_dir}

#    set +x
}

function dump_mysql_data() {
#    set -x

    vlog "Preparing to dump MySQL data"

    local mydumper_args="--outputdir ${data_dump_dir} --compress --build-empty-files --long-query-guard 300 --kill-long-queries --host ${backup_source_host} --user ${mysql_username} --password ${mysql_password} --threads ${num_backup_dump_threads} --verbose 3"

    vlog "Starting to dump MySQL data from ${backup_source_host} using mydumper with arguments ${mydumper_args}"
    ssh ${target_host} "${mydumper_bin} ${mydumper_args} > ${mydumper_log} 2>&1"

    if (( $? != 0 )); then
        echo "mydumper failed to complete successfully"
        exit 22
    fi

    # copy the mydumper log to the host running this script
    scp ${target_host}:${mydumper_log} ${output_dir}/${mydumper_log} &> /dev/null

    # copy the data dump metadata file
    scp ${target_host}:${data_dump_dir}/metadata ${output_dir}/metadata &> /dev/null

    vlog "MySQL data dump successfully completed. Log is available at ${output_dir}/${mydumper_log}"

#    set +x
}

function create_user_to_reload_dump() {
#    set -x

    local mysql_args="--user=root --password=''"

    vlog "Creating user ${mysql_username}@localhost on ${target_host} to reload the dump"
    ssh ${target_host} "${mysql_bin} ${mysql_args} -e \"GRANT ALL PRIVILEGES ON *.* TO ${mysql_username}@'localhost' IDENTIFIED BY '${mysql_password}'\""

    if (( $? != 0 )); then
        echo "Failed to create the user ${mysql_username}@localhost"
        exit 22
    fi

#    set +x
}

function reload_mysql_data() {
#    set -x

    vlog "Preparing to reload MySQL data"

    local myloader_args="--directory ${data_dump_dir} --overwrite-tables --host localhost --user ${mysql_username} --password ${mysql_password} --threads ${num_backup_reload_threads} --verbose 3"

    vlog "Starting to reload MySQL data on ${target_host} using myloader with arguments ${myloader_args}"
    ssh ${target_host} "${myloader_bin} ${myloader_args} > ${myloader_log} 2>&1"

    scp ${target_host}:${myloader_log} ${output_dir}/${myloader_log} &> /dev/null

    # I am seeing unusual errors where MySQL is reporting a duplicate record
    # when replaying the dump, although there is no duplicate record there"
    # So below is hack to ignore those errors
    local num_errors=$(grep -c Error ${output_dir}/${myloader_log})
    local num_errors_mysql_innodb_tbl_duplicate_entry=$(grep 'Error restoring mysql.innodb' ${output_dir}/${myloader_log} | grep -c 'Duplicate entry')

    if (( ${num_errors} > 0 )); then
        vlog "Following errors were detected during myloader run:"
        grep Error ${output_dir}/${myloader_log}
    fi

    if (( ${num_errors} > ${num_errors_mysql_innodb_tbl_duplicate_entry} )); then
        exit 22
    fi

    # Reloading MySQL privileges because mysql db would have been reloaded
    local mysql_args="--user=${mysql_username} --password=${mysql_password}"
    ssh ${target_host} "${mysql_bin} ${mysql_args} -e \"FLUSH PRIVILEGES\""

    vlog "MySQL data successfully reloaded. Log is available at ${myloader_log} on ${target_host}"

#    set +x
}

function setup_replication() {
#    set -x

    local backup_metadata_file="${output_dir}/metadata"
    local repl_master=
    local binlog_filename=
    local binlog_position=
    local change_master_sql=

    local mysql_args="--user=${mysql_username} --password=${mysql_password}"

    if [[ "${backup_source_is_master}" == "true" ]]; then
        repl_master=${backup_source_host}
        binlog_filename=$(grep -A 2 'SHOW MASTER STATUS:' ${backup_metadata_file} | awk '/Log:/ {print $2}')
        binlog_position=$(grep -A 2 'SHOW MASTER STATUS:' ${backup_metadata_file} | awk '/Pos:/ {print $2}')
    else
        repl_master=$(grep -A 3 'SHOW SLAVE STATUS:' ${backup_metadata_file} | awk '/Host:/ {print $2}')
        binlog_filename=$(grep -A 3 'SHOW SLAVE STATUS:' ${backup_metadata_file} | awk '/Log:/ {print $2}')
        binlog_position=$(grep -A 3 'SHOW SLAVE STATUS:' ${backup_metadata_file} | awk '/Pos:/ {print $2}')
    fi

    if [[ "${binlog_filename}" == "" ]] || [[ "${binlog_position}" == "" ]] || [[ "${repl_master}" == "" ]]; then
        echo "Binary log coordinates could not be parsed from the ${backup_metadata_file} file. Make sure the file exists and is not empty"
        exit 2014
    fi

    change_master_sql="CHANGE MASTER TO MASTER_HOST='${repl_master}', MASTER_LOG_FILE='${binlog_filename}', MASTER_LOG_POS=${binlog_position}"
    vlog "Executing ${change_master_sql}"

    ssh ${target_host} "${mysql_bin} ${mysql_args} -e \"${change_master_sql}, MASTER_USER='${mysql_repl_username}', MASTER_PASSWORD='${mysql_repl_password}'\""

    if (( $? != 0 )); then
        echo "Failed to execute CHANGE MASTER"
        exit 22
    fi

    ssh ${target_host} "${mysql_bin} ${mysql_args} -e \"START SLAVE\""

    sleep 5
    vlog "Replication setup successfully"

    vlog "Current slave status:"
    ssh ${target_host} "${mysql_bin} ${mysql_args} -e \"SHOW SLAVE STATUS\G\""

#    set +x
}

# Usage info
function show_help() {
cat << EOF
Usage: ${0##*/} --backup-source-host BACKUP_SOURCE_HOST --target-host TARGET_HOST --target-tmp-dir TARGET_TMP_DIR --output-dir OUTPUT_DIR --mysql-user MYSQL_USER --mysql-password MYSQL_PASSWORD --mysql-repl-user MYSQL_REPL_USER --mysql-repl-password MYSQL_REPL_PASSWD [options]
Take dump from MySQL server BACKUP_SOURCE_HOST and use the dump to setup TARGET_HOST as slave

Options:

    --help                                  display this help and exit
    --backup-source-host BACKUP_SOURCE_HOST the host that will be used as the
                                            source of the dump
    --target-host TARGET_HOST               the host that has to be setup as
                                            the slave
    --target-tmp-dir TARGET_TMP_DIR         the directory on the target-host
                                            that will temporarily store the
                                            dump and reload related data
    --output-dir OUTPUT_DIR                 the directory that will store the
                                            dump and reload related logs
    --mysql-user MYSQL_USER                 the MySQL username that would be
                                            used to dump the MySQL data
    --mysql-password MYSQL_PASSWORD         the MySQL user password
    --mysql-repl-user MYSQL_REPL_USER       the MySQL username that would by
                                            replication
    --mysql-repl-password MYSQL_REPL_PASSWD the MySQL replication user password
    --backup-source-is-master               should the BACKUP_SOURCE_HOST be
                                            used as the master
EOF
}

function show_help_and_exit() {
    show_help >&2
    exit 22 # Invalid parameters
}

# Command line processing
OPTS=$(getopt -o hcb:T:t:o:u:p:U:P: --long help,backup-source-is-master,backup-source-host:,target-host:,target-tmp-dir:,output-dir:,mysql-user:,mysql-password:,mysql-repl-user:,mysql-repl-password: -n 'clone_slave_dump_reload.sh' -- "$@")
[ $? != 0 ] && show_help_and_exit

eval set -- "$OPTS"

while true; do
  case "$1" in
    -b | --backup-source-host )
                                backup_source_host="$2";
                                shift; shift
                                ;;
    -T | --target-host )
                                target_host="$2";
                                shift; shift
                                ;;
    -t | --target-tmp-dir )
                                target_dump_dir="$2";
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
    -U | --mysql-repl-user )
                                mysql_repl_username="$2";
                                shift; shift
                                ;;
    -P | --mysql-repl-password )
                                mysql_repl_password="$2";
                                shift; shift
                                ;;
    -c | --backup-source-is-master )
                                backup_source_is_master=true
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
[[ -z ${backup_source_host} ]] && show_help_and_exit >&2

[[ -z ${target_host} ]] && show_help_and_exit >&2

ssh -q ${target_host} "exit"
(( $? != 0 )) && show_error_n_exit "Could not SSH into ${target_host}"

[[ -z ${target_dump_dir} ]] && show_help_and_exit >&2

[[ -z ${output_dir} ]] && show_help_and_exit >&2

[[ -z ${mysql_username} ]] && show_help_and_exit >&2

[[ -z ${mysql_password} ]] && show_help_and_exit >&2

[[ -z ${mysql_repl_username} ]] && show_help_and_exit >&2

[[ -z ${mysql_repl_password} ]] && show_help_and_exit >&2

# Setup various config options
data_dump_dir="${target_dump_dir}/data_dump"
mydumper_log="${target_dump_dir}/mydumper.log"
myloader_log="${target_dump_dir}/myloader.log"

# Test that all tools are available
for tool_bin in ${mysqladmin_bin} ${mysql_bin}; do
    for host in ${backup_source_host} ${target_host}; do
        if (( $(ssh ${host} "which $tool_bin" &> /dev/null; echo $?) != 0 )); then
            echo "Can't find $tool_bin on ${host}"
            exit 22 # OS error code  22:  Invalid argument
        fi
    done
done

for tool_bin in ${mydumper_bin} ${myloader_bin}; do
    if (( $(ssh ${target_host} "which $tool_bin" &> /dev/null; echo $?) != 0 )); then
        echo "Can't find $tool_bin on ${target_host}"
        exit 22 # OS error code  22:  Invalid argument
    fi
done

# Test that MySQL credentials are correct
vlog "Testing MySQL access from ${target_host} to ${backup_source_host}"
if (( $(test_mysql_access) != 0 )); then
    echo "Could not connect to MySQL"
    exit 2003
fi

# Do the actual stuff
trap cleanup HUP PIPE INT TERM

# Setup the directories needed on the source and target hosts
setup_directories

# Dump the MySQL data from backup_source_host
dump_mysql_data

# Create the user that will be used to reload the dump
create_user_to_reload_dump

# Reload MySQL data onto target_host
reload_mysql_data

# Configure replication
setup_replication

# Do the cleanup
cleanup

exit 0
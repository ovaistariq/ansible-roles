mysql
========
This is a role to install and configure MySQL. This role does not manage anything else.

Requirements
------------

No external requirements.

Role Variables
--------------

## Mandatory
These variables have to be defined in the playbook, since there are no defaults defined for them
* `mysql_major_version` The major version of the MySQL package that has to be installed, for example "5.6"
* `mysql_full_version` The full version of the MySQL package that has to be installed, for example "5.6.19-1"
* `mysql_socket` The unix domain socket that MySQL will use
* `mysql_root_password` The MySQL root password
* `checksum_user` The MySQL user used by pt-table-checksum. This user must already be setup
* `checksum_password` The MySQL user used by pt-table-checksum. This user must already be setup

## Standard
* `mysql_port` Defaults to 3306
* `mysql_user` Defaults to mysql
* `mysql_max_connections` Defaults to 7000
* `mysql_datadir` Defaults to /data/mysql_data
* `mysql_logdir` Defaults to /data/mysql_logs
* `mysql_tmpdir` Defaults to /data/mysql_data/tmp
* `mysql_error_log` Defaults to {{ mysql_logdir }}/mysql-error.log
* `mysql_slow_log` Defaults to {{ mysql_logdir }}/mysql-slow.log
* `mysql_log_bin` Defaults to {{ mysql_logdir }}/binary_log
* `mysql_expire_logs_days` Defaults to 7
* `mysql_relay_log` Defaults to {{ mysql_logdir }}/relay-bin
* `mysql_relay_log_index` Defaults to {{ mysql_logdir }}/relay-bin.index

Dependencies
------------

No external dependencies

Example Playbook
-------------------------

Including an example of how to use this role with variables passed in as parameters:

    - hosts: servers
      roles:
         - { role: mysql, mysql_major_version: "5.6", 
                          mysql_full_version: "5.6.19-1", 
                          mysql_socket: "/data/mysql_data/mysql.sock", 
                          mysql_root_password: "changeme",
                          checksum_user: "some_username",
                          checksum_password: "some_password" }

Author Information
------------------

Ovais Tariq
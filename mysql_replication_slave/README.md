mysql_replication_slave
=======================
This is a role to setup a new MySQL slave using dump and reload.

Requirements
------------

No external requirements.

Role Variables
--------------

## Mandatory
These variables have to be defined in the playbook, since there are no defaults defined for them
* `backup_source_host` The production host which will be used as the source of the dump
* `mysql_username` The username of the MySQL user that will be used for the dump and reload
* `mysql_password` The password of the MySQL user used for dump and reload 
* `mysql_repl_username` The username of the MySQL user that will be used for replication
* `mysql_repl_password` The password of the MySQL replication user

## Standard
* `output_dir` The directory to store the dump and reload related data, defaults to /data/mysql_data
* `backup_source_is_master` Should the backup_source_host be setup as the master, defaults to 'no'
* `mysql_datadir` Defaults to /data/mysql_data
* `mysql_logdir` Defaults to /data/mysql_logs
* `mysql_tmpdir` Defaults to /data/mysql_data/tmp

Dependencies
------------

* The role depends on the {{ backup_source_host }} being accessible via ssh from the host that will use the role.

Example Playbook
-------------------------

Including an example of how to use this role with variables passed in as parameters:

    - hosts: servers
      roles:
         - { role: mysql_replication_slave, backup_source_host: "hostname", 
                mysql_username: "some_username",
                mysql_password: "some_password",
                mysql_repl_username: "some_username",
                mysql_repl_password: "some_password" }

Author Information
------------------

Ovais Tariq

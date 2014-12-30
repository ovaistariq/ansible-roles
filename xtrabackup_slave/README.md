xtrabackup_slave
================
This is a role to backup using Percona XtraBackup a MySQL server, stream it to a new machine, prepare it and then use it to configure a new slave.

Requirements
------------

No external requirements.

Role Variables
--------------

## Mandatory
These variables have to be defined in the playbook, since there are no defaults defined for them
* `backup_source_host` The hostname of the MySQL server that will be backed up to clone a new slave
* `mysql_master_host` The hostname of the MySQL server that will be the master of the new slave, if the backup was taken from the slave
* `mysql_username` The MySQL user used to configure replication by executing CHANGE MASTER
* `mysql_password` The password of the MySQL user used to configure replication
* `mysql_repl_username` The MySQL user used by the replication threads
* `mysql_repl_password` The password of the MySQL user used by replication threads

## Standard
* `mysql_datadir` Defaults to /var/lib/mysql
* `mysql_logdir` Defaults to /var/log/mysql
* `mysql_tmpdir` Defaults to /tmp

Dependencies
------------

* The role depends on the {{ backup_source_host }} being accessible via ssh from the host that will use the role.
* The role also depends on port 7777 being open between {{ backup_source_host }} and the host which is supposed to receive the backup.

Example Playbook
-------------------------

Including an example of how to use this role with variables passed in as parameters:

    - hosts: servers
      roles:
         - { role: xtrabackup_slave, backup_source_host: "hostname",
                mysql_master_host: "hostname",
                mysql_username: "some_username",
                mysql_password: "changeme",
                mysql_repl_username: "some_username",
                mysql_repl_password: "some_password" }

Author Information
------------------

Ovais Tariq

xtrabackup_replication
======================
This is a role to configure replication on a MySQL server that has been prepared using Percona XtraBackup. 
This role depends on `xtrabackup_slave` role to prepare the MySQL server.

Requirements
------------

No external requirements.

Role Variables
--------------

## Mandatory
These variables have to be defined in the playbook, since there are no defaults defined for them
* `backup_source_host` The hostname of the MySQL server that was backed up to clone the new slave
* `mysql_master_host` The hostname of the MySQL server that will be the master of the new slave, if the backup was taken from the slave
* `mysql_replication_user` The MySQL user used by the replication threads
* `mysql_replication_password` The password of the MySQL user used by replication threads

## Standard
* `mysql_datadir` Defaults to /data/mysql_data

Dependencies
------------

This role depends on the `xtrabackup_slave` role which must be applied before this role can be applied.

Example Playbook
-------------------------

Including an example of how to use this role with variables passed in as parameters:

    - hosts: servers
      roles:
         - { role: xtrabackup_replication, backup_source_host: "hostname",
                mysql_master_host: "hostname",
                mysql_replication_user: "some_username",
                mysql_replication_password: "some_password" }

Author Information
------------------

Ovais Tariq
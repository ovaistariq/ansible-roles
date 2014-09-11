mysql
========
This is a role to backup using Percona XtraBackup a MySQL server, stream it to a new machine and prepare it so that it is ready to be used to setup a new slave. This role does not setup replication. 
Rather, it must be used together with `xtrabackup_replication` role to complete the replication setup of the slave.

Requirements
------------

No external requirements.

Role Variables
--------------

## Mandatory
These variables have to be defined in the playbook, since there are no defaults defined for them
* `mysql_root_password` The MySQL root password
* `mysql_master_host` The hostname of the MySQL server that will be backed up to clone a new slave

## Standard
* `mysql_datadir` Defaults to /data/mysql_data
* `mysql_logdir` Defaults to /data/mysql_logs
* `mysql_tmpdir` Defaults to /data/mysql_data/tmp

Dependencies
------------

* The role depends on the {{ mysql_master_host }} being accessible via ssh from the host that will use the role.
* The role also depends on port 7777 being open between {{ mysql_master_host }} and the host which is supposed to receive the backup.

Example Playbook
-------------------------

Including an example of how to use this role with variables passed in as parameters:

    - hosts: servers
      roles:
         - { role: xtrabackup_slave, mysql_root_password: "changeme", mysql_master_host: "hostname" }

Author Information
------------------

Ovais Tariq
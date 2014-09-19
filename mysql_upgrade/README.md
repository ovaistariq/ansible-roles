mysql_upgrade
=============
This is a role to upgrade a MySQL instance.

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

## Standard
* `mysql_logdir` Defaults to /data/mysql_logs

Dependencies
------------

No external dependencies

Example Playbook
-------------------------

Including an example of how to use this role with variables passed in as parameters:

    - hosts: servers
      roles:
         - { role: mysql_upgrade, mysql_major_version: "5.6", 
                mysql_full_version: "5.6.19-1", 
                mysql_socket: "/data/mysql_data/mysql.sock", 
                mysql_root_password: "changeme" }

Author Information
------------------

Ovais Tariq
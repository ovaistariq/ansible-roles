percona_toolkit
===============
This is a role to install Percona toolkit and setup the configuration files for the various Percona toolkit tools so that they can be used without specifying password on the command line.

Requirements
------------

No external requirements.

Role Variables
--------------

## Mandatory
These variables have to be defined in the playbook, since there are no defaults defined for them
* `pt_read_only_user` The username of MySQL user with read-only privileges: SELECT, PROCESS, SUPER, REPLICATION SLAVE, REPLICATION CLIENT ON *.* and ALL PRIVILEGES ON percona.*
* `pt_read_only_password` The password of the MySQL user with read-only privileges
* `pt_read_write_user` The username of MySQL user with read-write privileges: ALL PRIVILEGES ON *.*
* `pt_read_write_password` The password of the MySQL user with read-write privileges

Dependencies
------------

No dependencies

Example Playbook
-------------------------

Including an example of how to use this role with variables passed in as parameters:

    - hosts: servers
      roles:
         - { role: percona_toolkit, pt_read_only_user: "read_only_user", 
                pt_read_only_password: "changeme", 
                pt_read_write_user: "read_write_user",
                pt_read_write_password: "changeme" }

Author Information
------------------

Ovais Tariq

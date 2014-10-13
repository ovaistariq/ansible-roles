mysql_tests
===============
This is a role to test a MySQL server using production workload. The production workload is captured on the master and replayed on a production slave as a baseline. 
The baseline is then compared to how replaying the same workload works on the target server that is being benchmarked. 
Together with that pt-upgrade is used to run the queries on the target server and on a production slave and then result-sets are compared for any differences.

Requirements
------------

No external requirements.

Role Variables
--------------

## Mandatory
These variables have to be defined in the playbook, since there are no defaults defined for them
* `mysql_master_host` The production master from which workload will be captured using tcpdump
* `mysql_compare_host` The production slave where workload will be replayed to set a baseline
* `mysql_ro_username` The MySQL user with read-only privileges that will be used by the test scripts 
* `mysql_ro_password` The password of the MySQL user with read-only privileges

## Standard
* `benchmark_seconds` The number of seconds to capture the production workload for, defaults to 1800
* `target_tmpdir` The directory on the target server to store temporary files needed by benchmark, defaults to /tmp/mysql_tests
* `output_dir` The directory to store the benchmark results to, defaults to /var/lib/mysql_tests/sjc1ppod09
* `run_workload_replay_test` Should the "workload replay" test be run, defaults to 'yes'
* `run_pt_upgrade_test` Should the "pt-upgrade" test be run, defaults to 'yes'

Dependencies
------------

* The role depends on the {{ mysql_master_host }}, {{ mysql_compare_host }} being accessible via ssh from the host that will use the role.
* The role also depends on port 7778 being open between {{ mysql_master_host }} and the host which is supposed to be benchmarked.
* The role depends on the percona_toolkit role.

Example Playbook
-------------------------

Including an example of how to use this role with variables passed in as parameters:

    - hosts: servers
      roles:
         - { role: mysql_tests, mysql_master_host: "hostname", 
                mysql_compare_host: "hostname", 
                mysql_ro_username: "some_username",
                mysql_ro_password: "some_password" }

Author Information
------------------

Ovais Tariq

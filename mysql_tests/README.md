mysql_benchmark
===============
This is a role to benchmark a MySQL server using production workload. The production workload is captured on the master and replayed on a production slave as a baseline. 
The baseline is then compared to how replaying the same workload works on the target server that is being benchmarked.

Requirements
------------

No external requirements.

Role Variables
--------------

## Mandatory
These variables have to be defined in the playbook, since there are no defaults defined for them
* `mysql_master_host` The production master from which workload will be captured using tcpdump
* `mysql_slave_host` The production slave where workload will be replayed to set a baseline
* `mysql_user` The MySQL user that would be used to replay the production read-only workload, make sure the MySQL user can connect from target host to MySQL running on itself and on the master and the slave hosts
* `mysql_password` The password for the MySQL user

## Standard
* `benchmark_seconds` The number of seconds to capture the production workload for, defaults to 1800
* `target_tmpdir` The directory on the target server to store temporary files needed by benchmark, defaults to /tmp
* `output_dir` The directory to store the benchmark results to, defaults to /tmp

Dependencies
------------

* The role depends on the {{ mysql_master_host }}, {{ mysql_slave_host }} being accessible via ssh from the host that will use the role.
* The role also depends on port 7778 being open between {{ mysql_master_host }} and the host which is supposed to be benchmarked.

Example Playbook
-------------------------

Including an example of how to use this role with variables passed in as parameters:

    - hosts: servers
      roles:
         - { role: mysql_benchmark, mysql_master_host: "hostname", mysql_slave_host: "hostname", mysql_user: "changeme", mysql_password: "changeme" }

Author Information
------------------

Ovais Tariq

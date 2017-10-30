# Universe Security Scanner

This is a sample service that demonstrates how easy it is to scan the docker containers hosted by the DC/OS universe.

Capabilities:

* Install Clair [https://github.com/coreos/clair] on DC/OS with dependencies and make available from outside of cluster
* Read container list from DC/OS universe
* Use klar [https://github.com/optiopay/klar] to drive Clair from your local machine and build security reports

## Install Prerequisites on Your Machine

To run the demo setup script (`stage_container_scanner.sh`), the following pieces of software are expected to be available:

* A DC/OS cluster with one public node and two private nodes
* DC/OS CLI
* DC/OS Enterprise CLI

To run the security scanner, you will also need:

* A local Docker agent (either via docker-machine or otherwise) 

Run `bash stage_container_scanner.sh [master_ip]`

The above command will do the following:

* Configure the local CLI
* Install Marathon-LB, Postgresql, and Clair
* Generate a klar-config-file
* Output the commands to run to connect to Clair using Klar

## Run the scanner

You can either run the example command output by the demo setup script against a specific container, or you can leverage the scan_universe.sh script to scan all containers in the universe.

'scan_universe.sh' will do the following:
* Create a scan-results sub-directory for your security scan reports
* Create a 'universe_containers.txt' file with a list of all containers currently referenced in the DC/OS universe(s) registered to the configured cluster
* Scan each container listed in universe_containers.txt and output a '[containername].vuln' file with the known vulnerabilities

Please be aware that on a new Clair instance, it can take up to 15 minutes for Clair to cache the current NIST NVD - containers will return 0 vulnerabilities until the local database cache is built.

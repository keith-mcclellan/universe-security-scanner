#!/bin/bash
# Usage: DCOS_URL=http://<IP-address> bash stage_container_scanner.sh
# Alt Usage: bash stage_ebc_demo.sh [masterip] [publicELB]

# Requirements:
#   - Enterprise DC/OS cluster with 1 public slave and 2 private slaves with
#       or without superuser set
#   - DCOS CLI installed on localhost
#   - DCOS_URL set to DCOS master URL
#
set -o errexit

# Reset CLI
if [ -z ${DCOS_URL+x} ]; then
#strip http(s) from Master IP url
mip_clean=${1#*//}
#strip trailing slash from Master IP url
DCOS_URL=http://${mip_clean%/}
fi

# Required input checks
if [[ -z $DCOS_URL ]]; then
    echo "DCOS_URL is not set! Provide with --url or DCOS_URL env-var"
    exit 1
fi

echo $DCOS_URL

#Run CI Script in infrastructure mode
for i in `dcos cluster list | awk ' FNR > 1 { print $1 }' | sed 's/\*//'`; do dcos cluster remove $i; done

DCOS_AUTH_TOKEN=${DCOS_AUTH_TOKEN:=$ci_auth_token}
DCOS_USER=${DCOS_USER:='bootstrapuser'}
DCOS_PW=${DCOS_PW:='deleteme'}



cmd_eval() {
        log_msg "Executing: $1"
        eval $1
}

user_continue() {
if $STEP_MODE; then
    read -p 'Continue? (y/n) ' resp
    case $resp in
        y) return ;;
        n) exit 0 ;;
        *) user_continue ;;
    esac
fi
return
}

is_running() {
    status=`dcos marathon app list | grep $1 | awk '{print $6}'`
    if [[ $status = '---' ]]; then
        framework_status=$((`dcos $1 plan status deploy | grep '^deploy' | grep COMPLETE | awk '{print $2}'`) 2>&1)
        if [[ $framework_status = *"COMPLETE"* || $framework_status = *"not a dcos command"* ]]; then
                return 0
        else
                return 1
        fi
    else
        return 1
    fi
}

log_msg() {
    echo `date -u +'%D %T'`: $1
}

wait_for_deployment() {
    for service in $*; do
        until is_running $service; do
            log_msg "Wait for $service to finish deploying..."
            sleep 3
        done
    done
}

ee_login() {
cat <<EOF | expect -
spawn dcos cluster setup "$DCOS_URL" --no-check
expect "username:"
send "$DCOS_USER\n"
expect "password:"
send "$DCOS_PW\n"
expect eof
EOF
}

# Check DC/OS CLI is actually installed
dcos --help &> /dev/null || ( echo 'DC/OS must be installed!' && exit 1 )

# Setup access to the desired DCOS cluster and install marathon lb
log_msg "Setting DCOS CLI to use $DCOS_URL"
    log_msg "Starting DC/OS Enterprise Demo"
    log_msg "Override default credentials with --user and --pw"
    cmd_eval ee_login
    # Get the dcos EE CLI
    cmd_eval 'dcos package install --cli --yes dcos-enterprise-cli'
    cmd_eval 'dcos security org service-accounts keypair -l 4096 k.priv k.pub'
    cmd_eval 'dcos security org service-accounts create -p k.pub -d "Marathon LB" dcos_marathon_lb'
    cmd_eval 'dcos security secrets create-sa-secret k.priv dcos_marathon_lb marathon-lb'
    log_msg "Get auth headers to do calls outside of DC/OS CLI (ACLs)"
    auth_t=`dcos config show core.dcos_acs_token`
    log_msg "Received auth token: $auth_t"
    auth_h="Authorization: token=$auth_t"

    # Make our ACLs
    cmd_eval "curl -skSL -X PUT -H 'Content-Type: application/json' -d '{\"description\":\"Marathon admin events\"}' -H \"$auth_h\" $DCOS_URL/acs/api/v1/acls/dcos:service:marathon:marathon:admin:events"
    cmd_eval "curl -skSL -X PUT -H 'Content-Type: application/json' -d '{\"description\":\"Marathon all services\"}' -H \"$auth_h\" $DCOS_URL/acs/api/v1/acls/dcos:service:marathon:marathon:services:%252F"
    # Add our dcos_marathon_lb service account to the ACLs
    cmd_eval "curl -skSL -X PUT -H \"$auth_h\" $DCOS_URL/acs/api/v1/acls/dcos:service:marathon:marathon:admin:events/users/dcos_marathon_lb/read"
    cmd_eval "curl -skSL -X PUT -H \"$auth_h\" $DCOS_URL/acs/api/v1/acls/dcos:service:marathon:marathon:services:%252F/users/dcos_marathon_lb/read"

    cat <<EOF > options.json
{
  "marathon-lb": {
    "secret_name": "marathon-lb"
  }
}
EOF

#create clair config secret
cmd_eval 'dcos security secrets create -f config.yaml clair/clair_config'

#set packages to install
install_packages=(marathon-lb postgresql)

for pkg in ${install_packages[*]}; do
    cmd="dcos --log-level=ERROR package install --yes"
    if [[ $pkg = 'marathon-lb' ]] && ! $DCOS_OSS; then
        cmd="$cmd --options=options.json"
    fi
    cmd="$cmd $pkg"
    cmd_eval "$cmd"
done

# query until services are listed as running
wait_for_deployment ${install_packages[*]}

# install Clair
cmd_eval "dcos marathon app add clair.json"
wait_for_deployment clair

cmd_eval "dcos marathon app add public-ip.json"
wait_for_deployment public-ip
public_ip_str=`dcos task log --lines=1 public-ip`
public_ip="${public_ip_str##* }"
cmd_eval "dcos marathon app remove public-ip"

CLAIR_ADDR=http://$public_ip:10000

if [ -z "$threshold" ]
then
        threshold=0
fi

if [ -z "$docker_user" ]
then
        echo -n "Enter docker repo username and press [ENTER]: "
        read docker_user
fi

if [ -z "$docker_password" ]
then
        echo -n "Enter docker repo password and press [ENTER]: "
        read -s docker_password
fi

if [ -z "$output" ]
then
	PS3='Please select a severity threshold: '
	options=("Unknown" "Negligible" "Low" "Medium" "High" "Critical" "Defcon1")
	select opt in "${options[@]}"
   do
	case $opt in
		"Unknown")
			output=Unknown
			break
			;;
                "Negligible")
        	        output=Negligible
        	        break
			;;
                "Low")
               		output=Low
                	break
			;;
                "Medium")
                	output=Medium
                	break
			;;
                "High")
                	output=High
                	break
			;;
                "Critical")
                	output=Critical
                	break
			;;
                "Defcon1")
                	output=Defcon1
			break
                	;;
		*) echo invalid option;;
	esac
   done
fi

cat <<EOF > klar-env-file
CLAIR_ADDR=$CLAIR_ADDR
CLAIR_THRESHOLD=$threshold
CLAIR_OUTPUT=$output
DOCKER_USER=$docker_user
DOCKER_PASSWORD=$docker_password
EOF

log_msg "To scan a container, you can run the command: docker run --env-file=klar-env-file keithmcclellan/klar [container_name]"

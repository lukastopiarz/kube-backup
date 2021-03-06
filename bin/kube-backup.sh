#!/bin/bash
#
# kube-backup.sh
# Various strategies to back-up the contents of containers running on a Kubernetes cluster.
# Uses kubectl against the Kubernetes API. Can be use internal or external to a cluster.
# Aaron Roydhouse <aaron@roydhouse.com>, 2017
#
# Sample usage:
#   ./kube-backup.sh --task=backup-mysql-exec --selector=app=my-db,env=dev,component=mysql --container=mysql
#   ./kube-backup.sh --task=backup-files-exec --pod=my-website --container=website --files-path=/var/www
#
# Exit values:
# - Success: 0
# - Task failed: 1
# - Error occurred: 2
# - Missing dependancy: 3
#

VERSION=0.1.5

# Pipes have non-zero exit code if any step fail (rather than only the last)
set -o pipefail

#
# Utility functions
#

display_usage ()
{
  local script_name="$(basename $0)"
  cat <<END
Usage:
  ${script_name} --task=<task name> [options...]
  ${script_name} --task=backup-etcd [--retention=<number of backups to keep>] [options...]
  ${script_name} --task=backup-mysql-exec [--database=<db name>] [options...]
  ${script_name} --task=backup-files-exec [--files-path=<files path>] [options...]
  Options:
    [--pod=<pod-name>|--selector=<selector>] [--container=<container-name>] [--secret=<secret name>]
    [--s3-bucket=<bucket name>] [--s3-prefix=<prefix>] [--aws-secret=<secret name>]
    [--use-kubeconfig-from-secret|--kubeconfig-secret=<secret name>]
    [--slack-secret=<secret name>] [--slack-pretext=<text>]
    [--timestamp=<timestamp>] [--backup-name=<backup name>]
    [--os-auth-url=<openstack keystone url>] [--os-api-version=<openstack api version>]
    [--os-project-name=<openstack project name>]
    [--os-username=<openstack username>] [--os-password=<openstack user password>]
    [--backup-backend=<swift or s3>]
    [--dry-run]
  ${script_name} --help
  ${script_name} --version

Notes:
  --secret defaults to 'kube-backup' and is the default secret for kubeconfig, aws, and slack
  --timestamp allows two backups to share the same timestamp
  --s3-bucket if not specified, will be taken from the AWS secret
  --s3-prefix is inserted at the beginning of the S3 prefix
  --backup-name will replace e.g. the database name or file path
  --dry-run will do everything except the actual backup
  --slack-pretext may include links using the Slack '<url|text>' syntax
  --backup-backend choose either OpenStack Swift or Amazon S3 object storage

END
}

display_version ()
{
  local script_name="$(basename $0)"
  echo "${script_name} version ${VERSION}"
}

# Check for essential tools
check_tools ()
{
  for prog in "$@" envsubst; do
    if [ -z "$(which $prog)" ]; then
      echo "Missing dependency '${prog}'"
      exit 3
    fi
  done
}

array_contains () {
  local a
  for a in "${@:2}"; do [[ "$a" == "$1" ]] && return 0; done
  return 1
}

#======================================================================
# Find containers
#

# Check a container exists
# Pass the names of the global pod and container variables
# Will update the container variable is empty
check_container ()
{
  local pod_var=$1 container_var=$2
  eval "local pod=\$${pod_var}"
  eval "local container=\$${container_var}"

  if [[ -z "${pod}" ]]; then
    echo "Must specify a pod name"
    display_usage
    return 3
  else
    if [[ ! "$($KUBECTL get pod $pod $NS_ARG -o name)" ]]; then
      echo "Pod '$pod' not found"
      return 3
    fi  
  fi

  local containers=($($KUBECTL get pod $pod $NS_ARG -o jsonpath='{.spec.containers[*].name}' 2> /dev/null))
  if [[ "$?" -eq 0 ]]; then
    if [[ "${#containers[@]}" -gt 0 ]]; then
      echo "Pod '$pod' has ${#containers[@]} containers: ${containers[@]}"
      if [[ -z "$container" ]]; then
        echo "No container specified, using the first container in pod '${pod}': ${containers[0]}"
        container="${containers[0]}"
        eval "${container_var}=$container"
      else
        array_contains $container "${containers[@]}"
        if [[ "$?" -ne 0 ]]; then
          echo "Container '${container}' not found in pod '${pod}'"
          return 3
        else
          echo "Specified container '${container}' found in pod '${pod}'"
        fi
      fi
      # Check the identified pod is ready
      if [[ "true" != $($KUBECTL get pod $pod $NS_ARG -o jsonpath="{.status.containerStatuses[?(@.name == \"${container}\")].ready}") ]]; then
        echo "Container '${container}' in pod '${pod}' is not ready"
        return 3
      fi
    else
      echo "Pod '${pod}' has no containers"
      return 3
    fi
  else
    echo "Pod '${pod}' not found"
    return 3
  fi
}

# Find all pods matching a selector
# Returns pod names in pods_var
find_pods_with_selector ()
{
  local selector=$1 namespace=$2 pods_var=$3

  if [[ -n "${namespace}" ]]; then
    local ns_arg="--namespace=${namespace}"
  else
    local ns_arg=""
  fi

  local pods=($(kubectl get pod --selector=${selector} $ns_arg -o jsonpath='{.items[*].metadata.name}'))
  if [[ "$?" -eq 0 ]]; then
    if [[ "${#pods[@]}" -gt 0 ]]; then
      echo "Selector '$selector' matched ${#pods[@]} pods: ${pods[@]}"
    else
      echo "The selector '$selector' matched no pods"
    fi
  else
    echo "Error finding pods with selector '$selector'"
    return 1
  fi

  eval "${pods_var}=\"${pods[@]}\""
}

#======================================================================
# Kubernetes secrets
#

get_kubeconfig_secret ()
{
  local secret_name=$1

  if [[ -z "${secret_name}" ]]; then
    echo "No kubeconfig secret name specified"
    exit 3
  fi

  if [[ -r "${HOME}/.kube/config" ]]; then
    echo "kubeconfig file already exists at '${HOME}/.kube/config', not overwriting"
    exit 2
  fi

  local secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.kubeconfig}')
  if [[ "$?" -eq 0 ]]; then
    mkdir -p "${HOME}/.kube"
    touch "${HOME}/.kube/config"; chmod 0600 "${HOME}/.kube/config"
    echo "$secret" | $BASE64 -d > "${HOME}/.kube/config"
    echo "Fetched kubeconfig files from '$secret_name' secret"
  else
    echo "Failed to load kubeconfig from '$secret_name' secret"
    exit 2 
  fi
}

#======================================================================
# AWS Secrets
#

# Get AWS key and secret from a Kubernetes secret 
# Only in the current namespace
get_aws_secret ()
{
  local secret_name=$1

  if [[ -z "${secret_name}" ]]; then
    echo "No AWS secret name specified"
    exit 3
  fi

  local secrets=($($KUBECTL get secret ${secret_name} -o jsonpath='{.data.AWS_ACCESS_KEY_ID} {.data.AWS_SECRET_ACCESS_KEY}'))
  if [[ "$?" -eq 0 ]]; then
    export AWS_ACCESS_KEY_ID=$(echo "${secrets[0]}" | $BASE64 -d)
    export AWS_SECRET_ACCESS_KEY=$(echo "${secrets[1]}" | $BASE64 -d)
    echo "Fetched AWS credientials from '$secret_name' secret"
  else
    echo "Failed to load AWS credentials from '$secret_name' secret"
    exit 2 
  fi
}

check_for_aws_secret ()
{
  local secret_name=$1

  if [[ -z "${AWS_ACCESS_KEY_ID}" ]]; then
    get_aws_secret $secret_name || return 1
  fi
}

# Get AWS S3 settings from a Kubernetes secret 
# Only looks only in the current namespace
get_s3_secret ()
{
  local secret_name=$1

  if [[ -z "${secret_name}" ]]; then
    echo "No S3 secret name specified"
    exit 2
  fi

  local secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.S3_BUCKET}')
  if [[ "$?" -eq 0 ]]; then
    export S3_BUCKET=$(echo "$secret" | $BASE64 -d)
    echo "Fetched S3 bucket name from '$secret_name' secret"
    return 0
  else
    echo "Failed to load S3 bucket from '$secret_name' secret"swift
    return 2
  fi
}

check_for_s3_secret ()
{
  local secret_name=$1

  if [[ -z "${S3_BUCKET}" ]]; then
    get_s3_secret $secret_name || return 1
  fi
}

#======================================================================
# OpenStack support
#
set_openstack_environment_variables ()
{
  # Get variables from secret
  # Only in the current namespace
  local secret_name=$1

  echo "Setting up OpenStack environment variables (If not provided as parameters)"
  [[ -n $OS_AUTH_URL ]] || {
    local os_auth_url_secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.OS_AUTH_URL}');
    export OS_AUTH_URL=$(echo "$os_auth_url_secret" | $BASE64 -d);
  }
  [[ -n $OS_PROJECT_NAME ]] || {
    local os_project_name_secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.OS_PROJECT_NAME}');
    export OS_PROJECT_NAME=$(echo "$os_project_name_secret" | $BASE64 -d);
  }
  [[ -n $OS_USERNAME ]] || {
    local os_username_secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.OS_USERNAME}');
    export OS_USERNAME=$(echo "$os_username_secret" | $BASE64 -d);
  }
	[[ -n $OS_PASSWORD ]] || {
    local os_pasword_secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.OS_PASSWORD}');
    export OS_PASSWORD=$(echo "$os_pasword_secret" | $BASE64 -d);
  }
#  [[ -n $OS_REGION_NAME ]] || {
#  	local os_region_name_secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.OS_REGION_NAME}');
#  	export OS_REGION_NAME=$(echo "$os_region_name_secret" | $BASE64 -d);
#  }
#	[[ -n $OS_IDENTITY_API_VERSION ]] || {
#    local os_identity_api_version_secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.OS_IDENTITY_API_VERSION}');
#  	export OS_IDENTITY_API_VERSION=$(echo "$os_identity_api_version_secret" | $BASE64 -d);
#  }
	[[ -n $OS_API_VERSION ]] || {
    local os_api_version_secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.OS_API_VERSION}');
    export OS_API_VERSION=$(echo "$os_api_version_secret" | $BASE64 -d);
  }
}

#======================================================================
# Slack support
#

# Get Slack webhook URL from a Kubernetes secret 
# Only looks only in the current namespace
get_slack_secret ()
{
  local secret_name=$1

  if [[ -z "${secret_name}" ]]; then
    echo "No Slack secret name specified"
    exit 3
  fi

  local secret=$($KUBECTL get secret ${secret_name} -o jsonpath='{.data.SLACK_WEBHOOK}')
  if [[ "$?" -eq 0 ]]; then
    export SLACK_WEBHOOK=$(echo "$secret" | $BASE64 -d)
    echo "Fetched Slack webhook from '$secret_name' secret"
    return 0
  else
    echo "Failed to load Slack webhook from '$secret_name' secret"
    return 2
  fi
}

check_for_slack_secret ()
{
  local secret_name=$1

  if [[ -z "${SLACK_WEBHOOK}" ]]; then
    get_slack_secret $secret_name || return 1
  fi
}

send_slack_message ()
{
  local message=$1 color=$2

  if [[ -z "${SLACK_WEBHOOK}" || -z "${message}" ]]; then 
    return 
  fi
  : ${color:='good'}

  local body
  read -r -d '' body <<SLACKEND
{
  "username": "Kube Backup",
  "icon_url": "https://kubernetes.io/images/wheel.png",
  "attachments": [
    {
      "pretext": "${SLACK_PRETEXT}",
      "fallback": "${message}",
      "color": "${color}",
      "text": "${message}"
    }
  ]
}
SLACKEND

  local response=$(echo "${body}" | curl -Ss -X POST -H 'Content-type: application/json' --data @- $SLACK_WEBHOOK)

  if [[ "$?" -ne 0 ]]; then
    echo "Error sending message to Slack: '$response'"
  fi
}

send_slack_message_and_echo ()
{
  send_slack_message "$@"
  echo $1
}


#======================================================================
# Filenames
#

create_filename ()
{
  local pod=$1 container=$2 backup_name=$3 timestamp=$4 ext=$5

  # Have a go at removing the suffix that a Deployment and ReplicaSet adds
  local clean_pod="$(echo ${pod} | sed -e 's/-[0-9]\+-[a-z0-9]\+$//')"

  # Join all non-empty parts
  local filename="${clean_pod}"
  for part in "${container}" "${backup_name}" "${timestamp}"; do
    local clean_part="$(echo ${part} | sed -e 's/[^A-Za-z0-9_-]/_/g' -e 's/__+/_/g' -e 's/^[-_]\+//' -e 's/[-_]$\+//')"
    if [[ -n "${clean_part}" ]]; then
      # If the previous part ends with this part, skip adding (e.g. if pod='foo-website' and container='website')
      if [[ ! "$filename" =~ -${clean_part}$ ]]; then
        filename="${filename}-${clean_part}"
      fi
    fi
  done

  local filename="${filename}${ext}"
  echo "${filename}"
}

#======================================================================
# Backup tasks
#

# This strategy relies on kubectl exec into the offical or derivative MySQL container
# Requires environment variables in container: MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE
# Requires tools in container: bash mysqldump gzip
#
backup_mysql_exec ()
{
  check_container 'POD' 'CONTAINER'
  if [[ "$?" -ne 0 ]]; then
    echo "Aborting backup, no container selected"
    exit 3
  fi

  check_for_s3_secret $AWS_SECRET
  if [[ -n "$S3_BUCKET" ]]; then
    check_for_aws_secret $AWS_SECRET
  fi

  #
  # Work out the database name
  #

  local cmd="${KUBECTL} exec -i ${POD} --container=${CONTAINER} ${NS_ARG} --"

  if [[ -z "${DATABASE}" ]]; then
    echo "No database specified, getting database name from environment of container '$CONTAINER'"
    DATABASE=$($cmd bash -c "echo \"\${MYSQL_DATABASE}\"")
  fi 

  if [[ -z "${DATABASE}" ]]; then
    echo "No database name specified or found"
    exit 3
  fi

  #
  # Work out the target path
  #

  local backup_path="${NAMESPACE-default}/${TIMESTAMP}"
  local backup_filename=$(create_filename "${POD}" "${CONTAINER}" "${BACKUP_NAME:-$DATABASE}" "${TIMESTAMP}" ".gz")
  if [[ -n "${S3_BUCKET}" ]]; then
    [[ "$S3_PREFIX" =~ ^/*(.*[^/])/*$ ]] && local prefix=${BASH_REMATCH[1]}; prefix=${prefix}${prefix+/}
    local target="s3://${S3_BUCKET}/${prefix}${backup_path}/${backup_filename}"
    local use_s3="true"
  else
    local target="${backup_path}/${backup_filename}"
    local use_s3="false"
  fi

  #
  # Create and execute 'kubectl exec' backup command
  #

  local backup_cmd="MYSQL_PWD=\"\${MYSQL_PASSWORD}\" mysqldump '${DATABASE}' --user=\"\${MYSQL_USER}\" --single-transaction | gzip"
  echo "Backing up MySQL database '${DATABASE}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
  if [[ "${DRY_RUN}" != "true" ]]; then
    if [[ "$use_s3" == "true" ]]; then
      # relies on 'set -o pipefail' to detect kubectl errors
      $cmd bash -c "${backup_cmd}" | ${AWSCLI} s3 cp - "${target}"
    else
      mkdir -p "${backup_path}"
      $cmd bash -c "${backup_cmd}" > "${target}"
    fi
    if [[ "$?" -eq 0 ]];then
      send_slack_message_and_echo "Backed up MySQL database '${DATABASE}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
    else
      send_slack_message_and_echo "Error: Failed to back up MySQL database '${DATABASE}' from container '${CONTAINER}' in pod '${POD}' to '${target}'" danger
    fi
  else
    echo "Skipping backup, dry run delected"
  fi
}

#======================================================================
# Backup or restore files using 'kubectl exec' proxy of tar output to S3
# - backup_files_exec
# - restore_files_exec
#

# This strategy relies on kubectl exec into the container
# Requires tools in container: tar gzip
#
backup_files_exec ()
{
  echo "Running backup_files_exec"
  check_container 'POD' 'CONTAINER'
  if [[ "$?" -ne 0 ]]; then
    echo "Aborting backup, no container selected"
    exit 1
  fi

  check_for_s3_secret $AWS_SECRET
  if [[ -n "$S3_BUCKET" ]]; then
    check_for_aws_secret $AWS_SECRET
  fi

  if [[ -z "${FILES_PATH}" ]]; then
    echo "No backup path specified"
    exit 3
  fi

  #
  # Work out the target path
  #

  local backup_path="${NAMESPACE-default}/${TIMESTAMP}"
  local backup_filename=$(create_filename "${POD}" "${CONTAINER}" "${BACKUP_NAME:-$FILES_PATH}" "${TIMESTAMP}" ".tar.gz")
  if [[ -n "${S3_BUCKET}" ]]; then
    [[ "$S3_PREFIX" =~ ^/*(.*[^/])/*$ ]] && local prefix=${BASH_REMATCH[1]}; prefix=${prefix}${prefix+/}
    local target="s3://${S3_BUCKET}/${prefix}${backup_path}/${backup_filename}"
    local use_s3="true"
  else
    local target="${backup_path}/${backup_filename}"
    local use_s3="false"
  fi

  #
  # Create and execute 'kubectl exec' backup command
  #

  local cmd="${KUBECTL} exec -i ${POD} --container=${CONTAINER} ${NS_ARG} --"
  local backup_cmd="tar czf - '${FILES_PATH}'"
  echo "Backing up files in '${FILES_PATH}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
  if [[ "${DRY_RUN}" != "true" ]]; then
    if [[ "$use_s3" == "true" ]]; then
      # relies on 'set -o pipefail' to detect kubectl errors
      $cmd bash -c "${backup_cmd}" | ${AWSCLI} s3 cp - "${target}"
    else
      mkdir -p "${backup_path}"
      $cmd bash -c "${backup_cmd}" > "${target}"
    fi
    if [[ "$?" -eq 0 ]];then
      send_slack_message_and_echo "Backed up files in '${FILES_PATH}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
    else
      send_slack_message_and_echo "Error: Failed to back up files in '${FILES_PATH}' from container '${CONTAINER}' in pod '${POD}' to '${target}'" danger
    fi
  else
    echo "Skipping backup, dry run delected"
  fi
}


#===========================================================================
# Backup or restore files using 'kubectl exec' proxy of tar output to Swift
# - backup_files_exec_swift
#

# This strategy relies on kubectl exec into the container
# Requires tools in container: tar gzip
#
backup_files_exec_swift ()
{
  echo "Running backup_files_exec_swift"
  check_container 'POD' 'CONTAINER'
  if [[ "$?" -ne 0 ]]; then
    echo "Aborting backup, no container selected"
    exit 1
  fi

  if [[ -z "${FILES_PATH}" ]]; then
    echo "No backup path specified"
    exit 3
  fi

  #
  # Work out the target path
  #

  local backup_path="${NAMESPACE-default}/${TIMESTAMP}"
  local backup_filename=$(create_filename "${POD}" "${CONTAINER}" "${BACKUP_NAME:-$FILES_PATH}" "${TIMESTAMP}" ".tar.gz")
  local target="backup_container"

  #
  # Create and execute 'kubectl exec' backup command
  #

  local cmd="${KUBECTL} exec -i ${POD} --container=${CONTAINER} ${NS_ARG} --"
  local backup_cmd="tar czf - '${FILES_PATH}'"
  echo "Backing up files in '${FILES_PATH}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
  if [[ "${DRY_RUN}" != "true" ]]; then
    $cmd bash -c "${backup_cmd}" | ${SWIFTCLI} --os-auth-url=${OS_AUTH_URL} --auth-version=${OS_API_VERSION} --os-project-name=${OS_PROJECT_NAME} --os-username=${OS_USERNAME} --os-password=${OS_PASSWORD} upload --object-name="${backup_filename}" "${target}" -
    if [[ "$?" -eq 0 ]];then
      send_slack_message_and_echo "Backed up files in '${FILES_PATH}' from container '${CONTAINER}' in pod '${POD}' to '${target}'"
    else
      send_slack_message_and_echo "Error: Failed to back up files in '${FILES_PATH}' from container '${CONTAINER}' in pod '${POD}' to '${target}'" danger
    fi
  else
    echo "Would exec:"
    echo "${cmd} bash -c \"${backup_cmd}\" | ${SWIFTCLI} --os-auth-url=${OS_AUTH_URL} --auth-version=3 --os-project-name=${OS_PROJECT_NAME} --os-username=${OS_USERNAME} --os-password=HIDDEN_PASSWORD upload --object-name=\"${backup_filename}\" \"${target}\" -"
    echo "...but skipping backup, dry run selected"
  fi
}

#===========================================================================================
# Backup etcd db snapshot using 'kubectl exec' proxy of etcd tarred snapshot output to Swift
# - backup_etcd_exec_swift
#

# This strategy relies on kubectl exec into the container
# Requires tools in container: etcdctl tar gzip
#
backup_etcd_exec_swift ()
{
  echo "Running backup_etcd_exec_swift"
  check_container 'POD' 'CONTAINER'
  if [[ "$?" -ne 0 ]]; then
    echo "Aborting backup, no container selected"
    exit 1
  fi

  #
  # Work out the target path
  #

  local snapshot_dir="/var/lib/etcd/.backup"
  local backup_path="${NAMESPACE-default}/${TIMESTAMP}"
  local base_backup_filename=$(create_filename "${POD}" "${CONTAINER}" "${BACKUP_NAME:-etcddb}")
  local backup_filename=$(create_filename "${base_backup_filename}" "${TIMESTAMP}" ".tar.gz")
  local target="backup_container"

  #
  # Create ETCD POD URL
  #

  local ETCD_POD_IP=$($KUBECTL get pod ${POD} $NS_ARG -o jsonpath={.status.podIP})
  local ETCD_PORT=2379
  local ETCD_ENDPOINT_URL="https://${ETCD_POD_IP}:${ETCD_PORT}"

  #
  # Create and execute 'kubectl exec' backup command
  #

  local cmd="${KUBECTL} exec -i ${POD} --container=${CONTAINER} ${NS_ARG} --"
  local check_health="export ETCDCTL_API=3; etcdctl --cert=/etc/etcd/peer.crt --key=/etc/etcd/peer.key --cacert=/etc/etcd/ca.crt --endpoints=\"${ETCD_ENDPOINT_URL}\" endpoint health"
  local snapshot_cmd="export ETCDCTL_API=3; etcdctl --cert=/etc/etcd/peer.crt --key=/etc/etcd/peer.key --cacert=/etc/etcd/ca.crt --endpoints=\"${ETCD_ENDPOINT_URL}\" --write-out=table snapshot save ${snapshot_dir}/snapshotdb"
  echo "Backing up etcd from container '${CONTAINER}' in pod '${POD}' to '${target}'"
  if [[ $(${cmd} etcdctl) ]]; then
    if [[ $(${cmd} bash -c "${check_health}") ]]; then
      if [[ "${DRY_RUN}" != "true" ]]; then
        $cmd bash -c "test -d ${snapshot_dir} || mkdir ${snapshot_dir}"
        $cmd bash -c "${snapshot_cmd} && tar czf - ${snapshot_dir}/snapshotdb" | ${SWIFTCLI} --os-auth-url=${OS_AUTH_URL} --auth-version=${OS_API_VERSION} --os-project-name=${OS_PROJECT_NAME} --os-username=${OS_USERNAME} --os-password=${OS_PASSWORD} upload --object-name="${backup_filename}" "${target}" -
        if [[ "$?" -eq 0 ]]; then
          send_slack_message_and_echo "Backed up ETCD db from container '${CONTAINER}' in pod '${POD}' to '${target}'"
          $cmd bash -c "rm -f ${snapshot_dir}/snapshotdb"
        else
          send_slack_message_and_echo "Error: Failed to back up ETCD db from container '${CONTAINER}' in pod '${POD}' to '${target}'" danger
        fi
        if [[ -n "{$RETENTION}" ]]; then
          [ "${RETENTION}" -eq "${RETENTION}" ]  2> /dev/null || { echo "retention not a number!"; exit 2; }
          if [ ${RETENTION} -gt 0 ]; then
            backup_list=$(${SWIFTCLI} \
              --os-auth-url=${OS_AUTH_URL} \
              --auth-version=${OS_API_VERSION} \
              --os-project-name=${OS_PROJECT_NAME} \
              --os-username=${OS_USERNAME} \
              --os-password=${OS_PASSWORD} \
              list ${target} | grep ${base_backup_filename} | sort)
            linecount=$(echo "${backup_list}" | wc -l)
            if [ ${linecount} -gt ${RETENTION} ]; then
              echo "Keeping last ${RETENTION} entries. Removing old backups:"
              lastline=$(( ${linecount} - ${RETENTION} ))
              delete_list=$(echo "${backup_list}" | sed -n "1,${lastline} p")
              for old_entry in ${delete_list}; do
                ${SWIFTCLI} \
                  --os-auth-url=${OS_AUTH_URL} \
                  --auth-version=${OS_API_VERSION} \
                  --os-project-name=${OS_PROJECT_NAME} \
                  --os-username=${OS_USERNAME} --os-password=${OS_PASSWORD} \
                  delete ${target} ${old_entry}
              done
            fi
          fi
        fi
      else
        echo "Skipping backup, dry run delected"
      fi
    else
      send_slack_message_and_echo "Error: ETCD db endpoint ${ETCD_ENDPOINT_URL} not healthy!" danger
      exit 2
    fi
  else
    send_slack_message_and_echo "Error: Cannot exec into container ${CONTAINER} in pod ${POD}!" danger
    exit 2
  fi
}


#======================================================================
# Parse options
#

for i in "$@"
do
case $i in
  --task=*)
  TASK="${i#*=}"
  shift # past argument=value
  ;;
  --namespace=*)
  NAMESPACE="${i#*=}"
  shift # past argument=value
  ;;
  --pod=*)
  POD="${i#*=}"
  shift # past argument=value
  ;;
  --selector=*)
  SELECTOR="${i#*=}"
  shift # past argument=value
  ;;
  --container=*)
  CONTAINER="${i#*=}"
  shift # past argument=value
  ;;
  --database=*)
  DATABASE="${i#*=}"
  shift # past argument=value
  ;;
  --files-path=*)
  FILES_PATH="${i#*=}"
  shift # past argument=value
  ;;
  --s3-bucket=*)
  S3_BUCKET="${i#*=}"
  shift # past argument=value
  ;;
  --s3-prefix=*)
  S3_PREFIX="${i#*=}"
  shift # past argument=value
  ;;
  --secret=*)
  SECRET="${i#*=}"
  shift # past argument=value
  ;;
  --aws-secret=*)
  AWS_SECRET="${i#*=}"
  shift # past argument=value
  ;;
  --slack-secret=*)
  SLACK_SECRET="${i#*=}"
  shift # past argument=value
  ;;
  --slack-pretext=*)
  SLACK_PRETEXT="${i#*=}"
  shift # past argument=value
  ;;
  --kubeconfig-secret=*)
  KUBECONFIG_SECRET="${i#*=}"
  USE_KUBECONFIG=true
  shift # past argument=value
  ;;
  --use-kubeconfig-from-secret)
  USE_KUBECONFIG=true
  shift # past argument with no value
  ;;
  --timestamp=*)
  TIMESTAMP="${i#*=}"
  shift # past argument=value
  ;;
  --backup-name=*)
  BACKUP_NAME="${i#*=}"
  shift # past argument=value
  ;;
  --os-auth-url=*)
  OS_AUTH_URL="${i#*=}"
  shift
  ;;
  --os-api-version=*)
  OS_API_VERSION="${i#*=}"
  shift
  ;;
  --os-project-name=*)
  OS_PROJECT_NAME="${i#*=}"
  shift
  ;;
  --os-username=*)
  OS_USERNAME="${i#*=}"
  shift
  ;;
  --os-password=*)
  OS_PASSWORD="${i#*=}"
  shift
  ;;
#  --os-region-name=*)
#  OS_REGION_NAME="${i#*=}"
#  shift
#  ;;
#  --os-identity-api-version=*)
#  OS_IDENTITY_API_VERSION="${i#*=}"
#  shift
#  ;;
  --backup-backend=*)
  BACKUP_BACKEND="${i#*=}"
  shift
  ;;
  --retention=*)
  RETENTION="${i#*=}"
  shift
  ;;
  --dry-run)
  DRY_RUN=true
  shift # past argument with no value
  ;;
  --help)
  display_usage
  exit 0
  ;;
  --version)
  display_version
  exit 0
  ;;
  *)
  # Unknown option
  echo "Unknown option '$1'"
  display_usage
  exit 1
  ;;
esac
done

#======================================================================
# Check options and environment
#

if [[ -z "$TASK" ]]; then
  echo "No task specified"
  display_usage
  exit 3
fi

: ${KUBECTL:=kubectl}
: ${AWSCLI:=aws}
: ${ENVSUBST:=envsubst}
: ${BASE64:=base64}
: ${SWIFTCLI:=swift}
check_tools $KUBECTL $AWSCLI $ENVSUBST $BASE64 $SWIFTCLI sed basename

# Default secret name is 'kube-backup' in the same namespace
# This is the default secret for all other secrets
# Can be overridden individually
: ${SECRET:=kube-backup}

: ${KUBECONFIG_SECRET:=$SECRET}
if [[ "$USE_KUBECONFIG" == "true" ]]; then
  get_kubeconfig_secret $KUBECONFIG_SECRET
fi

# Only used if an AWS key/secret is not in the environment already
: ${AWS_SECRET:=$SECRET}

# Get optional slack webhook URL
: ${SLACK_SECRET:=$SECRET}
check_for_slack_secret $SLACK_SECRET

# Work out the target namespace
if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE=$($KUBECTL config view --minify -o jsonpath="{.contexts[0].context.namespace} 2> /dev/null")
  if [[ -z "${NAMESPACE}" ]]; then
    echo "No task namespace specified"
  fi
fi

# Create namespace argument is a namespace has been specified
# Otherwise the current namespace will be used (which is not necessarily 'default')
if [[ -n "${NAMESPACE}" ]]; then
  NS_ARG=${NAMESPACE+--namespace=$NAMESPACE}
else
  NS_ARG=""
fi

# Default timestamp for backups
# Setting this in environment or argument allows for multiple backups to be synchronized
: ${TIMESTAMP:=$(date +%Y%m%d-%H%M)}

#======================================================================
# Find pods for tasks
#

if [[ -n "$SELECTOR" ]]; then
  if [[ -n "$POD" ]]; then
    echo "Can only specify a pod name or a selector"
    exit 3
  fi

  PODS=""
  find_pods_with_selector "${SELECTOR}" "${NAMESPACE}" PODS
  if [[ "$?" -ne 0 ]]; then
    exit $?
  fi
  
  POD_ARRAY=($PODS)
  if [[ "${#POD_ARRAY[@]}" -eq 1 ]]; then
    POD="${POD_ARRAY[0]}"
  else
    if [[ "${#POD_ARRAY[@]}" -gt 1 ]]; then
      echo "Selector matched multiple pods, must match only one pod or specify pod name"
      exit 2
    else
      echo "Skipping task, no pods found with selector"
    fi
  fi
fi

#======================================================================
# Run task
#

case $TASK in
  backup-mysql-exec)
	if [[ "${BACKUP_BACKEND}" == "s3" ]]; then
	  backup_mysql_exec
	elif [[ "${BACKUP_BACKEND}" == "swift" ]]; then
	  backup_mysql_exec_swift
	else
	  echo "Unknown backup backend"
	fi
  ;;
  backup-files-exec)
	if [[ "${BACKUP_BACKEND}" == "s3" ]]; then
      backup_files_exec
	elif [[ "${BACKUP_BACKEND}" == "swift" ]]; then
      set_openstack_environment_variables ${SECRET}
      backup_files_exec_swift
	else
	  echo "Unknown backup backend"
	fi
  ;;
  backup-etcd)
	if [[ "${BACKUP_BACKEND}" == "s3" ]]; then
      #backup_etcd_s3
      echo "Not implemented yet"
	elif [[ "${BACKUP_BACKEND}" == "swift" ]]; then
      set_openstack_environment_variables ${SECRET}
      backup_etcd_exec_swift
	else
	  echo "Unknown backup backend"
	fi
  ;;
  test-slack)
    send_slack_message_and_echo "Hello world" warning
  ;;
  dump-env)
    env
  ;;
  test-aws)
    check_for_aws_secret $AWS_SECRET
    env
  ;;
  *)
    # Unknown task
    echo "Unknown task '${TASK}'"
    display_usage
    exit 3
  ;;
esac

echo "Done"

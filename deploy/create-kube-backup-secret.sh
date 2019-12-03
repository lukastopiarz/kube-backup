#!/bin/bash
set -e

# Verify OS and set correct base64 command syntax
OSTYPE=$(uname)
if [[ "$OSTYPE" == "Linux" ]]; then
  BASE64_COMMAND="base64 -w 0"
elif [[ "$OSTYPE" == "Darwin" ]]; then
  BASE64_COMMAND="base64 -i -o -"
else
  echo "Unknow system!"
  exit 1
fi

: ${BACKUP_BACKEND?"Must define BACKUP_BACKEND variable"}
: ${SLACK_WEBHOOK?"Must define SLACK_WEBHOOK"}

BACKUP_BACKEND=$(echo $BACKUP_BACKEND | tr '[:upper:]' '[:lower:]')

if [[ "${BACKUP_BACKEND}" == "s3" ]]; then
  : ${AWS_ACCESS_KEY_ID?"Must define AWS_ACCESS_KEY_ID"}
  : ${AWS_SECRET_ACCESS_KEY?"Must define AWS_SECRET_ACCESS_KEY"}

  if [[ -n "$S3_BUCKET" ]]; then
    S3_SECRET_ITEM="S3_BUCKET: $(echo -n "${S3_BUCKET}" | base64 -w 0)"
  fi
elif [[ "${BACKUP_BACKEND}" == "swift" ]]; then
  : ${OS_AUTH_URL?"Must define OS_AUTH_URL variable"}
  : ${OS_PROJECT_NAME?"Must define OS_PROJECT_NAME variable"}
  : ${OS_USERNAME?"Must define OS_USERNAME variable"}
  : ${OS_PASSWORD?"Must define OS_PASSWORD variable"}
  : ${OS_REGION_NAME?"Must define OS_REGION_NAME variable"}
  : ${OS_IDENTITY_API_VERSION?"Must define OS_IDENTITY_API_VERSION variable"}
  : ${OS_API_VERSION?"Must define OS_API_VERSION variable"}
else
  echo "Unknown backup backend!"
  exit 1
fi

: ${KUBECONFIG_FILE:=kubeconfig}
if [[ ! -r "${KUBECONFIG_FILE}" ]]; then
  echo "kubeconfig file '${KUBECONFIG_FILE}' is missing"
  exit 1
fi


: ${SECRET_NAME:=kube-backup}
: ${SECRET_ENV:=system}
: ${NAMESPACES:=kube-backup}
# Optionally create secret in all namespaces
#NAMESPACES="$(kubectl get namespace -o jsonpath='{..name}')"

for n in $NAMESPACES
do 
  if [[ "$(kubectl get secret $SECRET_NAME --namespace=$n --output name 2> /dev/null || true)" = "secret/${SECRET_NAME}" ]]; then
    ACTION=replace
  else
    ACTION=create
  fi
	
  if [ "${BACKUP_BACKEND}" == "s3" ]; then
    kubectl $ACTION --namespace $n -f - <<END
apiVersion: v1
kind: Secret
type: kubernetes.io/opaque
metadata:
  name: $SECRET_NAME
  labels:
    app: kube-backup
    env: $SECRET_ENV
data:
  SLACK_WEBHOOK: $(echo -n "${SLACK_WEBHOOK}" | ${BASE64_COMMAND})
  AWS_ACCESS_KEY_ID: $(echo -n "${AWS_ACCESS_KEY_ID}" | ${BASE64_COMMAND})
  AWS_SECRET_ACCESS_KEY: $(echo -n "${AWS_SECRET_ACCESS_KEY}" | ${BASE64_COMMAND})
  kubeconfig: $(cat "${KUBECONFIG_FILE}" | base64 -w 0)
  ${S3_SECRET_ITEM}
END
  else
    kubectl $ACTION --namespace $n -f - <<END
apiVersion: v1
kind: Secret
type: kubernetes.io/opaque
metadata:
  name: $SECRET_NAME
  labels:
    app: kube-backup
    env: $SECRET_ENV
data:
  SLACK_WEBHOOK: $(echo -n "${SLACK_WEBHOOK}" | ${BASE64_COMMAND})
  OS_AUTH_URL: $(echo -n "${OS_AUTH_URL}" | ${BASE64_COMMAND})
  OS_PROJECT_NAME: $(echo -n "${OS_PROJECT_NAME}" | ${BASE64_COMMAND})
  OS_USERNAME: $(echo -n "${OS_USERNAME}" | ${BASE64_COMMAND})
  OS_PASSWORD: $(echo -n "${OS_PASSWORD}" | ${BASE64_COMMAND})
  OS_REGION_NAME: $(echo -n "${OS_REGION_NAME}" | ${BASE64_COMMAND})
  OS_IDENTITY_API_VERSION: $(echo -n "${OS_IDENTITY_API_VERSION}" | ${BASE64_COMMAND})
  OS_API_VERSION: $(echo -n "${OS_API_VERSION}" | ${BASE64_COMMAND})
  kubeconfig: $(cat "${KUBECONFIG_FILE}" | ${BASE64_COMMAND})
END
  fi
done

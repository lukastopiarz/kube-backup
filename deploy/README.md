# Sample kube-backup deployment

Before using this example inspect what it does and adjust as required.
It will create a `kube-backup` namespace with RBAC roles and `kube-backup` Secret

## OpenStack Swift Install Steps

### Cluster Administrator Tasks

Cluster admnistrator has to create namespace/project for kube-backup:

```
apiVersion: v1
kind: Namespace
metadata:
  name: kube-backup
  labels:
    app: kube-backup
    env: system
```

Use following command to create one:

```
oc apply -f kube-backup-namespace.yaml
```

In case of OpenShift, cluster administrator has to allow communication to the pods and fetching the secrets with `kube-backup-rbac.yaml` like this:

```
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: <username>-backup
rules:
  - apiGroups: [""]
    resources: ["pods", "secrets"]
    verbs: ["get","list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: <username>-backup
subjects:
  - kind: ServiceAccount
    namespace: <your_project>
    name: default
  - kind: User
    name: system:serviceaccount:<your_project>:default
roleRef:
  kind: ClusterRole
  name: <username>-backup
  apiGroup: rbac.authorization.k8s.io
```

Once you modify `kube-backup-rbac.yaml`, cluster admin has to apply it:

```
oc apply -f kube-backup-rbac.yaml
```

### Developer/Namespace Admin Tasks

Environment variables (Required if not set as parameters during pod run) can be populated to kube-backup secret:

- BACKUP\_BACKEND (swift)
- SLACK\_WEBHOOK
- OS\_AUTH\_URL
- OS\_PROJECT\_NAME
- OS\_USERNAME
- OS\_PASSWORD
- OS\_API\_VERSION
- NAMESPACES (namespaces/projects of pods/containers you want to backup)

[//]: # (These variables not used now:)
[//]: # (- OS\_REGION\_NAME)
[//]: # (- OS\_IDENTITY\_API\_VERSION)
[//]: # (- KUBECONFIG\_FILE \(eg. ~/.kube/config\))

Switch to the environment/project you want to backup:

```
kubens <namespace-name>
```

or in case of OpenShift

```
oc project <project-name>
```

Run command:

```
./create-kube-backup-secret.sh
```

## Amazon S3 Install Steps

Set the required environment variables:

- AWS_ACCESS_KEY_ID
- AWS_SECRET_ACCESS_KEY
- SLACK_WEBHOOK

Optionally set the environment variables:

- S3_BUCKET

Run the `Deploy.sh` script.

*The SLACK_WEBHOOK should really be optional, you can remove it or set it to blank if you wish*

# Sample kube-backup deployment

Before using this example inspect what it does and adjust as required.
It will create a `kube-backup` namespace with RBAC roles and `kube-backup` Secret

## OpenStack Swift Install Steps

Set required environment variables:

- BACKUP\_BACKEND (swift)
- SLACK\_WEBHOOK
- OS\_AUTH\_URL
- OS\_PROJECT\_NAME
- OS\_USERNAME
- OS\_PASSWORD
- OS\_REGION\_NAME
- OS\_IDENTITY\_API\_VERSION
- OS\_API\_VERSION
- KUBECONFIG\_FILE (eg. ~/.kube/config)

Run commands:

```
cd deploy
bash Deploy.sh
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

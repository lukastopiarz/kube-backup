FROM ubuntu:18.04
LABEL MAINTAINER="lukas.topiarz@tieto.com"

RUN export DEBIAN_FRONTEND=noninteractive \
  && apt-get update -y \
  && apt-get install -y apt-utils gettext-base python curl unzip python-pip \
  && curl -sS -L https://s3.amazonaws.com/aws-cli/awscli-bundle.zip -o awscli-bundle.zip \
  && unzip awscli-bundle.zip \
  && ./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws \
  && rm -rf ./awscli-bundle \
  && curl -o /usr/local/bin/kubectl -L https://storage.googleapis.com/kubernetes-release/release/`curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt`/bin/linux/amd64/kubectl \
  && chmod +x /usr/local/bin/kubectl \
  && pip install python-swiftclient python-keystoneclient \
  && apt-get autoremove -y \
  && apt-get clean -y \
  && groupadd -r kube-backup && useradd --no-log-init -r -g kube-backup kube-backup -d /home/kube-backup -m

# We will start and expose ssh on port 22
EXPOSE 22

# Add the container start script, which will start ssh
COPY bin/ /home/kube-backup/bin

# change the user
USER kube-backup
ENTRYPOINT ["/home/kube-backup/bin/kube-backup.sh"]

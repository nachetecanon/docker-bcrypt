ARG KUSTOMIZE_VERSION=v3.9.4
ARG VAULT_VERSION=1.5.4
ARG DEFAULT_PWD_LENGTH=16
ARG HELM_VERSION=v3.3.4
ARG KUBECTL_VERSION=v1.18.8
ARG YQ_VERSION=4.6.3
ARG JQ_VERSION=1.6
FROM alpine:3.12.0 as downloader
ARG KUSTOMIZE_VERSION
ARG VAULT_VERSION
ARG DEFAULT_PWD_LENGTH
ARG HELM_VERSION
ARG KUBECTL_VERSION
ARG YQ_VERSION
ARG JQ_VERSION

ENV KUBEVAL_URL=https://github.com/instrumenta/kubeval/releases/latest/download/kubeval-linux-amd64.tar.gz
ENV VAULT_DOWNLOAD_URL=https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip
ENV KUSTOMIZE_URL=https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz
ENV HELM_URL=https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz
ENV YQ_URL=https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64
ENV JQ_URL=https://github.com/stedolan/jq/releases/download/jq-${JQ_VERSION}/jq-linux64
ENV KUBECTL_URL=https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl

RUN apk add curl  && \
    mkdir -p /opt/bin && \
    echo "downloading kubectl from ${KUBECTL_URL} ..." && curl -Lks ${KUBECTL_URL} -o /opt/bin/kubectl && \
    echo "downloading kubeval from ${KUBEVAL_URL} ..." && curl -Lks ${KUBEVAL_URL} | tar xz -C /opt/bin && \
    echo "downloading helm from ${HELM_URL} ..." && curl -Lks ${HELM_URL} | tar xz -C . --strip 1 && mv helm /opt/bin/helm && \
    echo "downloading vault from ${VAULT_DOWNLOAD_URL} ..." && curl -Lks ${VAULT_DOWNLOAD_URL} -o vault.zip && unzip vault.zip -d /opt/bin && \
    echo "downloading kustomize from ${KUSTOMIZE_URL} ..." && curl -Lks ${KUSTOMIZE_URL}  | tar xz -C /opt/bin && \
    echo "downloading yq from ${YQ_URL} ..." && curl -Lks ${YQ_URL} -o /opt/bin/yq && \
    echo "downloading jq from ${JQ_URL} ..." && curl -Lks ${JQ_URL} -o /opt/bin/jq &&  chmod +x /opt/bin/*
################################################################################################################################################################################
FROM golang:1.14 as builder

WORKDIR /go/src/bcrypt
COPY bcrypt.go /go/src/bcrypt/bcrypt.go
COPY fernet.go /go/src/fernet/fernet.go

RUN cd /go/src/bcrypt && go get -v . && go build -v bcrypt.go && \
    cd /go/src/fernet && go get -v . && go build -v fernet.go && \
    cp /go/src/bcrypt/bcrypt /opt/bin && cp /go/src/fernet/fernet /opt/bin
################################################################################################################################################################################

FROM centos:7
ARG KUSTOMIZE_VERSION
ARG VAULT_VERSION
ARG DEFAULT_PWD_LENGTH
ARG HELM_VERSION
ARG KUBECTL_VERSION

COPY --from=downloader /opt/bin /opt/bin
COPY --from=builder /go/bin/bcrypt /opt/bin
COPY --from=builder /go/bin/fernet /opt/bin

ADD kustomize /opt/kplugins/kustomize/
ADD scripts /opt/scripts/
ADD tests /opt/tests/
ENV XDG_CONFIG_HOME=/opt/kplugins \
    PATH=/opt/bin:/opt/scripts:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN yum install -y -q httpd-tools python3-pip openssl ca-certificates gettext bash git which diff --setopt=tsflags=nodocs && \
    find $XDG_CONFIG_HOME -type f ! -name "*.*" -exec chmod a+x {} \; && \
    ls /opt/bin && \
    chmod +x /opt/bin/* /opt/scripts/* && \
    cp /usr/bin/htpasswd /opt/bin && \
    mv /opt/scripts/shunit2 /usr/bin/shunit2 && chmod +x /usr/bin/shunit2 && \
    echo "running unit tests for scripts..." && \
    for i in $(ls -1 /opt/tests/*.sh);do echo "running tests in $i..." && chmod +x $i && bash -c "$i" || exit -1 ;done    && \
    yum clean all && rm -rf /var/cache/yum && rm -rf /var/cache/dnf /tmp/* && \
    rm -fR /opt/tests


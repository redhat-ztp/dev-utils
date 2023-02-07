FROM quay.io/podman/stable:latest

RUN dnf install -y \
    createrepo_c \
    dnf-utils \
    git \
    jq \
    rpmdevtools \
    skopeo \
    wget \
    which

RUN curl -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp-dev-preview/latest/openshift-client-linux.tar.gz \
    | tar xvzf - -C /usr/local/bin oc

COPY optv-build*.sh /usr/local/bin/

WORKDIR /workdir


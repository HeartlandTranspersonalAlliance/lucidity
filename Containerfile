ARG BASE_IMAGE=quay.io/almalinuxorg/almalinux-bootc:10

FROM ${BASE_IMAGE} AS common

# Pinned for reproducible AMD64/T3a builds. Select the matching architecture
# artifact explicitly when the deferred ARM64 milestone begins.
ARG SSM_AGENT_RPM_URL=https://s3.us-east-2.amazonaws.com/amazon-ssm-us-east-2/3.3.5068.0/linux_amd64/amazon-ssm-agent.rpm

# Docker documents its RHEL repository as supporting RHEL 10 on amd64 and arm64.
# The repository's GPG configuration remains enabled; packages are never installed
# with --nogpgcheck. Do not remove Podman: AlmaLinux's bootc and rpm-ostree
# packages currently depend on it. Docker remains the application runtime.
RUN dnf -y install dnf-plugins-core && \
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo && \
    dnf -y install \
        ca-certificates \
        cloud-init \
        container-selinux \
        curl \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin \
        git \
        gzip \
        jq \
        logrotate \
        NetworkManager \
        openssh-server \
        openssl \
        policycoreutils \
        rsyslog \
        selinux-policy-targeted \
        tar \
        wget && \
    dnf -y install "${SSM_AGENT_RPM_URL}" && \
    dnf clean all && \
    rm -rf \
        /run/cloud-init \
        /var/cache/* \
        /var/lib/cloud \
        /var/lib/dnf \
        /var/log/*

COPY roles/common/etc/ /etc/
COPY roles/common/usr/ /usr/

RUN install -d -m 0755 /nix /usr/lib/coolify-aws && \
    systemctl enable \
        cloud-config.service \
        cloud-final.service \
        cloud-init-local.service \
        cloud-init.service \
        bootc-fetch-apply-updates.timer \
        docker.service \
        amazon-ssm-agent.service \
        sshd.service

FROM common AS controller

ARG IMAGE_VERSION=dev

RUN printf '%s\n' "${IMAGE_VERSION}" > /usr/lib/coolify-aws/image-version && \
    bootc container lint

LABEL org.opencontainers.image.title="Coolify bootc controller foundation" \
      org.opencontainers.image.description="AlmaLinux bootc host foundation for the Coolify controller" \
      org.opencontainers.image.source="https://github.com/HeartlandTranspersonalAlliance/lucidity" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      io.coolify-aws.role="controller" \
      io.coolify-aws.image-version="${IMAGE_VERSION}"

FROM common AS worker

ARG IMAGE_VERSION=dev

COPY scripts/bootstrap-worker.sh /usr/libexec/coolify-aws/bootstrap-worker
COPY roles/worker/usr/ /usr/

RUN printf '%s\n' "${IMAGE_VERSION}" > /usr/lib/coolify-aws/image-version && \
    chmod 0755 /usr/libexec/coolify-aws/bootstrap-worker && \
    systemctl enable coolify-worker-authorized-keys.service && \
    bootc container lint

LABEL org.opencontainers.image.title="Coolify bootc worker" \
      org.opencontainers.image.description="AlmaLinux bootc host for Coolify-managed Docker workloads" \
      org.opencontainers.image.source="https://github.com/HeartlandTranspersonalAlliance/lucidity" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      io.coolify-aws.role="worker" \
      io.coolify-aws.image-version="${IMAGE_VERSION}"

FROM ubuntu:24.04

ARG KUBERNETES_VERSION=1.36.1
ARG KUBERNETES_MINOR=v1.36
ARG PAUSE_VERSION=3.10.2

ENV container=docker

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus \
      containerd \
      conntrack iptables iproute2 ethtool socat util-linux mount ebtables udev kmod \
      libseccomp2 pigz \
      bash ca-certificates curl gnupg apt-transport-https \
      nfs-common vim-tiny; \
    apt-get clean -y; \
    rm -rf /var/lib/apt/lists/* /var/cache/debconf/* /tmp/* /var/tmp/*

RUN set -eux; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /" \
      > /etc/apt/sources.list.d/kubernetes.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      kubelet="${KUBERNETES_VERSION}-1.1" \
      kubeadm="${KUBERNETES_VERSION}-1.1" \
      kubectl="${KUBERNETES_VERSION}-1.1"; \
    apt-mark hold kubelet kubeadm kubectl; \
    printf '%s\n' 'KUBELET_EXTRA_ARGS=--fail-swap-on=false' > /etc/default/kubelet; \
    apt-get clean -y; \
    rm -rf /var/lib/apt/lists/* /var/cache/debconf/* /tmp/* /var/tmp/*

RUN set -eux; \
    mkdir -p /etc/containerd /etc/sysctl.d /var/lib/kubelet /kind; \
    containerd config default > /etc/containerd/config.toml; \
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml; \
    sed -i "s/snapshotter = 'overlayfs'/snapshotter = 'native'/" /etc/containerd/config.toml; \
    sed -i "s#sandbox = 'registry.k8s.io/pause:[^']*'#sandbox = 'registry.k8s.io/pause:${PAUSE_VERSION}'#" /etc/containerd/config.toml; \
    printf '%s\n' \
      'net.bridge.bridge-nf-call-ip6tables = 1' \
      'net.bridge.bridge-nf-call-iptables = 1' \
      'net.ipv4.ip_forward = 1' \
      > /etc/sysctl.d/k8s.conf

RUN set -eux; \
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      'if [[ ! -e /dev/kmsg && -e /dev/console ]]; then' \
      '  ln -sf /dev/console /dev/kmsg' \
      'fi' \
      '' \
      'rm -f /etc/machine-id' \
      'systemd-machine-id-setup' \
      '' \
      'mount -o remount,ro /sys 2>/dev/null || true' \
      'mount --make-rshared / 2>/dev/null || true' \
      '' \
      'exec "$@"' \
      > /usr/local/bin/k8s-node-entrypoint; \
    chmod +x /usr/local/bin/k8s-node-entrypoint

RUN set -eux; \
    find /lib/systemd/system/sysinit.target.wants/ -name "systemd-tmpfiles-setup.service" -delete || true; \
    rm -f /lib/systemd/system/multi-user.target.wants/*; \
    rm -f /etc/systemd/system/*.wants/*; \
    rm -f /lib/systemd/system/local-fs.target.wants/*; \
    rm -f /lib/systemd/system/sockets.target.wants/*udev*; \
    rm -f /lib/systemd/system/sockets.target.wants/*initctl*; \
    rm -f /lib/systemd/system/basic.target.wants/*; \
    echo "ReadKMsg=no" >> /etc/systemd/journald.conf; \
    ln -sf /lib/systemd/systemd /sbin/init; \
    if [[ -f /usr/lib/systemd/system/systemd-tmpfiles-clean.timer ]]; then \
      sed -i -E 's#OnBootSec=.*#OnBootSec=1min#' /usr/lib/systemd/system/systemd-tmpfiles-clean.timer; \
    fi; \
    sed -i -E 's#^(hosts:[[:space:]]*).*#\1dns files#' /etc/nsswitch.conf; \
    systemctl enable containerd kubelet

STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/usr/local/bin/k8s-node-entrypoint", "/sbin/init"]

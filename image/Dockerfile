# Self-hosted orb base image with systemd as PID 1.
#
# Built for sysbox-runc (this host's default runtime), which runs systemd inside
# an unprivileged container: the container gets its own user namespace, so PID 1
# is namespaced root (uid 165536 on the host), not host root. No --privileged,
# no --cap-add, no host cgroup or /sys mounts.
#
# Requirements follow https://ampcode.com/docs/orbs/self-hosted#bring-your-own-image
# plus the systemd support the docs describe for Amp services.
#
# The dispatch program boots this image with `--user root /sbin/init`; the image
# default user stays `user`, so `docker exec ... amp orb bootstrap` still runs as
# the unprivileged user the dispatch contract asks for.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

# systemd (PID 1) plus everything the dispatch contract requires: bash,
# coreutils, util-linux, CA certificates, git >= 2.34, sudo, node >= 18,
# tmux >= 2.9, curl, and the recommended ripgrep, gh and openssh-client.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        bash ca-certificates coreutils util-linux gzip \
        git sudo tmux curl nodejs \
        ripgrep gh openssh-client \
 && rm -rf /var/lib/apt/lists/*

# The Amp CLI at /usr/local/bin/amp, checksum-verified against the published
# sha256 of the decompressed binary (same source install.sh uses).
RUN set -eux; \
    ver="$(curl -fsSL https://static.ampcode.com/cli/cli-version.txt)"; \
    base="https://static.ampcode.com/cli/${ver}"; \
    curl -fsSL "${base}/amp-linux-x64.gz" -o /tmp/amp.gz; \
    curl -fsSL "${base}/linux-x64-amp.sha256" -o /tmp/amp.sha256; \
    gunzip -c /tmp/amp.gz > /usr/local/bin/amp; \
    echo "$(cat /tmp/amp.sha256)  /usr/local/bin/amp" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/amp; \
    rm -f /tmp/amp.gz /tmp/amp.sha256; \
    /usr/local/bin/amp --version

# The image's default user must be `user` with a writable home and passwordless
# sudo, because Amp uses sudo to configure Git and prepare runtime files.
RUN set -eux; \
    userdel -r ubuntu 2>/dev/null || true; \
    useradd --create-home --uid 1000 --shell /bin/bash user; \
    printf 'user ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/user; \
    chmod 0440 /etc/sudoers.d/user; \
    mkdir -p /home/user/workspace; \
    chown -R user:user /home/user

# Units that need host kernel access cannot work in an unprivileged container.
# Masking them keeps `systemctl is-system-running` at "running" instead of
# "degraded" for failures that are expected here (they need /sys/kernel and kmod,
# which is exactly the privileged access we are avoiding).
# `systemctl mask` cannot run during a build (no systemd is booted), so the mask
# symlinks are created directly.
RUN set -eux; \
    for unit in \
        systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket \
        getty@.service console-getty.service serial-getty@.service \
        systemd-modules-load.service systemd-random-seed.service \
        kmod-static-nodes.service \
        sys-kernel-config.mount sys-kernel-debug.mount sys-kernel-tracing.mount; do \
        ln -sf /dev/null "/etc/systemd/system/${unit}"; \
    done

USER user
WORKDIR /home/user

# `docker stop` sends this so systemd shuts the orb down cleanly instead of
# being killed after the 10s timeout.
STOPSIGNAL SIGRTMIN+3

# The dispatch program passes /sbin/init with --user root; this is the default
# for anyone running the image by hand.
CMD ["/sbin/init"]

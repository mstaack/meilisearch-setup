# Minimal systemd-enabled image for test/smoke.sh. Works on amd64 and arm64.
#   docker build -t meili-smoke --build-arg BASE=debian:12 -f test/Dockerfile .
ARG BASE=debian:12
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl mask systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \
      systemd-modules-load.service sys-kernel-config.mount sys-kernel-debug.mount \
      getty.target console-getty.service systemd-logind.service systemd-resolved.service \
      systemd-networkd.service systemd-timesyncd.service >/dev/null 2>&1 || true
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

FROM alpine:3.21

# Versions of diagnostic tools: can be overridden during build via --build-arg
ARG DUF_VERSION=0.9.1
ARG GDU_VERSION=5.36.1

RUN apk add --no-cache \
    bash \
    samba \
    samba-common-tools \
    nfs-utils \
    e2fsprogs \
    kmod \
    mc \
    htop \
    btop \
    nano \
    net-tools \
    util-linux \
    findutils \
    curl

# Switch build shell to bash — all subsequent RUN commands execute in bash
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# duf is not in Alpine repository — install .apk directly from GitHub Releases.
# Version is fixed via ARG (reproducibility) but can be overridden during build:
#   docker build --build-arg DUF_VERSION=0.10.0 .
# Only amd64 and arm64 are supported — build fails on other architectures.
RUN ARCH=$(uname -m) \
    && case "$ARCH" in \
        x86_64)    DUF_ARCH="amd64"  ;; \
        aarch64)   DUF_ARCH="arm64"  ;; \
        *)         echo "⚠ duf: architecture $ARCH is not supported" >&2; exit 1 ;; \
    esac \
    && echo "Installing duf version $DUF_VERSION" \
    && DUF_FILE="duf_${DUF_VERSION}_linux_${DUF_ARCH}.apk" \
    && DUF_URL="https://github.com/muesli/duf/releases/download/v${DUF_VERSION}/${DUF_FILE}" \
    && echo "Downloading duf ($ARCH → $DUF_ARCH): $DUF_URL" \
    && curl -fL -o "/tmp/${DUF_FILE}" "${DUF_URL}" \
    && apk add --allow-untrusted "/tmp/${DUF_FILE}" \
    && rm -f "/tmp/${DUF_FILE}" \
    && duf --version \
    && echo "✓ duf installed"

# gdu — Alpine apk packages from mr-addams/gdu releases (amd64 + arm64).
# Version is fixed via ARG (reproducibility), can be overridden via --build-arg:
#   docker build --build-arg GDU_VERSION=5.37.0 .
# Only amd64 and arm64 are supported — build fails on other architectures.
RUN ARCH=$(uname -m) \
    && case "$ARCH" in \
        x86_64)  GDU_FILE="gdu_${GDU_VERSION}_x86_64.apk"  ;; \
        aarch64) GDU_FILE="gdu_${GDU_VERSION}_aarch64.apk" ;; \
        *)       echo "⚠ gdu: architecture $ARCH is not supported" >&2; exit 1 ;; \
    esac \
    && echo "Installing gdu version $GDU_VERSION" \
    && GDU_URL="https://github.com/mr-addams/gdu/releases/download/v${GDU_VERSION}/${GDU_FILE}" \
    && echo "Downloading gdu ($ARCH): $GDU_URL" \
    && curl -fL -o "/tmp/${GDU_FILE}" "${GDU_URL}" \
    && apk add --allow-untrusted "/tmp/${GDU_FILE}" \
    && rm -f "/tmp/${GDU_FILE}" \
    && gdu --version \
    && echo "✓ gdu installed"

# Change root's default shell from /bin/ash to bash — works in docker exec and interactive sessions
RUN sed -i 's|^\(root:.*:\)/bin/sh$|\1/bin/bash|' /etc/passwd

RUN mkdir -p /shares

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 2049 111 139 445

ENTRYPOINT ["/entrypoint.sh"]

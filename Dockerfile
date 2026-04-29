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
# Unknown architecture or download failure does not break build (|| true at the end).
RUN ARCH=$(uname -m) \
    && case "$ARCH" in \
        x86_64)    DUF_ARCH="amd64"  ;; \
        aarch64)   DUF_ARCH="arm64"  ;; \
        armv7l)    DUF_ARCH="armv7"  ;; \
        armv6l)    DUF_ARCH="armv6"  ;; \
        i686|i386) DUF_ARCH="386"    ;; \
        *)         DUF_ARCH=""        ;; \
    esac \
    && if [ -z "$DUF_ARCH" ]; then \
        echo "⚠ duf: architecture $ARCH is not supported — skipping" ; \
    else \
        echo "Installing duf version $DUF_VERSION" \
        && DUF_FILE="duf_${DUF_VERSION}_linux_${DUF_ARCH}.apk" \
        && DUF_URL="https://github.com/muesli/duf/releases/download/v${DUF_VERSION}/${DUF_FILE}" \
        && echo "Downloading duf ($ARCH → $DUF_ARCH): $DUF_URL" \
        && curl -fL -o "/tmp/${DUF_FILE}" "${DUF_URL}" \
        && apk add --allow-untrusted "/tmp/${DUF_FILE}" \
        && rm -f "/tmp/${DUF_FILE}" \
        && duf --version \
        && echo "✓ duf installed" ; \
    fi || echo "⚠ duf: installation failed — skipping"

# gdu — interactive disk usage analyzer, Go binary from GitHub Releases.
# Alpine uses musl libc — needs statically linked build.
# For amd64 release is explicitly marked with _static suffix; other architectures are cross-compiled
# without CGO and are statically linked by default.
# Version is fixed via ARG (reproducibility), can be overridden via --build-arg:
#   docker build --build-arg GDU_VERSION=5.37.0 .
RUN ARCH=$(uname -m) \
    && case "$ARCH" in \
        x86_64)    GDU_ARCH="amd64_static" ;; \
        aarch64)   GDU_ARCH="arm64"        ;; \
        armv7l)    GDU_ARCH="armv7l"       ;; \
        armv6l)    GDU_ARCH="armv6l"       ;; \
        i686|i386) GDU_ARCH="386"          ;; \
        *)         GDU_ARCH=""              ;; \
    esac \
    && if [ -z "$GDU_ARCH" ]; then \
        echo "⚠ gdu: architecture $ARCH is not supported — skipping" ; \
    else \
        echo "Installing gdu version $GDU_VERSION" \
        && GDU_FILE="gdu_linux_${GDU_ARCH}.tgz" \
        && GDU_URL="https://github.com/dundee/gdu/releases/download/v${GDU_VERSION}/${GDU_FILE}" \
        && echo "Downloading gdu ($ARCH → $GDU_ARCH): $GDU_URL" \
        && curl -fL -o "/tmp/${GDU_FILE}" "${GDU_URL}" \
        && tar xzf "/tmp/${GDU_FILE}" -C /tmp "gdu_linux_${GDU_ARCH}" \
        && install -m 755 "/tmp/gdu_linux_${GDU_ARCH}" /usr/local/bin/gdu \
        && rm -f "/tmp/${GDU_FILE}" "/tmp/gdu_linux_${GDU_ARCH}" \
        && gdu --version \
        && echo "✓ gdu installed" ; \
    fi || echo "⚠ gdu: installation failed — skipping"

# Change root's default shell from /bin/ash to bash — works in docker exec and interactive sessions
RUN sed -i 's|^\(root:.*:\)/bin/sh$|\1/bin/bash|' /etc/passwd

RUN mkdir -p /shares

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 2049 111 139 445

ENTRYPOINT ["/entrypoint.sh"]

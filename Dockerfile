FROM alpine:3.21

RUN apk add --no-cache \
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
    curl \
    && echo "=== Установка duf ===" \
    && ARCH=$(uname -m) \
    && case "$ARCH" in \
        x86_64) DUF_ARCH="amd64" ;; \
        aarch64) DUF_ARCH="arm64" ;; \
        armv7l) DUF_ARCH="armv7" ;; \
        i686|i386) DUF_ARCH="386" ;; \
        *) echo "ОШИБКА: Не поддерживаемая архитектура: $ARCH" && exit 1 ;; \
    esac \
    && DUF_VERSION="0.9.1" \
    && DUF_FILE="duf_${DUF_VERSION}_linux_${DUF_ARCH}.apk" \
    && DUF_URL="https://github.com/muesli/duf/releases/download/v${DUF_VERSION}/${DUF_FILE}" \
    && echo "Архитектура: $ARCH → $DUF_ARCH" \
    && echo "Загрузка APK: $DUF_URL" \
    && curl -fL -o "/tmp/${DUF_FILE}" "${DUF_URL}" || { echo "ОШИБКА: Не удалось загрузить $DUF_URL"; exit 1; } \
    && apk add --allow-untrusted "/tmp/${DUF_FILE}" || { echo "ОШИБКА: Установка APK не удалась"; exit 1; } \
    && rm -f "/tmp/${DUF_FILE}" /var/cache/apk/* \
    && duf --version \
    && echo "=== duf установлен успешно ==="
    
    
RUN mkdir -p /shares

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 2049 111 139 445

ENTRYPOINT ["/entrypoint.sh"]


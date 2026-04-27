FROM alpine:3.21

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

# duf отсутствует в Alpine-репозитории — устанавливаем свежий .apk прямо из GitHub Releases.
# Версия определяется динамически через API: всегда ставится последний релиз.
# Неизвестная архитектура или сбой загрузки не ломают сборку (|| true в конце).
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
        echo "⚠ duf: архитектура $ARCH не поддерживается — пропуск" ; \
    else \
        DUF_VERSION=$(curl -fsSL https://api.github.com/repos/muesli/duf/releases/latest \
            | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/') \
        && echo "Последняя версия duf: $DUF_VERSION" \
        && DUF_FILE="duf_${DUF_VERSION}_linux_${DUF_ARCH}.apk" \
        && DUF_URL="https://github.com/muesli/duf/releases/download/v${DUF_VERSION}/${DUF_FILE}" \
        && echo "Загрузка duf ($ARCH → $DUF_ARCH): $DUF_URL" \
        && curl -fL -o "/tmp/${DUF_FILE}" "${DUF_URL}" \
        && apk add --allow-untrusted "/tmp/${DUF_FILE}" \
        && rm -f "/tmp/${DUF_FILE}" \
        && duf --version \
        && echo "✓ duf установлен" ; \
    fi || echo "⚠ duf: установка не удалась — пропуск"

RUN mkdir -p /shares

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 2049 111 139 445

ENTRYPOINT ["/entrypoint.sh"]

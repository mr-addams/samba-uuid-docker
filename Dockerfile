FROM alpine:3.21

# Версии diagnostic tools: можно переопределить при сборке через --build-arg
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

# Переключаем шелл сборки на bash — все последующие RUN выполняются в bash
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# duf отсутствует в Alpine-репозитории — устанавливаем .apk прямо из GitHub Releases.
# Версия фиксирована через ARG (воспроизводимость), но может быть переопределена при сборке:
#   docker build --build-arg DUF_VERSION=0.10.0 .
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
        echo "Установка duf версия $DUF_VERSION" \
        && DUF_FILE="duf_${DUF_VERSION}_linux_${DUF_ARCH}.apk" \
        && DUF_URL="https://github.com/muesli/duf/releases/download/v${DUF_VERSION}/${DUF_FILE}" \
        && echo "Загрузка duf ($ARCH → $DUF_ARCH): $DUF_URL" \
        && curl -fL -o "/tmp/${DUF_FILE}" "${DUF_URL}" \
        && apk add --allow-untrusted "/tmp/${DUF_FILE}" \
        && rm -f "/tmp/${DUF_FILE}" \
        && duf --version \
        && echo "✓ duf установлен" ; \
    fi || echo "⚠ duf: установка не удалась — пропуск"

# gdu — интерактивный анализатор использования диска, Go-бинарник из GitHub Releases.
# Alpine использует musl libc — нужна статически слинкованная сборка.
# Для amd64 релиз явно помечен суффиксом _static; остальные арки кросс-компилируются
# без CGO и по умолчанию статически слинкованы.
# Версия фиксирована через ARG (воспроизводимость), переопределяется через --build-arg:
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
        echo "⚠ gdu: архитектура $ARCH не поддерживается — пропуск" ; \
    else \
        echo "Установка gdu версия $GDU_VERSION" \
        && GDU_FILE="gdu_linux_${GDU_ARCH}.tgz" \
        && GDU_URL="https://github.com/dundee/gdu/releases/download/v${GDU_VERSION}/${GDU_FILE}" \
        && echo "Загрузка gdu ($ARCH → $GDU_ARCH): $GDU_URL" \
        && curl -fL -o "/tmp/${GDU_FILE}" "${GDU_URL}" \
        && tar xzf "/tmp/${GDU_FILE}" -C /tmp "gdu_linux_${GDU_ARCH}" \
        && install -m 755 "/tmp/gdu_linux_${GDU_ARCH}" /usr/local/bin/gdu \
        && rm -f "/tmp/${GDU_FILE}" "/tmp/gdu_linux_${GDU_ARCH}" \
        && gdu --version \
        && echo "✓ gdu установлен" ; \
    fi || echo "⚠ gdu: установка не удалась — пропуск"

# Меняем дефолтный шелл рута с /bin/ash на bash — работает в docker exec и интерактивных сессиях
RUN sed -i 's|^\(root:.*:\)/bin/sh$|\1/bin/bash|' /etc/passwd

RUN mkdir -p /shares

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 2049 111 139 445

ENTRYPOINT ["/entrypoint.sh"]

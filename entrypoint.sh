#!/bin/sh
set -e

# ========================== Модуль entrypoint ==================================
#   Точка входа контейнера samba-uuid-docker.
#   1. Воссоздаёт симлинки /dev/disk/by-uuid (udev внутри контейнера не работает)
#   2. Проверяет, что каждый диск из DISK_<NAME>=<UUID> не смонтирован на хосте
#   3. Монтирует диски эксклюзивно, запускает Samba + NFS
#   4. При SIGTERM/SIGINT — корректно размонтирует до выхода

# ========================== Логирование ========================================

log()         { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
log_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ОШИБКА: $1" >&2; }
log_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1"; }
log_debug()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $1"; }

# ========================== Шаг 1: Симлинки /dev/disk/by-uuid =================

log "=== Samba + NFS на Alpine ==="
log "Шаг 1: Создание символических ссылок /dev/disk/by-uuid..."
mkdir -p /dev/disk/by-uuid /dev/disk/by-id

devices_found=0
for dev in /dev/sd* /dev/nvme* /dev/vd* /dev/mmcblk*; do
    [ -b "$dev" ] 2>/dev/null || continue
    devices_found=$((devices_found + 1))
    uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null)
    if [ -n "$uuid" ]; then
        ln -sf "$dev" "/dev/disk/by-uuid/$uuid"
        log_success "Ссылка: /dev/disk/by-uuid/$uuid → $dev"
    fi
done
log "Найдено блочных устройств: $devices_found"

# ========================== Шаг 2: Конфигурация ================================

log "Шаг 2: Загрузка конфигурации..."
WORKGROUP=${WORKGROUP:-WORKGROUP}
SERVER_STRING=${SERVER_STRING:-"Docker Samba+NFS (Alpine)"}
NETBIOS_NAME=${NETBIOS_NAME:-dockersamba}
GUEST_OK=${GUEST_OK:-yes}
READ_ONLY=${READ_ONLY:-no}
FORCE_USER=${FORCE_USER:-root}

# ========================== Шаг 3: Разбор DISK_* ==============================

log "Шаг 3: Поиск дисков в переменных окружения..."
DISKS=""
SHARE_NAMES=""
disk_count=0

for var in $(env | grep '^DISK_'); do
    name=$(echo "$var" | cut -d'=' -f1 | sed 's/^DISK_//')
    uuid=$(echo "$var" | cut -d'=' -f2-)
    [ -z "$uuid" ] && continue
    disk_count=$((disk_count + 1))
    # Без ведущего пробела — иначе cut -d' ' -f1 вернёт пустую строку для первого элемента
    if [ -z "$DISKS" ]; then
        DISKS="$uuid"
        SHARE_NAMES="$name"
    else
        DISKS="$DISKS $uuid"
        SHARE_NAMES="$SHARE_NAMES $name"
    fi
    log_success "Диск #$disk_count: $name → UUID $uuid"
done

if [ -z "$DISKS" ]; then
    log_error "Не найдено ни одного DISK_xxx в переменных окружения!"
    log_error "Проверьте файл deploy.env"
    env | grep -E '^(DISK_|WORKGROUP|SERVER)' || true
    exit 1
fi
log_success "Дисков найдено: $disk_count"

# ========================== Функции: монтирование ==============================

# Проверяет, смонтирован ли диск с данным UUID где-либо в системе.
# findmnt оперирует реальными путями — резолвим симлинк перед проверкой.
is_mounted_anywhere() {
    local uuid=$1
    local dev="/dev/disk/by-uuid/$uuid"
    local real_dev
    real_dev=$(readlink -f "$dev" 2>/dev/null) || real_dev="$dev"
    log_debug "Проверка монтирования: UUID=$uuid real=$real_dev"
    if findmnt -rno SOURCE 2>/dev/null | grep -qF "$real_dev"; then
        log_debug "Диск уже смонтирован"
        return 0
    fi
    log_debug "Диск не смонтирован"
    return 1
}

check_and_mount() {
    local uuid=$1
    local share_name=$2
    local dev="/dev/disk/by-uuid/$uuid"
    local mountpoint="/shares/$share_name"

    log ""
    log "========================================="
    log "Диск: $share_name  UUID: $uuid"
    log "Устройство: $dev  →  $mountpoint"
    log "========================================="

    if [ ! -e "$dev" ]; then
        log_error "Устройство $dev не существует!"
        log_error "Доступные UUID:"
        ls -la /dev/disk/by-uuid/ 2>&1 || true
        return 1
    fi
    log_success "Устройство существует"

    mkdir -p "$mountpoint"

    if is_mounted_anywhere "$uuid"; then
        log_error "Диск $uuid уже смонтирован на хосте — отказ!"
        return 1
    fi
    log_success "Диск не смонтирован"

    # Определяем тип ФС — не хардкодим ext4
    local fs_type
    fs_type=$(blkid -s TYPE -o value "$dev" 2>/dev/null)
    if [ -z "$fs_type" ]; then
        log_error "Не удалось определить тип файловой системы для $dev"
        return 1
    fi
    log "Тип файловой системы: $fs_type"

    # e2fsck только для ext2/3/4
    if echo "$fs_type" | grep -qE '^ext[234]$'; then
        log "Проверка файловой системы (e2fsck)..."
        if ! e2fsck -n -f "$dev" >/dev/null 2>&1; then
            log "Обнаружены ошибки → автоматический ремонт..."
            if ! e2fsck -p -f "$dev" 2>&1; then
                log "Авторемонт не помог → интерактивный режим (-y)..."
                if ! e2fsck -y -f "$dev" 2>&1; then
                    log_error "Не удалось исправить файловую систему!"
                    return 1
                fi
            fi
        else
            log_success "Файловая система чистая"
        fi
    fi

    log "Монтирование $dev → $mountpoint (тип: $fs_type)..."
    if ! mount -t "$fs_type" -o defaults,noatime,nodiratime "$dev" "$mountpoint" 2>&1; then
        log_error "Ошибка монтирования!"
        blkid "$dev" 2>&1 || true
        return 1
    fi

    sync
    log_success "Диск $share_name смонтирован"
    df -h "$mountpoint" 2>&1 || true
}

# ========================== Завершение: размонтирование ========================

cleanup() {
    log ""
    log "========================================="
    log "Получен сигнал остановки — размонтирование..."
    log "========================================="
    for name in $SHARE_NAMES; do
        mp="/shares/$name"
        mountpoint -q "$mp" 2>/dev/null || continue
        log "→ Sync + umount $mp..."
        sync
        if umount "$mp" 2>/dev/null; then
            log_success "$name размонтирован"
        elif umount -f "$mp" 2>/dev/null; then
            log_success "$name размонтирован с -f"
        else
            umount -l "$mp" 2>/dev/null \
                && log_success "$name: lazy unmount" \
                || log_error "Не удалось размонтировать $name"
        fi
    done
    log "Завершение."
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# ========================== Шаг 4: Монтирование ================================

log ""
log "========================================="
log "МОНТИРОВАНИЕ ДИСКОВ (всего: $disk_count)"
log "========================================="
i=1
for uuid in $DISKS; do
    name=$(echo "$SHARE_NAMES" | tr -s ' ' | cut -d' ' -f$i)
    log ">>> Диск #$i: $name"
    if ! check_and_mount "$uuid" "$name"; then
        log_error "Критическая ошибка с диском $name (UUID: $uuid)"
        exit 1
    fi
    i=$((i + 1))
done

log_success "Все диски смонтированы"

# ========================== Шаг 5: NFS =========================================

log "Шаг 5: Настройка и запуск NFS..."

# Загружаем модуль ядра и монтируем nfsd pseudo-fs (доступно в privileged-контейнере)
modprobe nfsd 2>/dev/null || true
mount -t nfsd nfsd /proc/fs/nfsd 2>/dev/null || true

# Генерируем /etc/exports без вложенных heredoc
exports_content=""
for name in $SHARE_NAMES; do
    mp="/shares/$name"
    mountpoint -q "$mp" 2>/dev/null || continue
    exports_content="${exports_content}${mp} *(rw,sync,no_subtree_check,no_root_squash,insecure)
"
done
printf '%s' "$exports_content" > /etc/exports
log_debug "Содержимое /etc/exports:"
cat /etc/exports

# rc-service не работает в контейнере (OpenRC не инициализирован) — запускаем напрямую
rpcbind -w 2>/dev/null || rpcbind || true
sleep 1
rpc.mountd --no-nfs-version 2 2>&1
rpc.nfsd 8 2>&1
exportfs -ra 2>&1
log_success "NFS запущен"

# ========================== Шаг 6: Samba =======================================

log "Шаг 6: Настройка Samba..."

# Вложенный heredoc (<< EOD внутри $(...) внутри << EOF) ненадёжен в busybox sh —
# генерируем секции шар в переменную, затем вставляем в основной heredoc.
shares_config=""
for name in $SHARE_NAMES; do
    mp="/shares/$name"
    mountpoint -q "$mp" 2>/dev/null || continue
    shares_config="${shares_config}
[$name]
path = $mp
browseable = yes
writable = yes
guest ok = ${GUEST_OK}
read only = ${READ_ONLY}
create mask = 0664
directory mask = 0775
force user = ${FORCE_USER}
"
done

cat > /etc/samba/smb.conf << EOF
[global]
workgroup = ${WORKGROUP}
server string = ${SERVER_STRING}
netbios name = ${NETBIOS_NAME}
security = user
map to guest = bad user
dns proxy = no
${shares_config}
EOF

log_debug "Содержимое /etc/samba/smb.conf:"
cat /etc/samba/smb.conf
log_success "Samba настроена"

# ========================== Шаг 7: Запуск сервисов ============================

log "Шаг 7: Запуск Samba..."

smbd --foreground --no-process-group &
SMBD_PID=$!
log_success "smbd запущен (PID: $SMBD_PID)"

nmbd --foreground --no-process-group &
NMBD_PID=$!
log_success "nmbd запущен (PID: $NMBD_PID)"

log_success "========================================="
log_success "=== СЕРВЕР ЗАПУЩЕН ==="
log_success "Шары: $SHARE_NAMES"
log_success "========================================="

# wait сохраняет trap — exec sleep infinity заменил бы процесс и потерял cleanup
wait $SMBD_PID $NMBD_PID

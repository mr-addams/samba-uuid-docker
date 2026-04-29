#!/bin/bash
set -euo pipefail

# ========================== entrypoint module ===================================
#   Entry point for samba-uuid-docker container.
#   Idempotent: re-running inside the same container reuses already-mounted disks
#   and restarts daemons without errors.
#
#   1. Recreates /dev/disk/by-uuid symlinks (udev does not work inside container)
#   2. Verifies that each disk from DISK_<NAME>=<UUID> is not mounted on host
#   3. Mounts disks exclusively, starts Samba + NFS
#   4. On SIGTERM/SIGINT — cleanly unmounts before exit

# ========================== Logging ============================================

log()         { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
log_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERROR: $1" >&2; }
log_success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1"; }
log_debug()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $1"; }

# ========================== Step 1: /dev/disk/by-uuid symlinks ====================

log "=== Samba + NFS on Alpine ==="
log "Step 1: Creating /dev/disk/by-uuid symlinks..."
mkdir -p /dev/disk/by-uuid /dev/disk/by-id

devices_found=0
for dev in /dev/sd* /dev/nvme* /dev/vd* /dev/mmcblk*; do
    [ -b "$dev" ] 2>/dev/null || continue
    devices_found=$((devices_found + 1))
    # || true: blkid returns 2 for devices without UUID; set -e would kill script without this
    uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null) || true
    if [ -n "$uuid" ]; then
        # ln -sf is idempotent: overwrites existing symlink
        ln -sf "$dev" "/dev/disk/by-uuid/$uuid"
        log_success "Symlink: /dev/disk/by-uuid/$uuid → $dev"
    fi
done
log "Block devices found: $devices_found"

# ========================== Step 2: Configuration ================================

log "Step 2: Loading configuration..."
WORKGROUP=${WORKGROUP:-WORKGROUP}
SERVER_STRING=${SERVER_STRING:-"Docker Samba+NFS (Alpine)"}
NETBIOS_NAME=${NETBIOS_NAME:-dockersamba}
GUEST_OK=${GUEST_OK:-yes}
READ_ONLY=${READ_ONLY:-no}
FORCE_USER=${FORCE_USER:-root}

# ========================== Step 3: Parse DISK_* ================================

log "Step 3: Searching for disks in environment variables..."

# Use bash arrays instead of word splitting for reliable name processing.
# Iterate through ${!DISK_@} — substitution of all variables starting with DISK_.
declare -a DISK_UUIDS
declare -a DISK_NAMES
disk_count=0

for var in "${!DISK_@}"; do
    name="${var#DISK_}"  # Remove DISK_ prefix
    uuid="${!var}"       # Indirect expansion: ${!var} = value of variable named $var
    [ -z "$uuid" ] && continue
    disk_count=$((disk_count + 1))
    DISK_UUIDS+=("$uuid")
    DISK_NAMES+=("$name")
    log_success "Disk #$disk_count: $name → UUID $uuid"
done

if [ $disk_count -eq 0 ]; then
    log_error "No DISK_xxx found in environment variables!"
    log_error "Check deploy.env file"
    env | grep -E '^(DISK_|WORKGROUP|SERVER)' || true
    exit 1
fi
log_success "Disks found: $disk_count"

# ========================== Mounting functions ==================================

# Checks if disk with given UUID is mounted anywhere in the system.
# findmnt operates with real paths — resolve symlink before checking.
is_mounted_anywhere() {
    local uuid=$1
    local dev="/dev/disk/by-uuid/$uuid"
    local real_dev
    real_dev=$(readlink -f "$dev" 2>/dev/null) || real_dev="$dev"
    log_debug "Checking mount: UUID=$uuid real=$real_dev"
    if findmnt -rno SOURCE 2>/dev/null | grep -qF "$real_dev"; then
        log_debug "Disk already mounted"
        return 0
    fi
    log_debug "Disk not mounted"
    return 1
}

check_and_mount() {
    local uuid=$1
    local share_name=$2
    local dev="/dev/disk/by-uuid/$uuid"
    local mountpoint="/shares/$share_name"

    log ""
    log "========================================="
    log "Disk: $share_name  UUID: $uuid"
    log "Device: $dev  →  $mountpoint"
    log "========================================="

    if [ ! -e "$dev" ]; then
        log_error "Device $dev does not exist!"
        log_error "Available UUIDs:"
        ls -la /dev/disk/by-uuid/ 2>&1 || true
        return 1
    fi
    log_success "Device exists"

    mkdir -p "$mountpoint"

    # Idempotency: if disk is already mounted at our mount point — reuse it.
    # This is normal during docker compose restart or re-running entrypoint.
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        log_success "Disk $share_name already mounted at $mountpoint — reusing"
        return 0
    fi

    # If mounted elsewhere (on host or different path) — this is an error.
    if is_mounted_anywhere "$uuid"; then
        log_error "Disk $uuid mounted elsewhere — refusing!"
        return 1
    fi
    log_success "Disk not mounted"

    # Determine filesystem type — do not hardcode ext4
    local fs_type
    fs_type=$(blkid -s TYPE -o value "$dev" 2>/dev/null) || true
    if [ -z "$fs_type" ]; then
        log_error "Failed to determine filesystem type for $dev"
        return 1
    fi
    log "Filesystem type: $fs_type"

    # e2fsck only for ext2/3/4
    if [[ "$fs_type" =~ ^ext[234]$ ]]; then
        log "Checking filesystem (e2fsck)..."
        if ! e2fsck -n -f "$dev" >/dev/null 2>&1; then
            log "Errors found → automatic repair..."
            if ! e2fsck -p -f "$dev" 2>&1; then
                log "Auto-repair did not help → interactive mode (-y)..."
                if ! e2fsck -y -f "$dev" 2>&1; then
                    log_error "Failed to repair filesystem!"
                    return 1
                fi
            fi
        else
            log_success "Filesystem is clean"
        fi
    fi

    log "Mounting $dev → $mountpoint (type: $fs_type)..."
    if ! mount -t "$fs_type" -o defaults,noatime,nodiratime "$dev" "$mountpoint" 2>&1; then
        log_error "Mount error!"
        blkid "$dev" 2>&1 || true
        return 1
    fi

    sync
    log_success "Disk $share_name mounted"
    df -h "$mountpoint" 2>&1 || true
}

# ========================== Cleanup: unmounting ================================

cleanup() {
    log ""
    log "========================================="
    log "Stop signal received — unmounting..."
    log "========================================="
    for i in "${!DISK_NAMES[@]}"; do
        name="${DISK_NAMES[$i]}"
        mp="/shares/$name"
        mountpoint -q "$mp" 2>/dev/null || continue
        log "→ Sync + umount $mp..."
        sync
        # Avoid A && B || C antipattern: use explicit if/else.
        # This prevents false errors if log_success unexpectedly fails.
        if umount "$mp" 2>/dev/null; then
            log_success "$name unmounted"
        elif umount -f "$mp" 2>/dev/null; then
            log_success "$name unmounted with -f"
        else
            if umount -l "$mp" 2>/dev/null; then
                log_success "$name: lazy unmount"
            else
                log_error "Failed to unmount $name"
            fi
        fi
    done
    log "Exiting."
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# ========================== Step 4: Mounting ====================================

log ""
log "========================================="
log "MOUNTING DISKS (total: $disk_count)"
log "========================================="

for i in "${!DISK_UUIDS[@]}"; do
    uuid="${DISK_UUIDS[$i]}"
    name="${DISK_NAMES[$i]}"
    log ">>> Disk #$((i + 1)): $name"
    if ! check_and_mount "$uuid" "$name"; then
        log_error "Critical error with disk $name (UUID: $uuid)"
        exit 1
    fi
done

log_success "All disks mounted"

# ========================== Step 5: NFS =========================================

log "Step 5: Configuring and starting NFS..."

# Load kernel module and mount nfsd pseudo-fs (available in privileged container)
modprobe nfsd 2>/dev/null || true
mount -t nfsd nfsd /proc/fs/nfsd 2>/dev/null || true

# Generate /etc/exports without nested heredoc
exports_content=""
for i in "${!DISK_NAMES[@]}"; do
    name="${DISK_NAMES[$i]}"
    mp="/shares/$name"
    mountpoint -q "$mp" 2>/dev/null || continue
    exports_content="${exports_content}${mp} *(rw,sync,no_subtree_check,no_root_squash,insecure)
"
done
printf '%s' "$exports_content" > /etc/exports
log_debug "/etc/exports contents:"
cat /etc/exports

# Idempotency: stop previous instances before restart.
# pkill returns 1 if no processes found — this is normal, || true suppresses error.
pkill -x rpcbind   2>/dev/null || true
pkill rpc.mountd   2>/dev/null || true
pkill rpc.nfsd     2>/dev/null || true
sleep 1

rpcbind -w 2>/dev/null || rpcbind
rpc.mountd --no-nfs-version 2
rpc.nfsd 8
exportfs -ra
log_success "NFS started"

# ========================== Step 6: Samba =======================================

log "Step 6: Configuring Samba..."

# Nested heredoc (<< EOD inside $(...) inside << EOF) is unreliable in busybox sh —
# generate share sections into variable, then insert into main heredoc.
shares_config=""
for i in "${!DISK_NAMES[@]}"; do
    name="${DISK_NAMES[$i]}"
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

log_debug "/etc/samba/smb.conf contents:"
cat /etc/samba/smb.conf
log_success "Samba configured"

# ========================== Step 7: Starting services ==========================

log "Step 7: Starting Samba..."

# Idempotency: stop previous instances before restart.
pkill smbd 2>/dev/null || true
pkill nmbd 2>/dev/null || true
sleep 1

smbd --foreground --no-process-group &
SMBD_PID=$!
log_success "smbd started (PID: $SMBD_PID)"

nmbd --foreground --no-process-group &
NMBD_PID=$!
log_success "nmbd started (PID: $NMBD_PID)"

log_success "========================================="
log_success "=== SERVER STARTED ==="
log_success "Shares: ${DISK_NAMES[*]}"
log_success "========================================="

# ========================== Guard: wait with error handling =====================

# wait with guard logic: if daemon crashes, cleanup runs correctly.
# Without this smbd crash would break unmounting chain on host.
if ! wait $SMBD_PID $NMBD_PID; then
    log_error "One of daemons exited with error. Running cleanup..."
    cleanup
fi

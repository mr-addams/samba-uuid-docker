# samba-uuid-docker

> **[English](#english) | [Русский](#russian)**

---

<a name="english"></a>
# English

## Overview

A Docker container that **exclusively mounts host disks by UUID** and shares them over **Samba (SMB)** and **NFS**. The container checks that each disk is not already mounted on the host before touching it, mounts it inside the container, and exposes it as a named share. On stop, shares are cleanly unmounted before exit.

Built on Alpine Linux 3.21. Includes `smbd`, `nmbd`, NFS kernel server, `e2fsck` for filesystem check/repair, and `duf` / `htop` / `btop` / `mc` for diagnostics inside the container.

---

## How It Works

```
deploy.env                      entrypoint.sh
──────────────                  ─────────────────────────────────────────────────
DISK_ARCHIVE=<uuid>   ──────►  1. Recreate /dev/disk/by-uuid symlinks (udev
DISK_MEDIA=<uuid>              does not run inside the container)
                               2. Verify each disk is NOT mounted on the host
                               3. Detect filesystem type (ext2/3/4, xfs, …)
                               4. e2fsck check/repair for ext* filesystems
                               5. mount -t <fstype> /dev/disk/by-uuid/<uuid>
                                         → /shares/<NAME>
                               6. Write /etc/exports, start rpcbind + NFS daemons
                               7. Write /etc/samba/smb.conf, start smbd + nmbd
                               8. wait — keep running, trap SIGTERM → umount all
```

The container uses `privileged: true` and maps `/dev` from the host so it can see and mount raw block devices. The host OS never mounts these disks — the container owns them exclusively.

---

## Requirements

| Requirement | Details |
|---|---|
| Docker Engine | 20.10+ |
| Docker Compose | v2 plugin (`docker compose`) |
| Host kernel | NFS kernel server support (`nfsd` module) |
| Disks | Must be **unmounted** on the host at container start |
| Filesystem | ext2 / ext3 / ext4 / xfs / btrfs / vfat — anything `blkid` can detect |

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/mr-addams/samba-uuid-docker.git
cd samba-uuid-docker
```

### 2. Find your disk UUIDs

```bash
# List block devices with UUIDs
lsblk -o NAME,UUID,FSTYPE,SIZE,MOUNTPOINT

# Or use blkid (requires root)
sudo blkid
```

Example output:
```
/dev/sdb1: UUID="36e7b6c6-525d-4d7d-bb1d-873615faa1c7" TYPE="ext4"
/dev/sdc1: UUID="a1b2c3d4-e5f6-7890-abcd-ef1234567890" TYPE="xfs"
```

### 3. Configure `deploy.env`

```bash
# === Disks: DISK_ShareName=UUID ===
DISK_ARCHIVE=36e7b6c6-525d-4d7d-bb1d-873615faa1c7
DISK_MEDIA=a1b2c3d4-e5f6-7890-abcd-ef1234567890

# Samba settings
WORKGROUP=WORKGROUP
SERVER_STRING=Docker Samba+NFS (Alpine)
NETBIOS_NAME=dockersamba
GUEST_OK=yes
READ_ONLY=no
FORCE_USER=root
```

> **Important:** The part after `DISK_` becomes the share name — both the Samba share name and the NFS export path. Use only alphanumeric characters and underscores.

### 4. Make sure disks are unmounted on the host

```bash
# Verify no mount points for your UUIDs
findmnt -o SOURCE,TARGET | grep sd
```

The container will **refuse to start** if it detects that a disk is already mounted.

### 5. Build and run

```bash
docker compose up --build
```

Or in detached mode:

```bash
docker compose up --build -d
docker compose logs -f
```

---

## Connecting to Shares

### Samba (SMB/CIFS)

```bash
# List available shares
smbclient -L //SERVER_IP -N

# Mount on Linux
sudo mount -t cifs //SERVER_IP/ARCHIVE /mnt/archive -o guest,vers=3.0

# Mount on macOS
# Finder → Go → Connect to Server → smb://SERVER_IP/ARCHIVE

# Mount on Windows
# File Explorer → \\SERVER_IP\ARCHIVE
```

### NFS

```bash
# Show exports
showmount -e SERVER_IP

# Mount on Linux
sudo mount -t nfs SERVER_IP:/shares/ARCHIVE /mnt/archive

# Or via /etc/fstab for persistent mount
SERVER_IP:/shares/ARCHIVE  /mnt/archive  nfs  defaults,_netdev  0  0
```

---

## Configuration Reference

### `deploy.env`

#### Disk variables

| Variable | Format | Description |
|---|---|---|
| `DISK_<NAME>` | `DISK_ARCHIVE=<uuid>` | Disk to mount. `<NAME>` becomes the share name. Multiple disks allowed. |

#### Samba variables

| Variable | Default | Description |
|---|---|---|
| `WORKGROUP` | `WORKGROUP` | Windows workgroup / domain name |
| `SERVER_STRING` | `Docker Samba+NFS (Alpine)` | Server description visible in network browsers |
| `NETBIOS_NAME` | `dockersamba` | NetBIOS hostname (visible in Windows Network) |
| `GUEST_OK` | `yes` | Allow access without a password (`yes` / `no`) |
| `READ_ONLY` | `no` | Mount shares read-only (`yes` / `no`) |
| `FORCE_USER` | `root` | All file operations run as this OS user |

### `docker-compose.yml`

The container requires:
- `privileged: true` — needed to `mount` block devices and load kernel modules
- `devices: - /dev:/dev` — exposes host block devices inside the container

### Ports

| Port | Protocol | Service |
|---|---|---|
| 445 | TCP | Samba (SMB/CIFS) |
| 139 | TCP | Samba (NetBIOS session) |
| 2049 | TCP/UDP | NFS |
| 111 | TCP/UDP | rpcbind (NFS portmapper) |

---

## Startup Sequence (entrypoint.sh)

| Step | Action |
|---|---|
| 1 | Recreate `/dev/disk/by-uuid` symlinks — udev is absent inside the container |
| 2 | Read `DISK_*` variables from environment |
| 3 | For each disk: verify device exists, verify not mounted on host |
| 4 | Detect filesystem type via `blkid` |
| 5 | Run `e2fsck` check + auto-repair for ext2/3/4 filesystems |
| 6 | `mount -t <fstype>` the disk to `/shares/<NAME>` |
| 7 | Load `nfsd` kernel module, start `rpcbind`, `rpc.mountd`, `rpc.nfsd` |
| 8 | Generate `/etc/exports` and run `exportfs -ra` |
| 9 | Generate `/etc/samba/smb.conf` |
| 10 | Start `smbd` and `nmbd` in foreground |
| 11 | `wait` — container stays alive; `SIGTERM` triggers clean umount of all shares |

---

## Graceful Shutdown

```bash
docker compose stop
# or
docker compose down
```

On `SIGTERM`, the container:
1. Calls `sync` to flush all write buffers
2. Unmounts each share (`umount` → `-f` → `-l` fallback)
3. Exits cleanly

This prevents filesystem corruption when you stop the container.

---

## Troubleshooting

### Container exits immediately

Check the logs:
```bash
docker compose logs samba-nfs
```

Common causes:
- **No `DISK_*` variables defined** in `deploy.env`
- **UUID not found** — verify with `sudo blkid` on the host
- **Disk already mounted** on the host — unmount it first

### Disk not found inside container

The container recreates UUID symlinks by scanning `/dev/sd*`, `/dev/nvme*`, `/dev/vd*`, `/dev/mmcblk*`. If your device uses a different naming pattern, it will not be detected.

Check available block devices inside the running container:
```bash
docker exec -it samba-nfs-exclusive lsblk
docker exec -it samba-nfs-exclusive ls -la /dev/disk/by-uuid/
```

### Filesystem errors at mount

`e2fsck` is run automatically for ext2/3/4 filesystems. For XFS, run `xfs_repair` manually before starting the container:
```bash
sudo xfs_repair /dev/disk/by-uuid/<uuid>
```

### NFS mount hangs or fails

The host kernel must have NFS server support. Check:
```bash
lsmod | grep nfsd
# If empty:
sudo modprobe nfsd
```

NFS v2 is disabled intentionally (`--no-nfs-version 2`). Use NFS v3 or v4.

### Samba: "Access denied" or not visible on network

- Ensure port 445 is reachable (check firewall: `ufw allow 445/tcp`)
- With `GUEST_OK=yes`, no username/password is required — use `guest` or leave blank
- On Linux clients, specify `vers=3.0` in the mount options

---

## ⚠ Internal Use — No Authentication

**This container is designed for trusted home / internal networks only.**

With the default configuration (`GUEST_OK=yes`, `READ_ONLY=no`):
- No username or password is required for Samba access
- Any client that can reach port 445 can **read and write** all shared data
- NFS is exported with `no_root_squash` and `insecure` — any client can access files as root

Do not expose this container to the internet or any untrusted network segment.

### Guest access compatibility by OS

#### Linux
Works out of the box. Use `-o guest` or omit credentials:
```bash
sudo mount -t cifs //SERVER_IP/SHARE /mnt/share -o guest,vers=3.0
```

#### macOS (10.15 Catalina and later)
Works. In Finder: **Go → Connect to Server → `smb://SERVER_IP/SHARE`**, then click **Guest** in the authentication dialog.

#### Windows 7 / 8 / 8.1 / 10 before version 1709
Works out of the box. No additional configuration needed.

#### Windows 10 (version 1709+) and Windows 11
**Guest access is blocked by default.** Microsoft disabled unauthenticated SMB guest connections as a security measure. Attempting to connect will show:

> *"You can't access this shared folder because your organization's security policies block unauthenticated guest access."*

**Fix — option A: Registry (per machine, one-time)**

Open `regedit` and set:
```
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters
  AllowInsecureGuestAuth = 1  (DWORD)
```

Or run in an elevated PowerShell:
```powershell
Set-ItemProperty `
  -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" `
  -Name "AllowInsecureGuestAuth" -Value 1 -Type DWord
```

Reboot or restart the `Workstation` service:
```powershell
Restart-Service LanmanWorkstation -Force
```

**Fix — option B: Group Policy (domain environments)**

*Computer Configuration → Administrative Templates → Network → Lanman Workstation →
Enable insecure guest logons* → **Enabled**

After applying either fix, Windows will connect to guest shares normally.

### Other security notes

- The container runs in `privileged` mode — it has full access to host devices. Use in trusted environments only.
- NFS is exported with `no_root_squash` — restrict the export to specific IPs if needed by editing the `/etc/exports` generation in `entrypoint.sh`.

---

## Installed Tools

| Tool | Purpose |
|---|---|
| `smbd`, `nmbd` | Samba file sharing daemon |
| `rpc.nfsd`, `rpc.mountd`, `rpcbind` | NFS server daemons |
| `e2fsck` | ext2/3/4 filesystem check and repair |
| `blkid` | Filesystem type and UUID detection |
| `findmnt` | Mount detection (guards against double-mount) |
| `duf` | Disk usage overview |
| `htop`, `btop` | Process and resource monitoring |
| `mc` | Midnight Commander file manager |

---

<a name="russian"></a>
# Русский

## Обзор

Docker-контейнер, который **эксклюзивно захватывает диски хоста по UUID** и раздаёт их по **Samba (SMB)** и **NFS**. Перед монтированием контейнер проверяет, что диск не смонтирован на хосте. При остановке контейнера все шары корректно размонтируются.

Основан на Alpine Linux 3.21. Включает `smbd`, `nmbd`, NFS-сервер ядра, `e2fsck` для проверки и ремонта ФС, а также `duf` / `htop` / `btop` / `mc` для диагностики внутри контейнера.

---

## Как это работает

```
deploy.env                      entrypoint.sh
──────────────                  ─────────────────────────────────────────────────
DISK_ARCHIVE=<uuid>   ──────►  1. Воссоздаём симлинки /dev/disk/by-uuid
DISK_MEDIA=<uuid>              (udev внутри контейнера не работает)
                               2. Проверяем, что диск НЕ смонтирован на хосте
                               3. Определяем тип ФС через blkid
                               4. e2fsck для ext* файловых систем
                               5. mount -t <тип> /dev/disk/by-uuid/<uuid>
                                         → /shares/<ИМЯ>
                               6. Записываем /etc/exports, запускаем NFS
                               7. Записываем /etc/samba/smb.conf, запускаем smbd
                               8. wait — ждём SIGTERM → корректный umount
```

Контейнер использует `privileged: true` и монтирует `/dev` с хоста, чтобы видеть блочные устройства. Хостовая ОС эти диски **не монтирует** — контейнер владеет ими эксклюзивно.

---

## Требования

| Требование | Детали |
|---|---|
| Docker Engine | 20.10+ |
| Docker Compose | v2 плагин (`docker compose`) |
| Ядро хоста | Поддержка NFS-сервера (модуль `nfsd`) |
| Диски | Должны быть **размонтированы** на хосте при старте контейнера |
| Файловая система | ext2 / ext3 / ext4 / xfs / btrfs / vfat — всё, что определяет `blkid` |

---

## Быстрый старт

### 1. Клонировать репозиторий

```bash
git clone https://github.com/mr-addams/samba-uuid-docker.git
cd samba-uuid-docker
```

### 2. Найти UUID дисков

```bash
# Список блочных устройств с UUID
lsblk -o NAME,UUID,FSTYPE,SIZE,MOUNTPOINT

# Или через blkid (нужны права root)
sudo blkid
```

Пример вывода:
```
/dev/sdb1: UUID="36e7b6c6-525d-4d7d-bb1d-873615faa1c7" TYPE="ext4"
/dev/sdc1: UUID="a1b2c3d4-e5f6-7890-abcd-ef1234567890" TYPE="xfs"
```

### 3. Настроить `deploy.env`

```bash
# === Диски: DISK_ИмяШары=UUID ===
DISK_ARCHIVE=36e7b6c6-525d-4d7d-bb1d-873615faa1c7
DISK_MEDIA=a1b2c3d4-e5f6-7890-abcd-ef1234567890

# Настройки Samba
WORKGROUP=WORKGROUP
SERVER_STRING=Docker Samba+NFS (Alpine)
NETBIOS_NAME=dockersamba
GUEST_OK=yes
READ_ONLY=no
FORCE_USER=root
```

> **Важно:** часть после `DISK_` становится именем шары — и в Samba, и в NFS-экспорте. Используйте только латинские буквы, цифры и подчёркивания.

### 4. Убедиться, что диски не смонтированы на хосте

```bash
# Проверить точки монтирования
findmnt -o SOURCE,TARGET | grep sd
```

Контейнер **откажет в запуске**, если обнаружит уже смонтированный диск.

### 5. Собрать и запустить

```bash
docker compose up --build
```

Или в фоновом режиме:

```bash
docker compose up --build -d
docker compose logs -f
```

---

## Подключение к шарам

### Samba (SMB/CIFS)

```bash
# Список доступных шар
smbclient -L //IP_СЕРВЕРА -N

# Монтирование на Linux
sudo mount -t cifs //IP_СЕРВЕРА/ARCHIVE /mnt/archive -o guest,vers=3.0

# macOS
# Finder → Переход → Подключение к серверу → smb://IP_СЕРВЕРА/ARCHIVE

# Windows
# Проводник → \\IP_СЕРВЕРА\ARCHIVE
```

### NFS

```bash
# Показать экспорты
showmount -e IP_СЕРВЕРА

# Монтирование на Linux
sudo mount -t nfs IP_СЕРВЕРА:/shares/ARCHIVE /mnt/archive

# Постоянное монтирование через /etc/fstab
IP_СЕРВЕРА:/shares/ARCHIVE  /mnt/archive  nfs  defaults,_netdev  0  0
```

---

## Справка по конфигурации

### `deploy.env`

#### Переменные дисков

| Переменная | Формат | Описание |
|---|---|---|
| `DISK_<ИМЯ>` | `DISK_ARCHIVE=<uuid>` | Диск для монтирования. `<ИМЯ>` становится именем шары. Можно задать несколько. |

#### Переменные Samba

| Переменная | По умолчанию | Описание |
|---|---|---|
| `WORKGROUP` | `WORKGROUP` | Имя рабочей группы / домена Windows |
| `SERVER_STRING` | `Docker Samba+NFS (Alpine)` | Описание сервера в сетевом окружении |
| `NETBIOS_NAME` | `dockersamba` | NetBIOS-имя (видно в «Сеть» Windows) |
| `GUEST_OK` | `yes` | Разрешить доступ без пароля (`yes` / `no`) |
| `READ_ONLY` | `no` | Только чтение (`yes` / `no`) |
| `FORCE_USER` | `root` | Все файловые операции выполняются от этого пользователя ОС |

### `docker-compose.yml`

Контейнеру необходимо:
- `privileged: true` — для монтирования блочных устройств и загрузки модулей ядра
- `devices: - /dev:/dev` — экспортирует блочные устройства хоста внутрь контейнера

### Порты

| Порт | Протокол | Сервис |
|---|---|---|
| 445 | TCP | Samba (SMB/CIFS) |
| 139 | TCP | Samba (NetBIOS-сессия) |
| 2049 | TCP/UDP | NFS |
| 111 | TCP/UDP | rpcbind (NFS portmapper) |

---

## Последовательность запуска (entrypoint.sh)

| Шаг | Действие |
|---|---|
| 1 | Воссоздать симлинки `/dev/disk/by-uuid` — udev внутри контейнера отсутствует |
| 2 | Прочитать переменные `DISK_*` из окружения |
| 3 | Для каждого диска: проверить существование устройства и отсутствие монтирования на хосте |
| 4 | Определить тип ФС через `blkid` |
| 5 | `e2fsck` проверка + авторемонт для ext2/3/4 |
| 6 | `mount -t <тип>` диска в `/shares/<ИМЯ>` |
| 7 | Загрузить модуль `nfsd`, запустить `rpcbind`, `rpc.mountd`, `rpc.nfsd` |
| 8 | Сгенерировать `/etc/exports`, применить `exportfs -ra` |
| 9 | Сгенерировать `/etc/samba/smb.conf` |
| 10 | Запустить `smbd` и `nmbd` в foreground-режиме |
| 11 | `wait` — контейнер держится живым; `SIGTERM` запускает корректный umount всех шар |

---

## Корректная остановка

```bash
docker compose stop
# или
docker compose down
```

При получении `SIGTERM` контейнер:
1. Вызывает `sync` — сбрасывает буферы записи
2. Размонтирует каждую шару (`umount` → `-f` → `-l` как fallback)
3. Завершается чисто

Это предотвращает повреждение файловой системы при остановке контейнера.

---

## Устранение неполадок

### Контейнер сразу завершается

Смотрите логи:
```bash
docker compose logs samba-nfs
```

Частые причины:
- **Нет переменных `DISK_*`** в `deploy.env`
- **UUID не найден** — проверьте через `sudo blkid` на хосте
- **Диск уже смонтирован** на хосте — размонтируйте его перед запуском

### Диск не виден внутри контейнера

Контейнер воссоздаёт симлинки по UUID, сканируя `/dev/sd*`, `/dev/nvme*`, `/dev/vd*`, `/dev/mmcblk*`. Если устройство называется иначе — оно не будет обнаружено.

Проверьте изнутри работающего контейнера:
```bash
docker exec -it samba-nfs-exclusive lsblk
docker exec -it samba-nfs-exclusive ls -la /dev/disk/by-uuid/
```

### Ошибки файловой системы при монтировании

`e2fsck` запускается автоматически для ext2/3/4. Для XFS запустите `xfs_repair` вручную до старта контейнера:
```bash
sudo xfs_repair /dev/disk/by-uuid/<uuid>
```

### NFS зависает или не монтируется

Ядро хоста должно поддерживать NFS-сервер. Проверьте:
```bash
lsmod | grep nfsd
# Если пусто:
sudo modprobe nfsd
```

NFS v2 отключён намеренно (`--no-nfs-version 2`). Используйте NFS v3 или v4.

### Samba: «Отказано в доступе» или шары не видны в сети

- Убедитесь, что порт 445 доступен (брандмауэр: `ufw allow 445/tcp`)
- При `GUEST_OK=yes` логин и пароль не нужны — оставьте поля пустыми или введите `guest`
- На Linux-клиентах указывайте `vers=3.0` в опциях монтирования

---

## ⚠ Только для внутреннего использования — без авторизации

**Контейнер рассчитан исключительно на доверенные домашние / внутренние сети.**

При конфигурации по умолчанию (`GUEST_OK=yes`, `READ_ONLY=no`):
- Имя пользователя и пароль для доступа к Samba **не требуются**
- Любой клиент, достигающий порта 445, может **читать и писать** на все шары
- NFS экспортируется с `no_root_squash` и `insecure` — клиент может работать с файлами с правами root

Не открывайте этот контейнер в интернет или в любой недоверенной сети.

### Совместимость гостевого доступа по ОС

#### Linux
Работает из коробки. Указывайте `-o guest` или просто не передавайте учётные данные:
```bash
sudo mount -t cifs //IP_СЕРВЕРА/ШАРА /mnt/share -o guest,vers=3.0
```

#### macOS (10.15 Catalina и новее)
Работает. В Finder: **Переход → Подключение к серверу → `smb://IP_СЕРВЕРА/ШАРА`**, затем нажать **Гость** в диалоге аутентификации.

#### Windows 7 / 8 / 8.1 / 10 до версии 1709
Работает из коробки. Дополнительная настройка не нужна.

#### Windows 10 (версия 1709+) и Windows 11
**Гостевой доступ заблокирован по умолчанию.** Microsoft отключила анонимные SMB-подключения в качестве меры безопасности. При попытке подключиться появляется ошибка:

> *«Не удаётся получить доступ к общей папке, так как политики безопасности вашей организации блокируют анонимный гостевой доступ.»*

**Решение — вариант A: Реестр (разово на машину)**

Открыть `regedit` и установить:
```
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters
  AllowInsecureGuestAuth = 1  (DWORD)
```

Или выполнить в PowerShell с правами администратора:
```powershell
Set-ItemProperty `
  -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" `
  -Name "AllowInsecureGuestAuth" -Value 1 -Type DWord
```

Перезагрузить ПК или перезапустить службу `Workstation`:
```powershell
Restart-Service LanmanWorkstation -Force
```

**Решение — вариант B: Групповая политика (доменная среда)**

*Конфигурация компьютера → Административные шаблоны → Сеть → Рабочая станция Lanman →
Включить небезопасные гостевые входы* → **Включено**

После применения любого из вариантов Windows будет подключаться к гостевым шарам без ошибок.

### Прочие замечания

- Контейнер работает в режиме `privileged` — у него полный доступ к устройствам хоста. Используйте только в доверенном окружении.
- NFS экспортируется с `no_root_squash` — ограничьте экспорт конкретными IP при необходимости (отредактируйте генерацию `/etc/exports` в `entrypoint.sh`).

---

## Установленные утилиты

| Утилита | Назначение |
|---|---|
| `smbd`, `nmbd` | Демон файлового шаринга Samba |
| `rpc.nfsd`, `rpc.mountd`, `rpcbind` | Демоны NFS-сервера |
| `e2fsck` | Проверка и ремонт ext2/3/4 |
| `blkid` | Определение типа ФС и UUID |
| `findmnt` | Проверка монтирования (защита от двойного mount) |
| `duf` | Обзор использования дисков |
| `htop`, `btop` | Мониторинг процессов и ресурсов |
| `mc` | Файловый менеджер Midnight Commander |

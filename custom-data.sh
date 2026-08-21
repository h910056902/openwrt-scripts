#!/bin/sh /etc/rc.common
# ============================================================
#  Custom data partition manager (v2.2 ASCII)
#  Auto create partition + fstab persistence + mount
# ============================================================

START=90
STOP=15

# ---------- Config ----------
DISK="/dev/mmcblk0"
MOUNT_POINT="/data"
FS_TYPE="f2fs"
MIN_SIZE_MB=1000
LABEL="data"

partition_exists() {
  [ -b "$DATA_PART" ]
}

is_mounted() {
  mount | grep -q " $MOUNT_POINT "
}

# Resolve target partition by label/uuid (no hardcoded p7)
resolve_data_part() {
  # 1. by label
  DATA_PART=$(blkid -t LABEL="$LABEL" -o device 2>/dev/null | head -1)
  [ -n "$DATA_PART" ] && return 0
  # 2. by fstab uuid
  uuid_val=$(uci -q get fstab.@mount[0].uuid 2>/dev/null)
  if [ -n "$uuid_val" ]; then
    DATA_PART=$(blkid -U "$uuid_val" 2>/dev/null | head -1)
    [ -n "$DATA_PART" ] && return 0
  fi
  # 3. fallback p7 (only if exists)
  if [ -b /dev/mmcblk0p7 ]; then
    DATA_PART="/dev/mmcblk0p7"
    return 0
  fi
  DATA_PART=""
  return 1
}

start() {
  echo "Data partition manager: checking..."

  # === 0. Resolve target partition ===
  resolve_data_part

  # === 1. Create partition if not exists ===
  if ! partition_exists; then
    echo "  Partition not found, checking free space..."
    DISK_TOTAL=$(cat /sys/block/$(basename $DISK)/size 2>/dev/null)
    [ -z "$DISK_TOTAL" ] && { echo "  [ERROR] Cannot read disk"; return 1; }

    LAST_END=$(fdisk -l "$DISK" 2>/dev/null | awk "/^\\/dev\/mmcblk0p[0-9]+/{end=\$3} END{print end}")
    [ -z "$LAST_END" ] && { echo "  [ERROR] Cannot read partition table"; return 1; }

    FREE_MB=$(( (DISK_TOTAL - LAST_END - 1) / 2048 ))
    if [ "$FREE_MB" -lt "$MIN_SIZE_MB" ]; then
      echo "  [SKIP] Not enough space: $FREE_MB MB < $MIN_SIZE_MB MB"; return 0;
    fi
    echo "  Free space: $FREE_MB MB, creating partition..."

    LAST_PART=$(fdisk -l "$DISK" 2>/dev/null | grep -oE "mmcblk0p[0-9]+" | grep -oE "[0-9]+$" | sort -n | tail -1)
    NEW_PART=$((LAST_PART + 1))
    DATA_PART="/dev/mmcblk0p${NEW_PART}"

    if ! printf "n\n%s\n%s\n\nw\n" "$NEW_PART" "$((LAST_END+1))" | fdisk "$DISK" >/dev/null 2>&1; then
      echo "  [ERROR] fdisk failed"; return 1;
    fi
    sleep 3
    block detect >/dev/null 2>&1 || true
    [ -b "$DATA_PART" ] || { echo "  [ERROR] Partition create failed"; return 1; }

    echo "  Formatting ${FS_TYPE}..."
    if ! mkfs.$FS_TYPE -f -l "$LABEL" "$DATA_PART" >/dev/null 2>&1; then
      echo "  [WARN] ${FS_TYPE} format failed, try ext4...";
      FS_TYPE="ext4";
      mkfs.ext4 -F -L "$LABEL" "$DATA_PART" >/dev/null 2>&1 || { echo "  [ERROR] Format failed"; return 1; }
    fi
  else
    DETECTED_FS=$(blkid -o value -s TYPE "$DATA_PART" 2>/dev/null)
    [ -n "$DETECTED_FS" ] && FS_TYPE="$DETECTED_FS";
  fi

  # === 2. Ensure fstab persistence (only manage own entry) ===
  UUID=$(blkid -o value -s UUID "$DATA_PART" 2>/dev/null)
  if [ -n "$UUID" ]; then
    DELETE_AGAIN=1
    while [ "$DELETE_AGAIN" = "1" ]; do
      DELETE_AGAIN=0
      IDX=0
      while uci -q get fstab.@mount[$IDX] >/dev/null 2>&1; do
        CUR_TARGET=$(uci -q get fstab.@mount[$IDX].target 2>/dev/null)
        if [ "$CUR_TARGET" = "$MOUNT_POINT" ]; then
          uci -q delete fstab.@mount[$IDX]
          uci -q commit fstab
          DELETE_AGAIN=1
          break
        fi
        IDX=$((IDX + 1))
      done
    done
    uci -q add fstab mount
    uci -q set fstab.@mount[-1].target="$MOUNT_POINT"
    uci -q set fstab.@mount[-1].uuid="$UUID"
    uci -q set fstab.@mount[-1].fstype="$FS_TYPE"
    uci -q set fstab.@mount[-1].enabled="1"
    uci -q commit fstab
    echo "  fstab updated (UUID: $UUID)"
  else
    echo "  [WARN] No UUID found, fstab not updated"
  fi

  # === 3. Mount ===
  if is_mounted; then
    SIZE=$(df -h "$MOUNT_POINT" 2>/dev/null | awk "NR==2{print \$2}")
    [ -n "$SIZE" ] && echo "  [OK] $MOUNT_POINT mounted ($SIZE)" || echo "  [OK] $MOUNT_POINT mounted"
  else
    mkdir -p "$MOUNT_POINT"
    if ! mount -t "$FS_TYPE" "$DATA_PART" "$MOUNT_POINT" 2>/dev/null; then
      echo "  [WARN] Direct mount failed, try block mount...";
      block mount >/dev/null 2>&1;
    fi
    if is_mounted; then
      echo "  [OK] $MOUNT_POINT mounted";
    else
      echo "  [ERROR] Mount failed, check manually";
    fi
  fi
}

stop() {
  umount -l "$MOUNT_POINT" 2>/dev/null || true
}

restart() {
  stop; sleep 1; start;
}
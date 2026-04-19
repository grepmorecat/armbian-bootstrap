#!/bin/bash
set -euo pipefail

INPUT_IMG=""
OUTPUT_IMG=""
BOOTSTRAP_FILE=""
PROVISION_FILE=""

MNT="./mnt"
ROOT_MNT="$MNT/root"

LOOPDEV=""
ROOT_PART=""

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

cleanup() {
  set +e
  log "Cleaning up..."
  sync
  umount "$ROOT_MNT" 2>/dev/null
  if [[ -n "${LOOPDEV:-}" ]]; then
    losetup -d "$LOOPDEV"
  fi
}
trap cleanup EXIT

# --- root check ---
[[ "$EUID" -ne 0 ]] && die "Run as root (use sudo)"

# --- argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)      INPUT_IMG="$2"; shift 2 ;;
    -o|--output)     OUTPUT_IMG="$2"; shift 2 ;;
    -b|--bootstrap)  BOOTSTRAP_FILE="$2"; shift 2 ;;
    -p|--provision)  PROVISION_FILE="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# --- required args ---
[[ -z "$INPUT_IMG" ]] && die "Input image required (-i)"
[[ -z "$OUTPUT_IMG" ]] && die "Output image required (-o)"
[[ ! -f "$INPUT_IMG" ]] && die "Input image does not exist"

mkdir -p "$ROOT_MNT"

# --- pre-flight validation ---
log "Attaching input image for inspection..."
TMP_LOOP=$(losetup -fP --show "$INPUT_IMG")

log "Detected partition layout:"
lsblk -o NAME,SIZE,TYPE,FSTYPE "$TMP_LOOP" || true

# collect partitions
PARTS=($(lsblk -nr -o NAME "$TMP_LOOP" | tail -n +2))

[[ ${#PARTS[@]} -eq 0 ]] && die "No partitions found"

log "Probing partitions to find root filesystem..."

for part in "${PARTS[@]}"; do
  DEV="/dev/$part"
  log "Checking $DEV..."

  mkdir -p "$ROOT_MNT"
  if mount -o ro "$DEV" "$ROOT_MNT" 2>/dev/null; then
    if [[ -d "$ROOT_MNT/etc" && -d "$ROOT_MNT/usr" ]]; then
      log "Found root filesystem at $DEV"
      ROOT_PART="$DEV"
      umount "$ROOT_MNT"
      break
    fi
    umount "$ROOT_MNT"
  fi
done

losetup -d "$TMP_LOOP"

[[ -z "$ROOT_PART" ]] && die "Could not detect root filesystem"

log "Validation passed (root at $ROOT_PART)"

# --- copy image ---
log "Copying image..."
cp "$INPUT_IMG" "$OUTPUT_IMG"

# --- attach output image ---
log "Attaching output image..."
LOOPDEV=$(losetup -fP --show "$OUTPUT_IMG")
sleep 1

# remap ROOT_PART to new loop device
ROOT_PART="${LOOPDEV}p${ROOT_PART##*p}"

# --- mount ---
log "Mounting root filesystem..."
mount "$ROOT_PART" "$ROOT_MNT"

# --- inject files ---
if [[ -n "$BOOTSTRAP_FILE" ]]; then
  log "Injecting bootstrap file..."
  cp "$BOOTSTRAP_FILE" "$ROOT_MNT/root/.not_logged_in_yet"
fi

if [[ -n "$PROVISION_FILE" ]]; then
  log "Injecting provisioning script..."
  cp "$PROVISION_FILE" "$ROOT_MNT/root/provisioning.sh"
  chmod +x "$ROOT_MNT/root/provisioning.sh"
fi

# --- flush ---
log "Syncing writes..."
sync

log "Done successfully"
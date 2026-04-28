#!/usr/bin/env bash
# Multi-layer recovery for alioth.
# Usage: recover.sh [--auto-stock] [--reason "what happened"]
# Without --auto-stock: tries to switch active slot to _a only.
# With --auto-stock: also re-flashes original stock images from workspace/stock-images/ if both slots look bad.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STOCK="$ROOT/workspace/stock-images"
LOG="$ROOT/runs/recovery-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$ROOT/runs"

auto_stock=0
reason="(unspecified)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-stock) auto_stock=1; shift;;
    --reason) reason="$2"; shift 2;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done

log() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }

log "=== recovery start (reason: $reason) ==="

# Layer A: device is in adb / android
if adb devices | grep -qE "device$"; then
  log "device reachable via adb; rebooting to bootloader"
  adb reboot bootloader || true
  sleep 5
fi

# Wait for fastboot
deadline=$((SECONDS+120))
while ! fastboot devices | grep -q .; do
  if (( SECONDS > deadline )); then
    log "FATAL: device not in fastboot after 120s — escalate to user (L5)"
    echo "ESCALATE_USER" > "$ROOT/runs/RECOVERY_ESCALATED"
    exit 3
  fi
  sleep 2
done
log "device in fastboot"

# Virtual A/B device — slot _b is not standalone. Recovery is just re-flash
# stock boot_a. Always do this on Layer B (no point in slot-switching).
if [[ ! -f "$STOCK/boot_a-original.img" ]]; then
  log "FATAL: stock backup missing at $STOCK; cannot recover"
  exit 4
fi
log "re-flashing stock boot_a (research kernel may have broken — restoring stock)"
fastboot flash boot_a "$STOCK/boot_a-original.img" 2>&1 | tee -a "$LOG"
if (( auto_stock )); then
  if [[ -f "$STOCK/dtbo_a-original.img" ]]; then
    fastboot flash dtbo_a "$STOCK/dtbo_a-original.img" 2>&1 | tee -a "$LOG"
  fi
fi
log "ensuring active slot is a"
fastboot --set-active=a 2>&1 | tee -a "$LOG"

log "rebooting"
fastboot reboot 2>&1 | tee -a "$LOG"

# Wait for adb back
deadline=$((SECONDS+180))
while ! adb devices | grep -qE "device$"; do
  if (( SECONDS > deadline )); then
    log "FATAL: device did not return to adb in 180s after recovery"
    echo "ESCALATE_USER" > "$ROOT/runs/RECOVERY_ESCALATED"
    exit 5
  fi
  sleep 3
done

log "=== recovery complete; device on slot a ==="

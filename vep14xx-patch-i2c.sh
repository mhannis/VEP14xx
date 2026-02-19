#!/bin/bash
set -euo pipefail
log() { echo "[$(date +'%F %T')] $*" >&2; }

detect_tc654_bus() {
  log "[1/3] Detecting which I2C bus has TC654 (0x1b)..."

  if ! compgen -G "/dev/i2c-*" >/dev/null; then
    log "No /dev/i2c-* nodes found yet; trying to load i2c host drivers..."
    modprobe i2c-i801 2>/dev/null || true
    modprobe i2c-ismt 2>/dev/null || true
    modprobe i2c-dev  2>/dev/null || true
  fi

  local bus=""
  for dev in /dev/i2c-*; do
    [[ -e "$dev" ]] || continue
    local n="${dev#/dev/i2c-}"
    if i2cdetect -y "$n" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(tolower($i)=="1b") f=1} END{exit !f}'; then
      bus="$n"
      break
    fi
  done

  if [[ -z "$bus" ]]; then
    echo "ERROR: Could not find TC654 (0x1b) on any /dev/i2c-* bus" >&2
    i2cdetect -l >&2 || true
    exit 1
  fi

  echo "$bus"
}

patch_xml_bus() {
  local BUS="$1"
  local files=(
  "/etc/dn/diag/default_fan_list.xml"
  "/etc/dn/diag/default_temp_sensors.xml"
  "/etc/dn/diag/default_led_list.xml"
  "/etc/dn/diag/default_pl_list.xml"
  )

  for f in "${files[@]}"; do
    log "[2/3] Patching ${f} to use /dev/i2c-${BUS}..."
    if [[ ! -f "$f" ]]; then
      log "File ${f} not found. Skipping patch".
    else
      sed -i -E "s#/dev/i2c-[0-9]+#/dev/i2c-${BUS}#g" "$f"
      log "Patched ${f} successfully."
    fi
  done
}

final_checks() {
  log "[3/3] Running quick checks..."

  export PATH="/opt/dellemc/diag/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  echo "Fan speeds:"
  /opt/dellemc/diag/bin/fantool --get --fan=all || true
  echo "Leds:"
  /opt/dellemc/diag/bin/ledtool --get || true
}

main() {
  BUS="$(detect_tc654_bus)"
  log "Detected TC654 on i2c-${BUS}"
  patch_xml_bus "$BUS"
  final_checks
}

main "$@"
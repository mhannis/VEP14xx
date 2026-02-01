#!/bin/bash
set -euo pipefail

DEB_DEFAULT="/root/dn-diags-VEP1400-DiagOS-3.43.4.81-26-2022-12-08.deb"
DEB="${1:-$DEB_DEFAULT}"

log() { echo "[$(date +'%F %T')] $*" >&2; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run as root" >&2
    exit 1
  fi
}

backup_apt_sources() {
  mkdir -p /root/apt-backup
  for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
    if [[ -f "$f" ]]; then
      log "Moving $f -> /root/apt-backup/"
      mv -f "$f" /root/apt-backup/
    fi
  done
}

ensure_no_subscription_repo() {
  cat >/etc/apt/sources.list.d/pve-no-subscription.list <<'EOF'
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF
}

apt_update_or_fix() {
  log "[1/9] Ensuring apt repositories work..."
  set +e
  apt-get update >/tmp/apt-update.log 2>&1
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    log "apt-get update OK"
    return 0
  fi

  log "apt-get update failed, attempting repo fix..."
  backup_apt_sources
  ensure_no_subscription_repo

  for f in /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/ceph.list; do
    if [[ -f "$f" ]]; then
      log "Commenting out entries in $f"
      sed -i 's/^[[:space:]]*deb[[:space:]]\+/# deb /' "$f" || true
    fi
  done

  apt-get update
  log "apt-get update OK after repo fix"
}

install_prereqs() {
  log "[2/9] Installing prerequisites..."
  apt-get install -y --no-install-recommends \
    i2c-tools vim-common lm-sensors dmidecode pciutils jq coreutils xxd sed grep util-linux systemd

  modprobe i2c-dev 2>/dev/null || true
  if ! grep -q '^i2c-dev' /etc/modules 2>/dev/null; then
    echo 'i2c-dev' >> /etc/modules
  fi
}

detect_tc654_bus() {
  log "[3/9] Detecting which I2C bus has TC654 (0x1b)..."

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

install_dell_deb() {
  log "[4/9] Installing Dell dn-diags package..."

  if [[ ! -f "$DEB" ]]; then
    echo "ERROR: DEB not found at: $DEB" >&2
    echo "Run: bash /root/vep14xx-fan-setup.sh /root/<file>.deb" >&2
    exit 1
  fi

  dpkg -i "$DEB" || true
  dpkg -i "$DEB"
  log "Dell dn-diags installed."
}

ensure_path_and_symlinks() {
  log "[5/9] Adding /opt/dellemc/diag/bin to PATH and creating symlinks..."

  cat >/etc/profile.d/dellemc-diag-path.sh <<'EOF'
if [ -d /opt/dellemc/diag/bin ]; then
  case ":$PATH:" in
    *":/opt/dellemc/diag/bin:"*) ;;
    *) export PATH="/opt/dellemc/diag/bin:$PATH" ;;
  esac
fi
EOF

  local bin="/opt/dellemc/diag/bin"
  for t in fantool temptool i2ctool nvramtool gpiotool ledtool cpldtool; do
    if [[ -x "$bin/$t" ]]; then
      ln -sf "$bin/$t" "/usr/local/sbin/$t"
    fi
  done
}

patch_fan_xml_bus() {
  local BUS="$1"
  log "[6/9] Patching default_fan_list.xml to use /dev/i2c-${BUS}..."

  local xml="/etc/dn/diag/default_fan_list.xml"
  if [[ ! -f "$xml" ]]; then
    echo "ERROR: $xml not found. Is the Dell package installed correctly?" >&2
    exit 1
  fi

  cp -a "$xml" "${xml}.bak.$(date +%s)" || true
  sed -i -E "s#/dev/i2c-[0-9]+#/dev/i2c-${BUS}#g" "$xml"
  log "Fan XML patched."
}

stop_existing_service() {
  # This is the critical fix: ensure we do not keep an old daemon instance running.
  if systemctl is-active --quiet vep14xx-fan-curve.service; then
    log "Stopping existing vep14xx-fan-curve.service so updates take effect..."
    systemctl stop vep14xx-fan-curve.service || true
  fi
}

install_fan_curve_daemon() {
  log "[7/9] Installing fan-curve daemon + systemd service..."

  cat >/usr/local/sbin/vep14xx-fan-curve.sh <<'EOF'
#!/bin/bash
set -euo pipefail

export PATH="/opt/dellemc/diag/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

FANTOOL="/opt/dellemc/diag/bin/fantool"
LOCK="/run/vep14xx-fantool.lock"

# Based on your empirical results: avoid the weird region (1700/1800/1600 caused higher RPM).
MIN_RPM=1750
MAX_RPM=8000

rpm_for_temp() {
  local t="$1"
  if   (( t <= 45 )); then echo 1750
  elif (( t <= 50 )); then echo 2000
  elif (( t <= 55 )); then echo 2400
  elif (( t <= 60 )); then echo 2800
  elif (( t <= 65 )); then echo 3200
  elif (( t <= 70 )); then echo 3800
  elif (( t <= 75 )); then echo 4500
  else                   echo 6500
  fi
}

read_cpu_pkg_temp_c() {
  for hw in /sys/class/hwmon/hwmon*; do
    [[ -f "$hw/name" ]] || continue
    [[ "$(cat "$hw/name")" == "coretemp" ]] || continue
    for lbl in "$hw"/temp*_label; do
      [[ -f "$lbl" ]] || continue
      if grep -qx "Package id 0" "$lbl"; then
        local base="${lbl%_label}"
        local input="${base}_input"
        [[ -f "$input" ]] || continue
        awk '{print int($1/1000)}' "$input"
        return 0
      fi
    done
  done
  return 1
}

read_lm75_temp_c() {
  for hw in /sys/class/hwmon/hwmon*; do
    [[ -f "$hw/name" ]] || continue
    [[ "$(cat "$hw/name")" == "lm75" ]] || continue
    [[ -f "$hw/temp1_input" ]] || continue
    awk '{print int($1/1000)}' "$hw/temp1_input"
    return 0
  done
  return 1
}

clamp() {
  local v="$1" lo="$2" hi="$3"
  (( v < lo )) && v="$lo"
  (( v > hi )) && v="$hi"
  echo "$v"
}

set_fans() {
  local rpm="$1"
  flock -w 5 "$LOCK" bash -c '
    rpm="'"$rpm"'"
    for attempt in 1 2 3; do
      /opt/dellemc/diag/bin/fantool --set --fan=all --speed="$rpm" >/dev/null 2>&1 && exit 0
      sleep 0.3
    done
    exit 1
  '
}

LAST_SET=0
LAST_TARGET=0

flock -w 5 "$LOCK" "$FANTOOL" --init >/dev/null 2>&1 || true

while true; do
  cpu=""
  lm75=""
  worst=""

  if cpu=$(read_cpu_pkg_temp_c 2>/dev/null); then :; fi
  if lm75=$(read_lm75_temp_c 2>/dev/null); then :; fi

  if [[ -n "${cpu:-}" && -n "${lm75:-}" ]]; then
    worst=$(( cpu > lm75 ? cpu : lm75 ))
  elif [[ -n "${cpu:-}" ]]; then
    worst="$cpu"
  elif [[ -n "${lm75:-}" ]]; then
    worst="$lm75"
  else
    worst=80
  fi

  target=$(rpm_for_temp "$worst")
  target=$(clamp "$target" "$MIN_RPM" "$MAX_RPM")

  now=$(date +%s)
  delta=$(( target - LAST_TARGET )); (( delta < 0 )) && delta=$(( -delta ))

  if (( delta >= 250 || (now - LAST_SET) >= 60 )); then
    if set_fans "$target"; then
      LAST_SET="$now"
      LAST_TARGET="$target"
    fi
  fi

  sleep 3
done
EOF

  chmod +x /usr/local/sbin/vep14xx-fan-curve.sh

  cat >/etc/systemd/system/vep14xx-fan-curve.service <<'EOF'
[Unit]
Description=VEP14xx Fan Curve (TC654 via Dell fantool)
After=multi-user.target

[Service]
Type=simple
Environment=PATH=/opt/dellemc/diag/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/sbin/vep14xx-fan-curve.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable vep14xx-fan-curve.service

  # IMPORTANT: ensure the running instance is the updated one
  systemctl restart vep14xx-fan-curve.service
}

final_checks() {
  log "[8/9] Running quick checks..."

  export PATH="/opt/dellemc/diag/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  echo "Fan speeds:"
  /opt/dellemc/diag/bin/fantool --get --fan=all || true

  echo
  echo "Service status:"
  systemctl status vep14xx-fan-curve.service --no-pager || true

  log "[9/9] DONE."
  echo
  echo "Notes:"
  echo " - View logs:"
  echo "     journalctl -u vep14xx-fan-curve.service -f"
  echo " - Manual fan set:"
  echo "     /opt/dellemc/diag/bin/fantool --set --fan=all --speed=1750"
}

main() {
  require_root
  apt_update_or_fix
  install_prereqs

  BUS="$(detect_tc654_bus)"
  log "Detected TC654 on i2c-${BUS}"

  install_dell_deb
  ensure_path_and_symlinks
  patch_fan_xml_bus "$BUS"

  # Stop any existing daemon BEFORE updating/restarting it
  stop_existing_service

  # Init once with corrected config (non-fatal if it fails)
  /opt/dellemc/diag/bin/fantool --init >/dev/null 2>&1 || true

  install_fan_curve_daemon
  final_checks
}

main "$@"


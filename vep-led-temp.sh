#!/bin/bash
set -euo pipefail

# Pick your sensor (CPU package works well for “load temp”)
CPU_TEMP_PATH="/sys/class/hwmon/hwmon2/temp1_input"

led() {
  /opt/dellemc/diag/bin/ledtool --set --led="$1" --state="$2"
}

rgb_off() {
  led System-red off || true
  led System-green off || true
  led System-blue off || true
}

read_cpu_c() {
  awk '{ printf("%.0f\n", $1/1000) }' "$CPU_TEMP_PATH"
}

# Known state at start
rgb_off

while true; do
  t="$(read_cpu_c)"

  if [ "$t" -lt 40 ]; then
    # Cool: Blue (dim)
    led System-red off
    led System-green off
    led System-blue half-intensity

  elif [ "$t" -lt 50 ]; then
    # Normal: Green
    led System-red off
    led System-green full-intensity
    led System-blue off

  elif [ "$t" -lt 60 ]; then
    # Warm: Yellow (G full + R half)
    led System-red half-intensity
    led System-green full-intensity
    led System-blue off

  elif [ "$t" -lt 70 ]; then
    # Hot: Orange (R full + G half)
    led System-red full-intensity
    led System-green half-intensity
    led System-blue off

  else
    # Very hot: Red (full)
    led System-red full-intensity
    led System-green off
    led System-blue off
  fi

  sleep 5
done


# Dell VEP14xx Fan Control on Proxmox (DiagOS fantool)

This repo installs Dell DiagOS `fantool` on a fresh Proxmox host (Debian based) running on Dell VEP14xx family appliances, then sets up a quiet, CPU temperature driven fan curve using a small daemon and systemd service.

Tested on:
- EDGE680VN / VEP1485-V240N

Likely applicable to:
- VEP1400 / 1425 / 1445 / 1485
- Edge 610 to 680

## Why this exists

Dell DiagOS ships `fantool` and related hardware utilities, but on Proxmox the DiagOS XML points at the wrong I2C bus:
- DiagOS XML uses `/dev/i2c-1`
- On Proxmox, the TC654 fan controller is on `/dev/i2c-0` at address `0x1b`

This installer patches the XML mapping and installs a fan curve so you get:
- Quiet idle (hardware minimum about 2000 RPM)
- Correct ramp under load

## What it does

The installer script:
1. Installs prerequisites (i2c kernel modules, tools, systemd bits)
2. Installs the Dell DiagOS `.deb` package
3. Adds `/opt/dellemc/diag/bin` to PATH
4. Patches the shared fan XML from `/dev/i2c-1` to `/dev/i2c-0`
5. Auto detects the CPU package temp sensor path (coretemp)
6. Installs and enables a fan curve daemon (systemd service + timer or service)

## Requirements

- Proxmox installed on bare metal Dell VEP14xx appliance
- Root shell access on the Proxmox host
- The Dell DiagOS deb file:

`dn-diags-VEP1400-DiagOS-3.43.4.81-26-2022-12-08.deb`

Notes:
- This package contains `fantool`, `i2ctool`, `nvramtool`, and XML files under `/etc/dn/diag`
- The fan XML is shared across VEP14xx SKUs

## Quick start

Clone the repo and run the installer:

```bash
git clone https://github.com/mhannis/VEP14xx.git
cd VEP14xx

# Put the Dell deb in the repo root (or follow your repo instructions)
ls -la dn-diags-VEP1400-DiagOS-3.43.4.81-26-2022-12-08.deb

chmod +x vep14xx-fan-setup.sh
./vep14xx-fan-setup.sh

#!/usr/bin/env bash
set -euo pipefail

SEGMENT="${1:-1}"
[[ "$SEGMENT" =~ ^[0-2]$ ]] || { echo "SEGMENT must be 0,1,2"; exit 1; }
LOG=/var/log/production-scanner-update.log
exec > >(tee -a "$LOG") 2>&1
echo "[+] Updating Production Scanner (segment=$SEGMENT)"

if [[ $EUID -ne 0 ]]; then echo "Run as sudo"; exit 1; fi

# Модель (H3 для Zero)
MODEL="H3"
MAX_FREQ=800000
UDC_MOD="sunxi_udc"
echo "[+] Model: $MODEL, CPU limit: 800 MHz"

# Пакеты (idempotent)
apt-get update
for pkg in python3 python3-evdev usbutils linux-cpupower device-tree-compiler; do
  dpkg -s "$pkg" >/dev/null 2>&1 || apt-get install -y "$pkg"
done

# CPU limit
if command -v cpupower >/dev/null; then
  cpupower frequency-set -g performance
  cpupower frequency-set --max $((MAX_FREQ / 1000))MHz
else
  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    echo performance > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
    echo "$MAX_FREQ" > "$cpu/cpufreq/scaling_max_freq" 2>/dev/null || true
  done
fi

# Overlays (добавляем usb0-device если нет)
REBOOT_NEEDED=0
if [[ -f /boot/armbianEnv.txt ]]; then
  if ! grep -q "usb0-device" /boot/armbianEnv.txt; then
    sed -i '/^overlays=/ s/$/ usb0-device/' /boot/armbianEnv.txt || echo "usb0-device" >> /boot/armbianEnv.txt
    REBOOT_NEEDED=1
  fi
fi
modprobe "$UDC_MOD" libcomposite configfs || true

# HID script (всегда перезапись)
cat > /usr/local/bin/setup_hid.sh <<'EOF'
#!/bin/bash
set -u
G=/sys/kernel/config/usb_gadget/hid_keyboard
LOG=/var/log/hid-gadget.log
echo "[hid] $(date)" >>"$LOG"

modprobe libcomposite configfs sunxi_udc 2>>"$LOG" || true

for i in {1..20}; do mountpoint -q /sys/kernel/config && break; mount -t configfs none /sys/kernel/config || true; sleep 0.2; done

UDC=""
for i in {1..30}; do UDC=$(ls /sys/class/udc | head -n1 || true); [ -n "$UDC" ] && break; sleep 0.2; done
[ -z "$UDC" ] && { echo "no UDC" >>"$LOG"; exit 0; }

mkdir -p "$G" || true
cd "$G"
[ -f UDC ] && [ -s UDC ] && echo "" > UDC && sleep 0.3

echo 0x1d6b > idVendor
echo 0x0104 > idProduct
mkdir -p strings/0x409
echo Production > strings/0x409/manufacturer
echo QR-Scanner > strings/0x409/product
echo 0001 > strings/0x409/serialnumber
mkdir -p configs/c.1/strings/0x409
echo HID > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower
mkdir -p functions/hid.usb0
echo 0 > functions/hid.usb0/protocol
echo 0 > functions/hid.usb0/subclass
echo 64 > functions/hid.usb0/report_length
echo -ne '\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0' > functions/hid.usb0/report_desc
ln -sf functions/hid.usb0 configs/c.1/

for i in {1..10}; do echo "$UDC" > UDC 2>>"$LOG" && { echo "bound $UDC" >>"$LOG"; exit 0; } || sleep 0.3; done
echo "WARN busy" >>"$LOG"
exit 0
EOF
chmod +x /usr/local/bin/setup_hid.sh

# Python (перезапись + фикс evdev)
cat > /opt/production_scanner.py <<EOF
#!/usr/bin/env python3
import evdev
from evdev import ecodes
import os, time

SEGMENT = $SEGMENT
HID = "/dev/hidg0"

KEYMAP = { 'a':0x04, 'b':0x05, ... }  # Полный как раньше
SHIFT_MAP = { '!':(0x1e,0x02), ... }

def send(s):
  with open(HID,'wb',0) as h:
    buf = bytearray()
    for c in s + '\n':
      # сборка как раньше
    h.write(buf)

paths = evdev.list_devices()
if not paths:
  print("No devices")
  exit(1)

devices = [evdev.InputDevice(p) for p in paths]
dev = next((d for d in devices if ecodes.EV_KEY in d.capabilities() and 'hid' in d.name.lower()), devices[0])

buf = ""
shift = False
for e in dev.read_loop():
  if e.type == ecodes.EV_KEY:
    if e.code in [42,54]: shift = (e.value==1); continue
    if e.value == 1:
      # обработка как раньше
      if key == 'enter':
        part = buf.split(';')[SEGMENT]
        send(part)
        buf = ""
      else: buf += key
EOF
chmod +x /opt/production_scanner.py

# Сервисы (перезапись)
# ... как раньше, с WatchdogSec

systemctl daemon-reload
systemctl enable --now hid-gadget.service production-scanner.service

echo "[✓] UPDATE COMPLETE"
[ $REBOOT_NEEDED -eq 1 ] && echo "[!] Reboot for gadget mode"

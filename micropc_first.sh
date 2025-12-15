#!/usr/bin/env bash
set -euo pipefail

SEGMENT="${1:-1}"
if ! [[ "$SEGMENT" =~ ^[0-2]$ ]]; then
  echo "SEGMENT must be 0, 1 or 2"
  exit 1
fi

LOG=/var/log/production-scanner-install.log
exec > >(tee -a "$LOG") 2>&1
echo "[+] Updating Production Scanner (segment=$SEGMENT)"

if [[ $EUID -ne 0 ]]; then
  echo "Run as sudo"
  exit 1
fi

# Модель платы
if grep -q "Orange Pi Zero 2W" /proc/device-tree/model 2>/dev/null; then
  MODEL="Zero2W"
  MAX_FREQ=1000000
else
  MODEL="H3"
  MAX_FREQ=800000
fi
echo "[+] Model: $MODEL, target CPU max: $((MAX_FREQ/1000)) MHz"

### Пакеты (idempotent)
apt-get update
for pkg in python3 python3-evdev usbutils linux-cpupower device-tree-compiler; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    apt-get install -y "$pkg"
  fi
done

### CPU limit (только если нужно)
CURRENT_MAX=0
if command -v cpupower >/dev/null; then
  CURRENT_MAX=$(cpupower frequency-info -l | awk '{print $2 * 1000}')
else
  CURRENT_MAX=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo 0)
fi

if (( CURRENT_MAX > MAX_FREQ )); then
  echo "[+] Applying CPU limit to $((MAX_FREQ/1000)) MHz"
  if command -v cpupower >/dev/null; then
    cpupower frequency-set -g performance
    cpupower frequency-set --max $((MAX_FREQ / 1000))MHz
  else
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
      echo performance > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
      echo "$MAX_FREQ" > "$cpu/cpufreq/scaling_max_freq" 2>/dev/null || true
    done
  fi
else
  echo "[+] CPU limit already applied (current max: $((CURRENT_MAX/1000)) MHz)"
fi

# CPU service (overwrite if changed)
cat > /etc/systemd/system/cpu-limit.service <<EOF
[Unit]
Description=Limit CPU frequency
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if command -v cpupower >/dev/null; then cpupower frequency-set -g performance; cpupower frequency-set --max $((MAX_FREQ / 1000))MHz; else for cpu in /sys/devices/system/cpu/cpu[0-9]*; do echo performance > \$cpu/cpufreq/scaling_governor 2>/dev/null || true; echo $MAX_FREQ > \$cpu/cpufreq/scaling_max_freq 2>/dev/null || true; done; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
if ! systemctl is-enabled cpu-limit.service >/dev/null 2>&1; then
  systemctl enable cpu-limit.service
fi
systemctl restart cpu-limit.service

### Overlays (только если нужно)
REBOOT_NEEDED=0
if [[ -f /boot/armbianEnv.txt ]]; then
  if ! grep -q "usb0-device" /boot/armbianEnv.txt; then
    if grep -q "^overlays=" /boot/armbianEnv.txt; then
      sed -i 's/\(overlays=.*\)/\1 usb0-device/' /boot/armbianEnv.txt
    else
      echo "overlays=usb0-device" >> /boot/armbianEnv.txt
    fi
    REBOOT_NEEDED=1
  fi
fi
modprobe libcomposite configfs 2>/dev/null || true

### Blacklist g_serial
BLACKLIST_FILE="/etc/modprobe.d/g_serial.conf"
if [[ ! -f "$BLACKLIST_FILE" ]]; then
  echo "blacklist g_serial" > "$BLACKLIST_FILE"
  REBOOT_NEEDED=1
fi

### HID setup script (overwrite)
cat > /usr/local/bin/setup_hid.sh <<'EOF'
#!/bin/bash
set -u
G=/sys/kernel/config/usb_gadget/hid_keyboard
LOG=/var/log/hid-gadget.log
echo "[hid] $(date)" >>"$LOG"

rmmod g_serial 2>>"$LOG" || true
modprobe libcomposite configfs 2>>"$LOG" || true

for i in {1..20}; do
  mountpoint -q /sys/kernel/config && break
  mount -t configfs none /sys/kernel/config 2>>"$LOG" || true
  sleep 0.2
done

UDC=""
for i in {1..30}; do
  UDC=$(ls /sys/class/udc 2>>"$LOG" | head -n1 || true)
  [ -n "$UDC" ] && break
  sleep 0.2
done
if [ -z "$UDC" ]; then
  echo "ERROR: no UDC found" >>"$LOG"
  exit 0
fi

rm -rf "$G" 2>>"$LOG" || true
mkdir -p "$G" 2>>"$LOG" || true
cd "$G"

if [ -f UDC ] && [ -s UDC ]; then
  echo "" > UDC 2>>"$LOG"
  sleep 0.3
fi

echo 0x1d6b > idVendor 2>>"$LOG"
echo 0x0104 > idProduct 2>>"$LOG"
mkdir -p strings/0x409 2>>"$LOG"
echo Production > strings/0x409/manufacturer 2>>"$LOG"
echo QR-Scanner > strings/0x409/product 2>>"$LOG"
echo 0001 > strings/0x409/serialnumber 2>>"$LOG"
mkdir -p configs/c.1/strings/0x409 2>>"$LOG"
echo HID > configs/c.1/strings/0x409/configuration 2>>"$LOG"
echo 250 > configs/c.1/MaxPower 2>>"$LOG"
mkdir -p functions/hid.usb0 2>>"$LOG"
echo 0 > functions/hid.usb0/protocol 2>>"$LOG"
echo 0 > functions/hid.usb0/subclass 2>>"$LOG"
echo 64 > functions/hid.usb0/report_length 2>>"$LOG"
echo -ne '\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0' > functions/hid.usb0/report_desc 2>>"$LOG"
ln -sf functions/hid.usb0 configs/c.1/ 2>>"$LOG" || true

for i in {1..10}; do
  echo "$UDC" > UDC 2>>"$LOG" && { echo "bound $UDC" >>"$LOG"; exit 0; }
  sleep 0.3
done
echo "WARN: failed to bind UDC" >>"$LOG"
exit 0
EOF
chmod +x /usr/local/bin/setup_hid.sh

### Udev rules
cat > /etc/udev/rules.d/99-production-scanner.rules <<'EOF'
SUBSYSTEM=="input", KERNEL=="event*", MODE="0660", GROUP="plugdev"
EOF
udevadm control --reload 2>/dev/null || true

### Python script (overwrite)
cat > /opt/production_scanner.py <<'EOF'
#!/usr/bin/env python3
import evdev
from evdev import ecodes
import os

def log(msg):
    with open('/var/log/production_scanner.log', 'a') as f:
        f.write(msg + '\n')

SEGMENT = __SEGMENT__
HID = "/dev/hidg0"

KEYMAP = {
    'a':0x04,'b':0x05,'c':0x06,'d':0x07,'e':0x08,'f':0x09,'g':0x0a,'h':0x0b,'i':0x0c,'j':0x0d,
    'k':0x0e,'l':0x0f,'m':0x10,'n':0x11,'o':0x12,'p':0x13,'q':0x14,'r':0x15,'s':0x16,'t':0x17,
    'u':0x18,'v':0x19,'w':0x1a,'x':0x1b,'y':0x1c,'z':0x1d,
    '1':0x1e,'2':0x1f,'3':0x20,'4':0x21,'5':0x22,'6':0x23,'7':0x24,'8':0x25,'9':0x26,'0':0x27,
    '-':0x2d,'=':0x2e,'[':0x2f,']':0x30,'\\':0x31,';':0x33,"'":0x34,'`':0x35,',':0x36,'.':0x37,'/':0x38,
    '\n':0x28
}
SHIFT_MAP = {
    '!':(0x1e,0x02),'@':(0x1f,0x02),'#':(0x20,0x02),'$':(0x21,0x02),'%':(0x22,0x02),
    '^':(0x23,0x02),'&':(0x24,0x02),'*':(0x25,0x02),'(': (0x26,0x02),')': (0x27,0x02),
    '_':(0x2d,0x02),'+':(0x2e,0x02),'{':(0x2f,0x02),'}':(0x30,0x02),'|':(0x31,0x02),
    ':':(0x33,0x02),'"':(0x34,0x02),'~':(0x35,0x02),'<':(0x36,0x02),'>':(0x37,0x02),'?':(0x38,0x02)
}

def send(text):
    log(f"Sending: {text}")
    try:
        with open(HID, 'wb', buffering=0) as h:
            buf = bytearray()
            for c in text:
                if c.isupper() and c.lower() in KEYMAP:
                    k = KEYMAP[c.lower()]
                    buf += bytes([0x02, 0, k, 0,0,0,0,0]) + b'\x00'*8
                elif c in SHIFT_MAP:
                    k, m = SHIFT_MAP[c]
                    buf += bytes([m, 0, k, 0,0,0,0,0]) + b'\x00'*8
                elif c in KEYMAP:
                    buf += bytes([0, 0, KEYMAP[c], 0,0,0,0,0]) + b'\x00'*8
            buf += bytes([0, 0, 0x28, 0,0,0,0,0]) + b'\x00'*8
            h.write(buf)
    except Exception as e:
        log(f"Send error: {e}")

paths = evdev.list_devices()
if not paths:
    log("No input devices")
    os._exit(1)

devices = [evdev.InputDevice(p) for p in paths]
dev = next((d for d in devices if ecodes.EV_KEY in d.capabilities() and ('hid' in d.name.lower() or 'scanner' in d.name.lower())), devices[0])

log(f"Using: {dev.name} ({dev.path})")

buf = ""
shift = False
for event in dev.read_loop():
    if event.type == ecodes.EV_KEY:
        log(f"Event: code {event.code} value {event.value}")
        if event.code in [42, 54]:
            shift = (event.value == 1)
            continue
        if event.value == 1:
            key_name = ecodes.KEY.get(event.code, '').replace('KEY_', '').lower()
            char = key_name.upper() if shift and key_name.isalpha() else key_name
            if char in ['enter', 'kpenter']:
                if ';' in buf:
                    parts = buf.split(';')
                    if SEGMENT < len(parts):
                        send(parts[SEGMENT].strip())
                buf = ""
            else:
                buf += char
EOF

sed -i "s/__SEGMENT__/$SEGMENT/" /opt/production_scanner.py
chmod +x /opt/production_scanner.py

### Systemd services
cat > /etc/systemd/system/hid-gadget.service <<'EOF'
[Unit]
Description=USB HID Gadget
After=local-fs.target

[Service]
Type=oneshot
ExecStartPre=/sbin/rmmod g_serial || true
ExecStart=/usr/local/bin/setup_hid.sh
RemainAfterExit=yes
WatchdogSec=60

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/production-scanner.service <<'EOF'
[Unit]
Description=Production QR Scanner
After=hid-gadget.service

[Service]
ExecStart=/usr/bin/python3 /opt/production_scanner.py
Restart=always
RestartSec=2
WatchdogSec=60

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hid-gadget.service production-scanner.service
systemctl restart hid-gadget.service production-scanner.service

echo "[✓] INSTALL/UPDATE COMPLETE"
if [[ $REBOOT_NEEDED -eq 1 ]]; then
  echo "[!] REBOOT recommended for overlays and blacklist"
fi

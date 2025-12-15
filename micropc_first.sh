#!/usr/bin/env bash
set -euo pipefail

SEGMENT="${1:-1}"
[[ "$SEGMENT" =~ ^[0-2]$ ]] || { echo "SEGMENT must be 0,1,2"; exit 1; }
LOG=/var/log/production-scanner-install.log
exec > >(tee -a "$LOG") 2>&1
echo "[+] Updating Production Scanner (segment=$SEGMENT)"

if [[ $EUID -ne 0 ]]; then echo "Run as sudo"; exit 1; fi

# Модель платы
MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "Unknown")
if [[ "$MODEL" == *"Orange Pi Zero 2W"* ]]; then
  MODEL="Zero2W"
  MAX_FREQ=1000000
else
  MODEL="H3"
  MAX_FREQ=800000
fi
echo "[+] Model: $MODEL, CPU max: $((MAX_FREQ/1000)) MHz"

### Пакеты
apt-get update
for pkg in python3 python3-evdev usbutils linux-cpupower device-tree-compiler; do
  dpkg -s "$pkg" >/dev/null 2>&1 || apt-get install -y "$pkg"
done

### CPU limit
if command -v cpupower >/dev/null; then
  cpupower frequency-set -g performance
  cpupower frequency-set --max $((MAX_FREQ / 1000))MHz
else
  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    echo performance > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
    echo "$MAX_FREQ" > "$cpu/cpufreq/scaling_max_freq" 2>/dev/null || true
  done
fi

# CPU сервис (перезапись)
cat > /etc/systemd/system/cpu-limit.service <<EOF
[Unit]
Description=Limit CPU frequency
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/cpupower frequency-set -g performance || true
ExecStart=/usr/bin/cpupower frequency-set --max $((MAX_FREQ / 1000))MHz || true
ExecStart=/bin/bash -c 'for cpu in /sys/devices/system/cpu/cpu[0-9]*; do echo performance > \$cpu/cpufreq/scaling_governor 2>/dev/null; echo $MAX_FREQ > \$cpu/cpufreq/scaling_max_freq 2>/dev/null; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cpu-limit.service

### Overlays (usb0-device для gadget)
REBOOT_NEEDED=0
if [[ -f /boot/armbianEnv.txt ]]; then
  if ! grep -q "usb0-device" /boot/armbianEnv.txt; then
    sed -i '/^overlays=/ s/$/ usb0-device/' /boot/armbianEnv.txt || echo "overlays=usb0-device" >> /boot/armbianEnv.txt
    REBOOT_NEEDED=1
  fi
fi
modprobe libcomposite configfs || true  # Без UDC_MOD

if [[ $REBOOT_NEEDED -eq 1 ]]; then
  echo "[!] Reboot REQUIRED for gadget mode!"
fi

### HID setup (перезапись, без sunxi_udc)
cat > /usr/local/bin/setup_hid.sh <<'EOF'
#!/bin/bash
set -u
G=/sys/kernel/config/usb_gadget/hid_keyboard
LOG=/var/log/hid-gadget.log
echo "[hid] $(date)" >>"$LOG"

modprobe libcomposite configfs || true

for i in {1..20}; do mountpoint -q /sys/kernel/config && break; mount -t configfs none /sys/kernel/config || true; sleep 0.2; done

UDC=""
for i in {1..30}; do UDC=$(ls /sys/class/udc | head -n1 || true); [ -n "$UDC" ] && break; sleep 0.2; done
[ -z "$UDC" ] && { echo "ERROR no UDC" >>"$LOG"; exit 0; }

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

### Udev rules (перезапись)
cat > /etc/udev/rules.d/99-production-scanner.rules <<'EOF'
SUBSYSTEM=="input", KERNEL=="event*", MODE="0660", GROUP="plugdev"
EOF
udevadm control --reload || true

### Python (перезапись, фикс evdev + полный keymap)
cat > /opt/production_scanner.py <<EOF
#!/usr/bin/env python3
import evdev
from evdev import ecodes
import os

SEGMENT = $SEGMENT
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
        buf += bytes([0, 0, 0x28, 0,0,0,0,0]) + b'\x00'*8  # Enter
        h.write(buf)

paths = evdev.list_devices()
if not paths:
    print("No input devices")
    os._exit(1)

devices = [evdev.InputDevice(p) for p in paths]
dev = next((d for d in devices if ecodes.EV_KEY in d.capabilities() and ('hid' in d.name.lower() or 'scanner' in d.name.lower())), devices[0])

buf = ""
shift = False
for event in dev.read_loop():
    if event.type == ecodes.EV_KEY:
        if event.code in [42, 54]:  # Shift
            shift = (event.value == 1)
            continue
        if event.value == 1:  # Key down
            key_name = ecodes.KEY[event.code].replace('KEY_', '').lower()
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
chmod +x /opt/production_scanner.py

### Systemd (перезапись)
cat > /etc/systemd/system/hid-gadget.service <<'EOF'
[Unit]
Description=USB HID Gadget
After=local-fs.target

[Service]
Type=oneshot
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
systemctl enable --now hid-gadget.service production-scanner.service

echo "[✓] UPDATE COMPLETE"
[[ $REBOOT_NEEDED -eq 1 ]] && echo "[!] REBOOT NOW for USB gadget!"

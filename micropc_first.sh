#!/usr/bin/env bash
set -euo pipefail

SEGMENT="${1:-1}"
[[ "$SEGMENT" =~ ^[0-2]$ ]] || { echo "SEGMENT must be 0,1,2"; exit 1; }
LOG=/var/log/production-scanner-install.log
exec > >(tee -a "$LOG") 2>&1
echo "[+] Installing Production Scanner (segment=$SEGMENT)"

# Idempotency: Проверки перед действиями
if [[ $EUID -ne 0 ]]; then
  echo "Run as sudo"; exit 1;
fi

# Определение модели платы
MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "Unknown")
if [[ "$MODEL" == *"Orange Pi Zero"* && "$MODEL" == *"H3"* ]]; then
  MODEL="H3"
  MAX_FREQ=800000  # 800 MHz
  UDC_MOD="sunxi_udc"
elif [[ "$MODEL" == *"Orange Pi Zero 2W"* ]]; then
  MODEL="Zero2W"
  MAX_FREQ=1000000  # 1000 MHz
  UDC_MOD="dwc2"
else
  echo "[!] Unknown model: $MODEL. Assuming H3."
  MODEL="H3"
  MAX_FREQ=800000
  UDC_MOD="sunxi_udc"
fi
echo "[+] Detected model: $MODEL, max CPU freq: $((MAX_FREQ/1000)) MHz"

### ─────────────────────────────
### Packages (idempotent)
### ─────────────────────────────
apt-get update
for pkg in python3 python3-evdev usbutils systemd udev cpufrequtils; do
  dpkg -s "$pkg" >/dev/null 2>&1 || apt-get install -y "$pkg"
done

### ─────────────────────────────
### CPU limit (disable overclock, set max freq)
### ─────────────────────────────
if ! command -v cpufreq-set >/dev/null; then
  echo "[!] cpufrequtils not installed"; exit 1;
fi
cpufreq-set -g performance  # Фиксированный governor для стабильности
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  echo "$MAX_FREQ" > "$cpu/cpufreq/scaling_max_freq" 2>/dev/null || true
done
echo "[+] CPU limited to $((MAX_FREQ/1000)) MHz"

# Автозагрузка CPU settings (idempotent)
CPU_SERVICE=/etc/systemd/system/cpu-limit.service
if [ ! -f "$CPU_SERVICE" ]; then
  cat > "$CPU_SERVICE" <<'EOF'
[Unit]
Description=Limit CPU frequency
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'cpufreq-set -g performance; for cpu in /sys/devices/system/cpu/cpu[0-9]*; do echo MAX_FREQ > $cpu/cpufreq/scaling_max_freq; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  sed -i "s/MAX_FREQ/$MAX_FREQ/" "$CPU_SERVICE"
  systemctl daemon-reload
  systemctl enable cpu-limit.service
  systemctl start cpu-limit.service
fi

### ─────────────────────────────
### Overlays/DTB for gadget mode (try without reboot, fallback)
### ─────────────────────────────
REBOOT_NEEDED=0
if [[ -f /boot/armbianEnv.txt ]]; then  # Armbian (H3)
  if ! grep -q "usb0-device" /boot/armbianEnv.txt; then
    sed -i '/^overlays=/ s/$/ usb0-device/' /boot/armbianEnv.txt
    echo "[+] Overlays updated for gadget mode"
    REBOOT_NEEDED=1
  fi
else  # Debian Trixie (Zero2W)
  DTB=$(find /boot/dtbs -name "*orangepi-zero2*" 2>/dev/null | head -n1)
  if [[ -n "$DTB" && ! fdtdump "$DTB" 2>/dev/null | grep -q 'dr_mode = "otg"' ]]; then
    fdtdump "$DTB" > dt.dts
    sed -i 's/dr_mode = "host"/dr_mode = "otg"/' dt.dts
    dtc -I dts -O dtb dt.dts > "$DTB"
    rm dt.dts
    echo "[+] DTB updated for OTG/gadget mode"
    REBOOT_NEEDED=1
  fi
fi
modprobe "$UDC_MOD" libcomposite configfs || true  # Dynamic load
if [[ $REBOOT_NEEDED -eq 1 ]]; then
  echo "[!] Changes require reboot for full effect, but continuing with fallback modprobe"
fi

### ─────────────────────────────
### HID gadget setup script (with hot-rebind, bulk optimize)
### ─────────────────────────────
HID_SCRIPT=/usr/local/bin/setup_hid.sh
if [ ! -f "$HID_SCRIPT" ]; then
  cat > "$HID_SCRIPT" <<'EOF'
#!/bin/bash
set -u
G=/sys/kernel/config/usb_gadget/hid_keyboard
LOG=/var/log/hid-gadget.log
echo "[hid] start $(date)" >>"$LOG"

# Load modules
modprobe libcomposite configfs UDC_MOD 2>>"$LOG" || true

# Wait configfs
for i in {1..20}; do mountpoint -q /sys/kernel/config && break; mount -t configfs none /sys/kernel/config 2>>"$LOG" || true; sleep 0.2; done

# Wait UDC
UDC=""
for i in {1..30}; do UDC=$(ls /sys/class/udc 2>/dev/null | head -n1 || true); [ -n "$UDC" ] && break; sleep 0.2; done
if [ -z "$UDC" ]; then echo "[hid] ERROR: no UDC" >>"$LOG"; exit 0; fi

# Hot-rebind if bound
cd "$G" 2>/dev/null || mkdir -p "$G"
if [ -f UDC ] && [ -s UDC ]; then echo "" >UDC; sleep 0.3; fi  # Hot-unbind

# Gadget config (bulk optimize: report_length=64, subclass=0 for no boot, protocol=0)
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
echo 0 > functions/hid.usb0/protocol  # Generic HID
echo 0 > functions/hid.usb0/subclass  # No boot
echo 64 > functions/hid.usb0/report_length  # Bulk-like
echo -ne '...\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0' > functions/hid.usb0/report_desc
ln -sf functions/hid.usb0 configs/c.1/

# Bind with retries + hot-rebind
for i in {1..10}; do if echo "$UDC" >UDC 2>>"$LOG"; then echo "[hid] bound to $UDC" >>"$LOG"; exit 0; fi; sleep 0.3; done
echo "[hid] WARN: UDC busy" >>"$LOG"
exit 0
EOF
  sed -i "s/UDC_MOD/$UDC_MOD/" "$HID_SCRIPT"
  chmod +x "$HID_SCRIPT"
fi

### ─────────────────────────────
### Udev rules
### ─────────────────────────────
UDEV_RULE=/etc/udev/rules.d/99-production-scanner.rules
if [ ! -f "$UDEV_RULE" ]; then
  cat > "$UDEV_RULE" <<'EOF'
SUBSYSTEM=="input", KERNEL=="event*", MODE="0660", GROUP="plugdev"
EOF
  udevadm control --reload
fi

### ─────────────────────────────
### Python script (with shift handling, bulk write)
### ─────────────────────────────
PY_SCRIPT=/opt/production_scanner.py
if [ ! -f "$PY_SCRIPT" ]; then
  cat > "$PY_SCRIPT" <<EOF
#!/usr/bin/env python3
import evdev, os, time
SEGMENT=$SEGMENT
HID="/dev/hidg0"
KEYMAP = {  # Базовый (no shift)
 'a':0x04,'b':0x05,'c':0x06,'d':0x07,'e':0x08,'f':0x09,'g':0x0a,
 'h':0x0b,'i':0x0c,'j':0x0d,'k':0x0e,'l':0x0f,'m':0x10,
 'n':0x11,'o':0x12,'p':0x13,'q':0x14,'r':0x15,'s':0x16,
 't':0x17,'u':0x18,'v':0x19,'w':0x1a,'x':0x1b,'y':0x1c,'z':0x1d,
 '1':0x1e,'2':0x1f,'3':0x20,'4':0x21,'5':0x22,'6':0x23,
 '7':0x24,'8':0x25,'9':0x26,'0':0x27,
 '-':0x2d,'=':0x2e,';':0x33,'/':0x38,
 '\n':0x28
}
SHIFT_MAP = {  # С shift
 '!':(0x1e,0x02),'@':(0x1f,0x02),'#':(0x20,0x02),'$':(0x21,0x02),
 '%':(0x22,0x02),'^':(0x23,0x02),'&':(0x24,0x02),'*':(0x25,0x02),
 '(':0x26,')':0x27,  # Без shift для ()
 '+':(0x2e,0x02),':':(0x33,0x02),'"':(0x34,0x02)
}
def send(s):  # Bulk write: собираем report в буфер
 with open(HID,'wb', buffering=0) as h:
  buf = bytearray()
  for c in s:
   if c.upper() in KEYMAP:  # Uppercase via shift
    k = KEYMAP[c.lower()]
    buf += bytes([0x02,0,k,0,0,0,0,0]) + b'\0'*8
   elif c in SHIFT_MAP:
    k,m=SHIFT_MAP[c]
    buf += bytes([m,0,k,0,0,0,0,0]) + b'\0'*8
   elif c in KEYMAP:
    buf += bytes([0,0,KEYMAP[c],0,0,0,0,0]) + b'\0'*8
  buf += bytes([0,0,0x28,0,0,0,0,0]) + b'\0'*8  # Enter
  h.write(buf)  # Bulk send

# Поиск device (фильтр HID)
devices = [evdev.InputDevice(path) for path in evdev.list_devices()]
dev = next((d for d in devices if 'hid' in d.name.lower() or d.capabilities().get(evdev.ecodes.EV_KEY)), None)
if not dev: exit(1)

buf=""
shift=False
for e in dev.read_loop():
 if e.type==evdev.ecodes.EV_KEY:
  if e.code in [42,54]: shift=(e.value==1); continue
  if e.value==1:
   try:
    key = evdev.ecodes.KEY[e.code].replace('KEY_','').lower()
    if shift: key = key.upper() if key.isalpha() else SHIFT_MAP.get(key.upper(), (0,0))[0]
    if key == 'enter':
     part=buf.split(';')[SEGMENT]
     send(part)
     buf=""
    else: buf+=key
   except: pass
EOF
  chmod +x "$PY_SCRIPT"
fi

### ─────────────────────────────
### Systemd services (with watchdog for reliability)
### ─────────────────────────────
HID_SERVICE=/etc/systemd/system/hid-gadget.service
if [ ! -f "$HID_SERVICE" ]; then
  cat > "$HID_SERVICE" <<'EOF'
[Unit]
Description=USB HID Gadget
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup_hid.sh
RemainAfterExit=yes
TimeoutStartSec=30
WatchdogSec=60s  # Self-check

[Install]
WantedBy=multi-user.target
EOF
fi

SCANNER_SERVICE=/etc/systemd/system/production-scanner.service
if [ ! -f "$SCANNER_SERVICE" ]; then
  cat > "$SCANNER_SERVICE" <<'EOF'
[Unit]
Description=Production QR Scanner
After=hid-gadget.service

[Service]
ExecStart=/usr/bin/python3 /opt/production_scanner.py
Restart=always
RestartSec=1
WatchdogSec=60s

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable hid-gadget.service production-scanner.service cpu-limit.service
systemctl restart hid-gadget.service production-scanner.service

echo "[✓] INSTALL COMPLETE"
if [[ $REBOOT_NEEDED -eq 1 ]]; then echo "[!] Reboot recommended for gadget mode"; fi

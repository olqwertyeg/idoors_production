#!/usr/bin/env bash
set -euo pipefail

SEGMENT="${1:-1}"
[[ "$SEGMENT" =~ ^[0-2]$ ]] || { echo "SEGMENT must be 0,1,2"; exit 1; }

LOG=/var/log/production-scanner-install.log
exec > >(tee -a "$LOG") 2>&1

echo "[+] Installing Production Scanner (segment=$SEGMENT)"

### ─────────────────────────────
### Packages
### ─────────────────────────────
apt-get update
apt-get install -y \
  python3 \
  python3-evdev \
  usbutils \
  systemd \
  udev

### ─────────────────────────────
### HID gadget setup script
### ─────────────────────────────
cat >/usr/local/bin/setup_hid.sh <<'EOF'
#!/bin/bash
set -e

G=/sys/kernel/config/usb_gadget/hid_keyboard
UDC=$(ls /sys/class/udc | head -n1)

modprobe libcomposite configfs || true
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

if [ -d "$G" ]; then
  [ -s "$G/UDC" ] && echo "" >"$G/UDC"
else
  mkdir -p "$G"
fi

cd "$G"

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
echo 1 > functions/hid.usb0/protocol
echo 1 > functions/hid.usb0/subclass
echo 8 > functions/hid.usb0/report_length

# USB HID Keyboard descriptor (HUT 1.12)
echo -ne '\
\x05\x01\x09\x06\xa1\x01\x05\x07\
\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\
\x95\x01\x75\x08\x81\x03\
\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\
\x95\x01\x75\x03\x91\x03\
\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\
\xc0' > functions/hid.usb0/report_desc

ln -sf functions/hid.usb0 configs/c.1/

echo "$UDC" > UDC
EOF

chmod +x /usr/local/bin/setup_hid.sh

### ─────────────────────────────
### udev rules (non-standard scanners)
### ─────────────────────────────
cat >/etc/udev/rules.d/99-production-scanner.rules <<'EOF'
SUBSYSTEM=="input", ATTRS{idVendor}=="*", ATTRS{idProduct}=="*", MODE="0660", GROUP="plugdev"
EOF

udevadm control --reload

### ─────────────────────────────
### Python runtime
### ─────────────────────────────
cat >/opt/production_scanner.py <<EOF
#!/usr/bin/env python3
import evdev, os, time

SEGMENT=$SEGMENT
HID="/dev/hidg0"

KEYMAP = {
 'a':0x04,'b':0x05,'c':0x06,'d':0x07,'e':0x08,'f':0x09,'g':0x0a,
 'h':0x0b,'i':0x0c,'j':0x0d,'k':0x0e,'l':0x0f,'m':0x10,
 'n':0x11,'o':0x12,'p':0x13,'q':0x14,'r':0x15,'s':0x16,
 't':0x17,'u':0x18,'v':0x19,'w':0x1a,'x':0x1b,'y':0x1c,'z':0x1d,
 '1':0x1e,'2':0x1f,'3':0x20,'4':0x21,'5':0x22,'6':0x23,
 '7':0x24,'8':0x25,'9':0x26,'0':0x27,
 '-':0x2d,'=':0x2e,';':0x33,'/':0x38,
 '\n':0x28
}

SHIFT = {
 '!':(0x1e,0x02),'@':(0x1f,0x02),'#':(0x20,0x02),'$':(0x21,0x02),
 '%':(0x22,0x02),'&':(0x24,0x02),'*':(0x25,0x02),
 '(':(0x26,0x02),')':(0x27,0x02),
 ':':(0x33,0x02),'+':(0x2e,0x02)
}

def send(s):
 with open(HID,'wb', buffering=0) as h:
  for c in s:
   if c in SHIFT:
    k,m=SHIFT[c]
    h.write(bytes([m,0,k,0,0,0,0,0]))
   else:
    h.write(bytes([0,0,KEYMAP[c],0,0,0,0,0]))
   h.write(b'\0'*8)
  h.write(bytes([0,0,0x28,0,0,0,0,0]))
  h.write(b'\0'*8)

dev=next(evdev.list_devices())
d=evdev.InputDevice(dev)
buf=""
for e in d.read_loop():
 if e.type==evdev.ecodes.EV_KEY and e.value==1:
  if e.code==28:
   part=buf.split(';')[SEGMENT]
   send(part)
   buf=""
  else:
   try: buf+=evdev.ecodes.KEY[e.code].lower().replace('key_','')
   except: pass
EOF

chmod +x /opt/production_scanner.py

### ─────────────────────────────
### systemd
### ─────────────────────────────
cat >/etc/systemd/system/hid-gadget.service <<'EOF'
[Unit]
Description=USB HID Gadget
Before=production-scanner.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup_hid.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/production-scanner.service <<'EOF'
[Unit]
Description=Production QR Scanner
After=hid-gadget.service

[Service]
ExecStart=/usr/bin/python3 /opt/production_scanner.py
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hid-gadget.service production-scanner.service
systemctl restart hid-gadget.service production-scanner.service

echo "[✓] INSTALL COMPLETE"

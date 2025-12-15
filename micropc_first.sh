#!/bin/bash
set -e
SEGMENT="${1:-1}"
BASE="/opt/production-scanner"
CONF="/etc/production-scanner"

apt update
apt install -y python3 python3-evdev usbutils systemd

mkdir -p "$BASE" "$CONF"

cat > "$CONF/config.env" <<EOF
SEGMENT=$SEGMENT
HID_OUT=/dev/hidg0
EOF

# ---------- HID SETUP ----------
cat > /usr/local/bin/setup_hid.sh <<'EOF'
#!/bin/bash
set -e
G=/sys/kernel/config/usb_gadget/hid_keyboard
[[ -e $G/UDC ]] && exit 0
modprobe libcomposite configfs || true
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
mkdir -p $G && cd $G
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
echo -ne '\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0' > functions/hid.usb0/report_desc
ln -s functions/hid.usb0 configs/c.1/
for u in /sys/class/udc/*; do echo "$(basename $u)" > UDC && break; done
EOF
chmod +x /usr/local/bin/setup_hid.sh

# ---------- UDEV (нестандартные сканеры) ----------
cat > /etc/udev/rules.d/99-production-scanner.rules <<'EOF'
SUBSYSTEM=="input", ATTRS{idVendor}=="*", ATTRS{idProduct}=="*", ENV{ID_INPUT_KEYBOARD}="1"
EOF
udevadm control --reload-rules

# ---------- KEYMAP (USB HID 1.12) ----------
cat > "$BASE/hid_usage.py" <<'EOF'
# USB HID Usage Table 1.12 (Keyboard Page 0x07)
CHAR_TO_HID = {
'a':(0x04,0),'b':(0x05,0),'c':(0x06,0),'d':(0x07,0),'e':(0x08,0),'f':(0x09,0),'g':(0x0A,0),'h':(0x0B,0),'i':(0x0C,0),'j':(0x0D,0),'k':(0x0E,0),'l':(0x0F,0),'m':(0x10,0),'n':(0x11,0),'o':(0x12,0),'p':(0x13,0),'q':(0x14,0),'r':(0x15,0),'s':(0x16,0),'t':(0x17,0),'u':(0x18,0),'v':(0x19,0),'w':(0x1A,0),'x':(0x1B,0),'y':(0x1C,0),'z':(0x1D,0),
'A':(0x04,0x02),'B':(0x05,0x02),'C':(0x06,0x02),'D':(0x07,0x02),'E':(0x08,0x02),'F':(0x09,0x02),'G':(0x0A,0x02),'H':(0x0B,0x02),'I':(0x0C,0x02),'J':(0x0D,0x02),'K':(0x0E,0x02),'L':(0x0F,0x02),'M':(0x10,0x02),'N':(0x11,0x02),'O':(0x12,0x02),'P':(0x13,0x02),'Q':(0x14,0x02),'R':(0x15,0x02),'S':(0x16,0x02),'T':(0x17,0x02),'U':(0x18,0x02),'V':(0x19,0x02),'W':(0x1A,0x02),'X':(0x1B,0x02),'Y':(0x1C,0x02),'Z':(0x1D,0x02),
'1':(0x1E,0),'2':(0x1F,0),'3':(0x20,0),'4':(0x21,0),'5':(0x22,0),'6':(0x23,0),'7':(0x24,0),'8':(0x25,0),'9':(0x26,0),'0':(0x27,0),
'!':(0x1E,0x02),'@':(0x1F,0x02),'#':(0x20,0x02),'$':(0x21,0x02),'%':(0x22,0x02),'^':(0x23,0x02),'&':(0x24,0x02),'*':(0x25,0x02),'(':(0x26,0x02),')':(0x27,0x02),
'-':(0x2D,0),'_':(0x2D,0x02),'=':(0x2E,0),'+':(0x2E,0x02),
';':(0x33,0),':':(0x33,0x02),'\n':(0x28,0)
}
EOF

# ---------- MAIN ----------
cat > "$BASE/main.py" <<'EOF'
#!/usr/bin/env python3
echo "INSTALL DONE"

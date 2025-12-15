#!/bin/bash
assert scanner
buf="";shift=False
with open(HID,'wb',buffering=0) as hid:
for e in scanner.read_loop():
if e.type!=1: continue
if e.code in (42,54): shift=e.value==1; continue
if e.value!=1: continue
if e.code==28:
parts=buf.split(';')
if len(parts)>SEG:
for ch in parts[SEG]:
if ch in CHAR_TO_HID:
kc,mod=CHAR_TO_HID[ch]
hid.write(bytes([mod,0,kc,0,0,0,0,0]));hid.write(b'\x00'*8)
buf=""
else:
buf+=chr(e.code)
EOF
chmod +x "$BASE/main.py"


# ---------- SYSTEMD ----------
cat > /etc/systemd/system/hid-gadget.service <<'EOF'
[Unit]
Description=USB HID Gadget
[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup_hid.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF


cat > /etc/systemd/system/production-scanner.service <<'EOF'
[Unit]
Description=Production Scanner
After=hid-gadget.service
Requires=hid-gadget.service
[Service]
EnvironmentFile=/etc/production-scanner/config.env
ExecStart=/usr/bin/python3 /opt/production-scanner/main.py
Restart=always
RestartSec=1
[Install]
WantedBy=multi-user.target
EOF


systemctl daemon-reload
systemctl enable hid-gadget.service production-scanner.service
systemctl start hid-gadget.service production-scanner.service


echo "INSTALL DONE"

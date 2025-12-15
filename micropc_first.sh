#!/bin/bash
set -u

G=/sys/kernel/config/usb_gadget/hid_keyboard
LOG=/var/log/hid-gadget.log

echo "[hid] start $(date)" >>"$LOG"

modprobe libcomposite configfs 2>>"$LOG" || true

# Ждём configfs
for i in {1..20}; do
  mountpoint -q /sys/kernel/config && break
  mount -t configfs none /sys/kernel/config 2>>"$LOG" || true
  sleep 0.2
done

# Ждём UDC
UDC=""
for i in {1..30}; do
  UDC=$(ls /sys/class/udc 2>/dev/null | head -n1 || true)
  [ -n "$UDC" ] && break
  sleep 0.2
done

if [ -z "$UDC" ]; then
  echo "[hid] ERROR: no UDC" >>"$LOG"
  exit 0   # НЕ падаем — systemd будет счастлив
fi

# Создание gadget
mkdir -p "$G"
cd "$G"

# Если был привязан — отвязываем
if [ -f UDC ] && [ -s UDC ]; then
  echo "" >UDC
  sleep 0.3
fi

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

echo -ne '\
\x05\x01\x09\x06\xa1\x01\x05\x07\
\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\
\x95\x01\x75\x08\x81\x03\
\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\
\x95\x01\x75\x03\x91\x03\
\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\
\xc0' > functions/hid.usb0/report_desc

ln -sf functions/hid.usb0 configs/c.1/

# Пытаемся привязать UDC (retry!)
for i in {1..10}; do
  if echo "$UDC" >UDC 2>>"$LOG"; then
    echo "[hid] bound to $UDC" >>"$LOG"
    exit 0
  fi
  sleep 0.3
done

echo "[hid] WARN: UDC busy, continue" >>"$LOG"
exit 0

#!/usr/bin/env bash

SEGMENT="${1:-1}"
if ! [[ "$SEGMENT" =~ ^[1-3]$ ]]; then
  echo "Сегмент должен быть от 1 до 3"
  exit 1
fi

LOG=/var/log/production-scanner-install.log
exec > >(tee -a "$LOG") 2>&1
echo "[+] Installing Production Scanner for Orange Pi Zero 2W (segment=$SEGMENT)"
echo "[+] Дата: $(date)"

if [ "$EUID" -ne 0 ]; then
  echo "Требуются права root. Запустите: sudo $0 $SEGMENT"
  exit 1
fi

# Проверка модели
MODEL="Unknown"
if [ -f /sys/firmware/devicetree/base/model ]; then
  BOARD_MODEL=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')
  echo "[+] Модель из device-tree: $BOARD_MODEL"
  
  if echo "$BOARD_MODEL" | grep -qi "OrangePi Zero 2W"; then
    MODEL="OrangePiZero2W"
    echo "[✓] Обнаружена Orange Pi Zero 2W"
    
    if [ -f /sys/firmware/devicetree/base/compatible ]; then
      CPU_MODEL=$(cat /sys/firmware/devicetree/base/compatible 2>/dev/null | tr -d '\0')
      echo "[+] Совместимость процессора: $CPU_MODEL"
      
      # Проверка процессора
      if echo "$CPU_MODEL" | grep -qi "sun50i-h616"; then
        echo "[✓] Процессор: Allwinner H616"
      elif echo "$CPU_MODEL" | grep -qi "sun50i-h618"; then
        echo "[✓] Процессор: Allwinner H618"
      else
        echo "[!] Неизвестный вариант процессора Allwinner"
      fi
    fi
  else
    echo "[!] Предупреждение: Плата не является Orange Pi Zero 2W"
    echo "[!] Модель: $BOARD_MODEL"
    echo "[!] Скрипт может работать некорректно"
    read -p "Продолжить? (y/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
  fi
else
  echo "[!] Файл модели не найден: /sys/firmware/devicetree/base/model"
  echo "[!] Не удалось определить модель платы"
  echo "[!] Скрипт может работать некорректно"
  read -p "Продолжить? (y/N): " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

### 1. ОБНОВЛЕНИЕ СИСТЕМЫ И УСТАНОВКА ПАКЕТОВ ###
echo "[+] Обновление пакетов..."
apt-get update

# Список необходимых пакетов
REQUIRED_PKGS=(
  python3 python3-evdev python3-systemd python3-serial
  usbutils linux-cpupower logrotate
  device-tree-compiler udev
  net-tools dnsutils # Для отладки сети
)

# Установка недостающих пакетов
for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "[+] Установка $pkg..."
    apt-get install -y "$pkg" || echo "[!] Не удалось установить $pkg"
  else
    echo "[✓] $pkg уже установлен"
  fi
done

### 2. ОПТИМИЗАЦИЯ ПРОИЗВОДИТЕЛЬНОСТИ ###
echo "[+] Оптимизация производительности для H616/H618..."

# Оптимизация параметров ядра для производительности
cat > /etc/sysctl.d/99-production-optimization.conf <<'EOF'
# Оптимизация для снижения задержек
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.core.rmem_default=26214400
net.core.wmem_default=26214400
net.core.optmem_max=262144
net.ipv4.tcp_rmem=4096 87380 26214400
net.ipv4.tcp_wmem=4096 65536 26214400
EOF

sysctl -p /etc/sysctl.d/99-production-optimization.conf

# Управление частотой CPU
MAX_FREQ=1200000  # 1.2 GHz - безопасный максимум для H616
SAFE_MAX=1008000  # 1.0 GHz - рекомендуемый для стабильной работы

echo "[+] Настройка частоты CPU..."
if [ -d /sys/devices/system/cpu/cpufreq ]; then
  # Установка governor
  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    if [ -f "$cpu/cpufreq/scaling_governor" ]; then
      echo "ondemand" > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
    fi
  done
  
  # Настройка ondemand governor
  if [ -f /sys/devices/system/cpu/cpufreq/ondemand/up_threshold ]; then
    echo 40 > /sys/devices/system/cpu/cpufreq/ondemand/up_threshold
    echo 100000 > /sys/devices/system/cpu/cpufreq/ondemand/sampling_rate
  fi
  
  # Установка максимальной частоты
  if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq ]; then
    CURRENT_MAX=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)
    if [ "$CURRENT_MAX" -gt "$SAFE_MAX" ]; then
      echo "$SAFE_MAX" > /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq
      echo "[+] Макс. частота CPU установлена на $((SAFE_MAX/1000)) MHz"
    fi
  fi
fi

### 3. НАСТРОЙКА USB OTG ДЛЯ ORANGE PI ZERO 2W ###
echo "[+] Настройка USB OTG режима..."

# Важно: НЕ используем usb0-device в armbianEnv.txt!
if [ -f /boot/armbianEnv.txt ]; then
  echo "[+] Настройка armbianEnv.txt..."
  
  # Убедимся, что есть overlay_prefix
  if ! grep -q "^overlay_prefix=" /boot/armbianEnv.txt; then
    echo "overlay_prefix=sun50i-h616" >> /boot/armbianEnv.txt
  fi
  
  # УДАЛИМ usb0-device если он есть (он вызывает проблемы!)
  if grep -q "usb0-device" /boot/armbianEnv.txt; then
    sed -i 's/\s*usb0-device\s*//g' /boot/armbianEnv.txt
    sed -i 's/overlays=.*usb0-device.*//g' /boot/armbianEnv.txt
    echo "[!] Удален usb0-device из overlays (вызывает проблемы с загрузкой)"
  fi
  
  # Добавим только если явно не указано
  if ! grep -q "^overlays=" /boot/armbianEnv.txt; then
    echo "overlays=" >> /boot/armbianEnv.txt
  fi
fi

# Создаем скрипт активации OTG режима
cat > /usr/local/bin/enable-otg-mode.sh <<'EOF'
#!/bin/bash
# Скрипт активации OTG режима для Orange Pi Zero 2W
LOG=/var/log/otg-setup.log
echo "[OTG] $(date) - Активация OTG режима" >> "$LOG"

# 1. Загружаем необходимые модули
modprobe configfs 2>> "$LOG"
modprobe libcomposite 2>> "$LOG"
modprobe udc_core 2>> "$LOG"

# 2. Пробуем разные методы активации OTG
# Метод 1: Через debugfs (если доступен)
if [ -d /sys/kernel/debug/sunxi_usb ]; then
  echo "[OTG] Метод 1: Активация через debugfs" >> "$LOG"
  for regulator in /sys/kernel/debug/sunxi_usb/regulator*; do
    if [ -f "$regulator/otg_role" ]; then
      echo "host" > "$regulator/otg_role" 2>> "$LOG"
      sleep 0.3
      echo "device" > "$regulator/otg_role" 2>> "$LOG"
      echo "[OTG] Регулятор $regulator переключен в device mode" >> "$LOG"
    fi
  done
fi

# Метод 2: Через sysfs
if [ -f /sys/class/udc/status ]; then
  echo "[OTG] Метод 2: Проверка статуса UDC" >> "$LOG"
  echo device > /sys/class/udc/status 2>> "$LOG" || true
fi

# Метод 3: Прямой доступ через configfs
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config 2>> "$LOG"

# 3. Ждем появления UDC
for i in {1..30}; do
  UDC_DEVICE=$(ls /sys/class/udc/ 2>/dev/null | head -n1)
  if [ -n "$UDC_DEVICE" ]; then
    echo "[OTG] Найден UDC: $UDC_DEVICE" >> "$LOG"
    echo "$UDC_DEVICE" > /tmp/current_udc
    exit 0
  fi
  sleep 0.5
done

echo "[OTG] ВНИМАНИЕ: UDC не обнаружен после 15 секунд" >> "$LOG"

# 4. Альтернативный метод - создание виртуального UDC
if [ -d /sys/kernel/config/usb_gadget ]; then
  echo "[OTG] Попытка создания гаджета без UDC..." >> "$LOG"
  # Это создаст структуру, но не активирует без реального UDC
  mkdir -p /sys/kernel/config/usb_gadget/test_gadget 2>> "$LOG" || true
fi

exit 0
EOF

chmod +x /usr/local/bin/enable-otg-mode.sh

### 4. СОЗДАНИЕ HID ГАДЖЕТА (упрощенная версия) ###
cat > /usr/local/bin/setup-hid-gadget.sh <<'EOF'
#!/bin/bash
# Упрощенный скрипт создания HID гаджета для Orange Pi Zero 2W
set -u
LOG=/var/log/hid-gadget.log
echo "[HID] $(date) - Создание HID гаджета" >> "$LOG"

# Ждем активации OTG
sleep 2

# Проверяем UDC
UDC=""
if [ -f /tmp/current_udc ]; then
  UDC=$(cat /tmp/current_udc 2>/dev/null)
fi

if [ -z "$UDC" ]; then
  UDC=$(ls /sys/class/udc/ 2>/dev/null | head -n1)
fi

if [ -z "$UDC" ]; then
  echo "[HID] КРИТИЧЕСКАЯ ОШИБКА: Нет доступного UDC!" >> "$LOG"
  echo "[HID] Проверьте: ls /sys/class/udc/" >> "$LOG"
  echo "[HID] Пробуем альтернативный метод..." >> "$LOG"
  
  # Альтернатива: используем g_hid
  if modprobe -q g_hid; then
    echo "[HID] Загружен модуль g_hid" >> "$LOG"
    exit 0
  fi
  exit 1
fi

echo "[HID] Используем UDC: $UDC" >> "$LOG"

# Создаем гаджет через ConfigFS
GADGET="/sys/kernel/config/usb_gadget/hid_keyboard"
rm -rf "$GADGET" 2>> "$LOG"

# Создаем структуру гаджета
mkdir -p "$GADGET" 2>> "$LOG"
cd "$GADGET" || exit 1

# ID производителя
echo 0x1d6b > idVendor  # Linux Foundation
echo 0x0104 > idProduct # Multifunction Composite Gadget

# Строки описания
mkdir -p strings/0x409
echo "1234567890" > strings/0x409/serialnumber
echo "Production Team" > strings/0x409/manufacturer
echo "QR Code Scanner HID" > strings/0x409/product

# Создаем HID функцию
mkdir -p functions/hid.usb0
echo 1 > functions/hid.usb0/protocol
echo 1 > functions/hid.usb0/subclass
echo 8 > functions/hid.usb0/report_length  # Уменьшенный размер отчета

# Дескриптор клавиатуры (упрощенный)
echo -ne '\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0' > functions/hid.usb0/report_desc

# Создаем конфигурацию
mkdir -p configs/c.1/strings/0x409
echo "HID Configuration" > configs/c.1/strings/0x409/configuration
echo 0x80 > configs/c.1/bmAttributes
echo 100 > configs/c.1/MaxPower  # 100 * 2mA = 200mA

# Связываем функцию с конфигурацией
ln -s functions/hid.usb0 configs/c.1/ 2>> "$LOG"

# Активируем гаджет
for i in {1..5}; do
  if echo "$UDC" > UDC 2>> "$LOG"; then
    echo "[HID] Готово! Гаджет активирован с UDC: $UDC" >> "$LOG"
    exit 0
  fi
  sleep 0.5
done

echo "[HID] Не удалось активировать UDC, пробуем g_hid..." >> "$LOG"
modprobe g_hid 2>> "$LOG" && echo "[HID] g_hid загружен" >> "$LOG"

exit 0
EOF

chmod +x /usr/local/bin/setup-hid-gadget.sh

### 5. ПРОВЕРКА И НАСТРОЙКА СКАНЕРА ###
echo "[+] Настройка прав доступа для сканера..."

# Создаем правило udev для сканера QR-кодов
cat > /etc/udev/rules.d/99-qr-scanner.rules <<'EOF'
# Правила для HID сканеров
SUBSYSTEM=="input", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="e024", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="input", ATTRS{idVendor}=="1a2c", ATTRS{idProduct}=="2124", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="input", ATTRS{idVendor}=="0c2e", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1a86", MODE="0666"
SUBSYSTEM=="usb", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="e024", MODE="0666"
SUBSYSTEM=="input", KERNEL=="event[0-9]*", MODE="0660", GROUP="plugdev"

# Устройство HID гаджета
SUBSYSTEM=="usb", KERNEL=="gadget", MODE="0666"
SUBSYSTEM=="misc", KERNEL=="hidg*", MODE="0666"
EOF

# Создаем группу plugdev если её нет
getent group plugdev >/dev/null || groupadd plugdev
usermod -a -G plugdev root

# Перезагружаем правила udev
udevadm control --reload-rules
udevadm trigger

### 6. УЛУЧШЕННЫЙ СКРИПТ ОБРАБОТКИ QR-КОДОВ ###
echo "[+] Установка Python скрипта обработки QR-кодов..."

cat > /opt/production_scanner.py <<'EOF'
#!/usr/bin/env python3
"""
Улучшенный обработчик QR-кодов для Orange Pi Zero 2W
Поддерживает сегментированный вывод и автоматическое восстановление
"""
import evdev
from evdev import ecodes, InputDevice, list_devices
import os
import time
import sys
import select
import threading
import subprocess
from pathlib import Path

# Конфигурация
SEGMENT = __SEGMENT__
HID_DEVICE = "/dev/hidg0"
LOG_FILE = "/var/log/production_scanner.log"
SCANNER_TIMEOUT = 30  # секунд для ожидания сканера

def log(message, level="INFO"):
    """Запись в лог с меткой времени"""
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    full_msg = f"[{timestamp}] [{level}] {message}"
    
    # Вывод в консоль
    print(full_msg)
    
    # Запись в файл
    try:
        with open(LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(full_msg + '\n')
    except Exception as e:
        print(f"Ошибка записи в лог: {e}")

class KeyboardMapper:
    """Расширенный маппер клавиш с поддержкой комбинаций"""
    
    def __init__(self):
        # Базовые мапы
        self.keymap_no_shift = {
            # Цифры
            2: '1', 3: '2', 4: '3', 5: '4', 6: '5', 
            7: '6', 8: '7', 9: '8', 10: '9', 11: '0',
            
            # Буквы (верхний ряд)
            16: 'q', 17: 'w', 18: 'e', 19: 'r', 20: 't', 
            21: 'y', 22: 'u', 23: 'i', 24: 'o', 25: 'p',
            
            # Буквы (средний ряд)
            30: 'a', 31: 's', 32: 'd', 33: 'f', 34: 'g',
            35: 'h', 36: 'j', 37: 'k', 38: 'l',
            
            # Буквы (нижний ряд)
            44: 'z', 45: 'x', 46: 'c', 47: 'v', 48: 'b',
            49: 'n', 50: 'm',
            
            # Специальные символы
            12: '-', 13: '=', 26: '[', 27: ']', 43: '\\',
            39: ';', 40: "'", 41: '`', 51: ',', 52: '.', 53: '/',
            57: ' ', 28: '\n',
            
            # Цифровая клавиатура
            79: '1', 80: '2', 81: '3', 75: '4', 76: '5',
            77: '6', 71: '7', 72: '8', 73: '9', 82: '0',
            83: '.', 74: '-', 78: '+', 55: '*', 98: '/'
        }
        
        self.keymap_shift = {
            # Цифры с Shift
            2: '!', 3: '@', 4: '#', 5: '$', 6: '%',
            7: '^', 8: '&', 9: '*', 10: '(', 11: ')',
            
            # Буквы с Shift
            16: 'Q', 17: 'W', 18: 'E', 19: 'R', 20: 'T',
            21: 'Y', 22: 'U', 23: 'I', 24: 'O', 25: 'P',
            30: 'A', 31: 'S', 32: 'D', 33: 'F', 34: 'G',
            35: 'H', 36: 'J', 37: 'K', 38: 'L',
            44: 'Z', 45: 'X', 46: 'C', 47: 'V', 48: 'B',
            49: 'N', 50: 'M',
            
            # Специальные символы с Shift
            12: '_', 13: '+', 26: '{', 27: '}', 43: '|',
            39: ':', 40: '"', 41: '~', 51: '<', 52: '>', 53: '?'
        }
        
        # HID коды
        self.hid_codes = {
            'a': 0x04, 'b': 0x05, 'c': 0x06, 'd': 0x07, 'e': 0x08,
            'f': 0x09, 'g': 0x0a, 'h': 0x0b, 'i': 0x0c, 'j': 0x0d,
            'k': 0x0e, 'l': 0x0f, 'm': 0x10, 'n': 0x11, 'o': 0x12,
            'p': 0x13, 'q': 0x14, 'r': 0x15, 's': 0x16, 't': 0x17,
            'u': 0x18, 'v': 0x19, 'w': 0x1a, 'x': 0x1b, 'y': 0x1c,
            'z': 0x1d,
            '1': 0x1e, '2': 0x1f, '3': 0x20, '4': 0x21, '5': 0x22,
            '6': 0x23, '7': 0x24, '8': 0x25, '9': 0x26, '0': 0x27,
            ' ': 0x2c, '-': 0x2d, '=': 0x2e, '[': 0x2f, ']': 0x30,
            '\\': 0x31, ';': 0x33, "'": 0x34, '`': 0x35, ',': 0x36,
            '.': 0x37, '/': 0x38, '\n': 0x28
        }
        
        # Shift комбинации
        self.shift_combinations = {
            '!': (0x1e, 0x02), '@': (0x1f, 0x02), '#': (0x20, 0x02),
            '$': (0x21, 0x02), '%': (0x22, 0x02), '^': (0x23, 0x02),
            '&': (0x24, 0x02), '*': (0x25, 0x02), '(': (0x26, 0x02),
            ')': (0x27, 0x02), '_': (0x2d, 0x02), '+': (0x2e, 0x02),
            '{': (0x2f, 0x02), '}': (0x30, 0x02), '|': (0x31, 0x02),
            ':': (0x33, 0x02), '"': (0x34, 0x02), '~': (0x35, 0x02),
            '<': (0x36, 0x02), '>': (0x37, 0x02), '?': (0x38, 0x02),
            
            # Заглавные буквы
            'A': (0x04, 0x02), 'B': (0x05, 0x02), 'C': (0x06, 0x02),
            'D': (0x07, 0x02), 'E': (0x08, 0x02), 'F': (0x09, 0x02),
            'G': (0x0a, 0x02), 'H': (0x0b, 0x02), 'I': (0x0c, 0x02),
            'J': (0x0d, 0x02), 'K': (0x0e, 0x02), 'L': (0x0f, 0x02),
            'M': (0x10, 0x02), 'N': (0x11, 0x02), 'O': (0x12, 0x02),
            'P': (0x13, 0x02), 'Q': (0x14, 0x02), 'R': (0x15, 0x02),
            'S': (0x16, 0x02), 'T': (0x17, 0x02), 'U': (0x18, 0x02),
            'V': (0x19, 0x02), 'W': (0x1a, 0x02), 'X': (0x1b, 0x02),
            'Y': (0x1c, 0x02), 'Z': (0x1d, 0x02)
        }
    
    def get_char(self, keycode, shift_pressed=False):
        """Получить символ по коду клавиши"""
        if shift_pressed:
            return self.keymap_shift.get(keycode, '')
        return self.keymap_no_shift.get(keycode, '')
    
    def get_hid_code(self, char):
        """Получить HID код для символа"""
        if char in self.shift_combinations:
            return self.shift_combinations[char]
        elif char.lower() in self.hid_codes:
            # Для строчных букв без Shift
            if char.isupper():
                return (self.hid_codes[char.lower()], 0x02)
            else:
                return (self.hid_codes[char], 0)
        return None

class HIDTransmitter:
    """Класс для отправки HID событий"""
    
    def __init__(self, hid_device):
        self.hid_device = hid_device
        self.last_send_time = 0
        self.min_interval = 0.01  # 10ms между отправками
        
    def send_key(self, code, modifier=0):
        """Отправить нажатие клавиши"""
        try:
            # Защита от слишком частой отправки
            current_time = time.time()
            elapsed = current_time - self.last_send_time
            if elapsed < self.min_interval:
                time.sleep(self.min_interval - elapsed)
            
            # Отправка нажатия
            with open(self.hid_device, 'wb', buffering=0) as h:
                # Key down
                h.write(bytes([modifier, 0, code, 0, 0, 0, 0, 0]))
                time.sleep(0.005)
                # Key up
                h.write(b'\x00' * 8)
                time.sleep(0.005)
            
            self.last_send_time = time.time()
            return True
            
        except Exception as e:
            log(f"Ошибка отправки HID: {e}", "ERROR")
            return False
    
    def send_string(self, text):
        """Отправить строку посимвольно"""
        log(f"Отправка строки: '{text}'")
        success_count = 0
        
        mapper = KeyboardMapper()
        
        for char in text:
            hid_data = mapper.get_hid_code(char)
            if hid_data:
                code, modifier = hid_data
                if self.send_key(code, modifier):
                    success_count += 1
                else:
                    log(f"Не удалось отправить символ: '{char}'", "WARNING")
            else:
                log(f"Неизвестный символ: '{char}' (код: {ord(char)})", "WARNING")
        
        log(f"Отправлено {success_count}/{len(text)} символов")
        return success_count > 0

class QRScanner:
    """Основной класс обработки QR-кодов"""
    
    def __init__(self, segment):
        self.segment = segment
        self.mapper = KeyboardMapper()
        self.transmitter = HIDTransmitter(HID_DEVICE)
        self.scanner_device = None
        self.running = True
        self.buffer = ""
        self.shift_pressed = False
        
    def find_scanner(self):
      """Найти устройство сканера"""
      log("Поиск устройства сканера...")
      
      try:
          paths = list_devices()
          
          if not paths:
              log("Нет доступных устройств!")
              return None
              
          devices = [InputDevice(path) for path in paths]
          
          # Приоритетный поиск по признакам сканера
          scanner_patterns = ['scanner', 'qr', 'barcode', 'keyboard', 'usb', 'input']
          
          for device in devices:
              device_info = f"{device.name} ({device.path})"
              log(f"Проверяем: {device_info}")
              
              # Проверяем поддержку клавиш
              try:
                  caps = device.capabilities()
                  if ecodes.EV_KEY in caps:
                      #log(f"  Поддерживает EV_KEY")
                      # Проверяем по имени
                      lower_name = device.name.lower()
                      for pattern in scanner_patterns:
                          if pattern in lower_name:
                              log(f"  Найден сканер по паттерну '{pattern}': {device_info}")
                              return device
                      
              except Exception as e:
                  log(f"  Ошибка проверки устройства: {e}")
                  continue
          
          # Если не нашли специфичное устройство, берем первое с поддержкой EV_KEY
          for device in devices:
              try:
                  if ecodes.EV_KEY in device.capabilities():
                      log(f"Используем первое устройство с клавишами: {device.name}")
                      return device
              except:
                  continue
          
          # Если совсем ничего не нашли, берем первое устройство
          if devices:
              log(f"Используем первое доступное устройство: {devices[0].name}")
              return devices[0]
          
      except Exception as e:
          log(f"Ошибка поиска сканера: {e}", "ERROR")
      
      return None
    
    def process_event(self, event):
        """Обработать событие от устройства"""
        if event.type == ecodes.EV_KEY:
            # Обработка Shift
            if event.code in [ecodes.KEY_LEFTSHIFT, ecodes.KEY_RIGHTSHIFT]:
                self.shift_pressed = (event.value == 1)
                return
            
            # Только нажатия клавиш
            if event.value == 1:
                char = self.mapper.get_char(event.code, self.shift_pressed)
                
                if char:
                    if char == '\n':
                        # Обработка завершения сканирования
                        self.process_complete_scan()
                    else:
                        # Добавление символа в буфер
                        self.buffer += char
                        log(f"Буфер: '{self.buffer}'")
    
    def process_complete_scan(self):
        """Обработать завершенный отсканированный код"""
        if not self.buffer:
            log("Пустой буфер, игнорирую", "WARNING")
            return
        
        log(f"Считан QR-код: '{self.buffer}'")
        
        # Разделение по точке с запятой
        parts = [part.strip() for part in self.buffer.split(';')]
        log(f"Сегменты: {parts}")
        
        # Проверка доступности нужного сегмента
        if self.segment - 1 < len(parts):
            selected_segment = parts[self.segment - 1]
            log(f"Выбран сегмент {self.segment}: '{selected_segment}'")
            
            # Отправка через HID
            if self.transmitter.send_string(selected_segment):
                log("Успешно отправлено")
            else:
                log("Ошибка отправки", "ERROR")
        else:
            log(f"Сегмент {self.segment} недоступен. Всего сегментов: {len(parts)}", "WARNING")
        
        # Сброс буфера
        self.buffer = ""
    
    def health_check(self):
        """Проверка состояния системы"""
        # Проверка HID устройства
        if not os.path.exists(HID_DEVICE):
            log(f"HID устройство {HID_DEVICE} не найдено", "WARNING")
            return False
        
        # Проверка доступности устройства сканера
        if not self.scanner_device or not os.path.exists(self.scanner_device.path):
            log("Устройство сканера недоступно", "WARNING")
            return False
        
        return True
    
    def run(self):
        """Основной цикл обработки"""
        log(f"Запуск Production Scanner (сегмент: {self.segment})")
        
        # Поиск устройства
        self.scanner_device = self.find_scanner()
        if not self.scanner_device:
            log("Сканер не найден!", "ERROR")
            return False
        
        log(f"Найдено устройство: {self.scanner_device.name}")
        
        # Grab устройство для эксклюзивного доступа
        try:
            self.scanner_device.grab()
            log(f"Захвачено устройство: {self.scanner_device.name}")
        except Exception as e:
            log(f"Не удалось захватить устройство: {e}", "WARNING")
        
        log("Готов к сканированию. Ожидание QR-кодов...")
        
        # Основной цикл обработки событий
        try:
            while self.running:
                # Периодическая проверка здоровья
                if time.time() % 10 < 0.1:  # Каждые ~10 секунд
                    if not self.health_check():
                        log("Проблема с оборудованием, попытка восстановления...", "WARNING")
                
                # Чтение событий с прямым использованием read_loop (проверенная версия)
                try:
                    # Используем read_loop без аргументов - совместимо с evdev 1.6
                    for event in self.scanner_device.read_loop():
                        self.process_event(event)
                        
                except BlockingIOError:
                    # Нет событий, продолжаем
                    continue
                except OSError as e:
                    log(f"Ошибка чтения устройства: {e}", "ERROR")
                    break
                except Exception as e:
                    log(f"Ошибка в цикле чтения: {e}", "ERROR")
                    time.sleep(0.1)
                    continue
                        
        except KeyboardInterrupt:
            log("Остановлено пользователем", "INFO")
        except Exception as e:
            log(f"Критическая ошибка: {e}", "ERROR")
        finally:
            # Освобождение устройства
            try:
                self.scanner_device.ungrab()
            except:
                pass
            log("Сканер остановлен")
        
        return True

def main():
    """Основная функция"""
    log("=" * 50)
    log("Запуск Production Scanner")
    log(f"Версия для Orange Pi Zero 2W")
    log(f"Целевой сегмент: {SEGMENT}")
    log("=" * 50)
    
    # Создаем и запускаем сканер
    scanner = QRScanner(SEGMENT)
    
    # Попытки перезапуска при ошибках
    max_retries = 3
    retry_delay = 5
    
    for attempt in range(max_retries):
        log(f"Попытка {attempt + 1}/{max_retries}")
        
        if scanner.run():
            log("Сканер завершил работу нормально")
            break
        else:
            if attempt < max_retries - 1:
                log(f"Перезапуск через {retry_delay} секунд...")
                time.sleep(retry_delay)
            else:
                log("Достигнут лимит попыток перезапуска", "ERROR")
    
    log("Программа завершена")

if __name__ == "__main__":
    main()
EOF

# Заменяем номер сегмента в Python скрипте
sed -i "s/__SEGMENT__/$SEGMENT/g" /opt/production_scanner.py
chmod +x /opt/production_scanner.py

# Устанавливаем зависимости Python
echo "[+] Установка Python зависимостей через apt..."
apt-get install -y python3-evdev python3-systemd

# Если пакеты недоступны через apt, используем экстренный метод:
if ! python3 -c "import evdev" 2>/dev/null; then
    echo "[!] Пакет evdev не установлен, используем --break-system-packages"
    python3 -m pip install --break-system-packages evdev systemd-python || {
        echo "[!] Создаем виртуальное окружение..."
        python3 -m venv /opt/scanner_venv
        /opt/scanner_venv/bin/pip install evdev systemd-python
        sed -i "1s|^.*$|#!/opt/scanner_venv/bin/python3|" /opt/production_scanner.py
    }
fi

### 7. СИСТЕМНЫЕ СЕРВИСЫ ###
echo "[+] Настройка systemd сервисов..."

# Сервис активации OTG режима
cat > /etc/systemd/system/enable-otg.service <<'EOF'
[Unit]
Description=Enable USB OTG Mode for Orange Pi Zero 2W
After=local-fs.target
Before=hid-gadget.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/enable-otg-mode.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Сервис HID гаджета (упрощенный)
cat > /etc/systemd/system/hid-gadget.service <<'EOF'
[Unit]
Description=USB HID Gadget for QR Scanner
After=enable-otg.service
Requires=enable-otg.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-hid-gadget.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Основной сервис сканера
cat > /etc/systemd/system/production-scanner.service <<'EOF'
[Unit]
Description=Production QR Code Scanner
After=hid-gadget.service network.target
Requires=hid-gadget.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/production_scanner.py
Restart=always
RestartSec=10
User=root
Group=root
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal
StandardError=journal
WatchdogSec=300

# Ограничения для стабильности
ProtectSystem=strict
ReadWritePaths=/var/log /tmp
PrivateTmp=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

# Сервис мониторинга
cat > /etc/systemd/system/scanner-monitor.service <<'EOF'
[Unit]
Description=Scanner Health Monitor
After=production-scanner.service

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do if ! systemctl is-active --quiet production-scanner.service; then echo "[MONITOR] Scanner service stopped, restarting..." | tee -a /var/log/production_scanner.log; systemctl restart production-scanner.service; fi; sleep 30; done'
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

# Перезагрузка systemd и включение сервисов
systemctl daemon-reload

echo "[+] Включение сервисов..."
systemctl enable enable-otg.service hid-gadget.service production-scanner.service

# Не включаем монитор по умолчанию (опционально)
# systemctl enable scanner-monitor.service

### 8. НАСТРОЙКА ЛОГИРОВАНИЯ ###
echo "[+] Настройка логирования..."

# Расширенная конфигурация logrotate
cat > /etc/logrotate.d/production_scanner <<'EOF'
/var/log/production_scanner.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
    postrotate
        systemctl reload production-scanner.service >/dev/null 2>&1 || true
    endscript
}

/var/log/hid-gadget.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0644 root root
}

/var/log/otg-setup.log {
    weekly
    rotate 2
    compress
    missingok
    notifempty
    create 0644 root root
}
EOF

### 9. ФИНАЛЬНАЯ ПРОВЕРКА И ЗАПУСК ###
echo "[+] Финальная проверка..."

# Проверяем необходимые компоненты
echo "[+] Проверка компонентов:"

# 1. Проверка Python скрипта
if [ -f /opt/production_scanner.py ]; then
  echo "[✓] Python скрипт установлен"
  python3 -m py_compile /opt/production_scanner.py && echo "[✓] Синтаксис Python скрипта корректен"
fi

# 2. Проверка сервисов
for service in enable-otg hid-gadget production-scanner; do
  if systemctl is-enabled "${service}.service" >/dev/null 2>&1; then
    echo "[✓] Сервис $service включен"
  else
    echo "[!] Сервис $service не включен"
  fi
done

# 3. Проверка прав доступа
if [ -d /sys/kernel/config/usb_gadget ]; then
  echo "[✓] ConfigFS доступен"
else
  echo "[!] ConfigFS не доступен"
fi

# 4. Информация о системе
echo "[+] Информация о системе:"
echo "    Модель: $MODEL"
echo "    Ядро: $(uname -r)"
echo "    Python: $(python3 --version 2>/dev/null || echo 'Не найден')"

### 10. ЗАПУСК СЕРВИСОВ ###
echo "[+] Запуск сервисов..."

# Запускаем в правильном порядке
systemctl start enable-otg.service
sleep 2
systemctl start hid-gadget.service
sleep 2
if systemctl list-unit-files | grep -q production-scanner.service; then
  if systemctl is-active production-scanner.service >/dev/null 2>&1; then
    systemctl restart production-scanner.service
  else
    systemctl start production-scanner.service
  fi
fi

# Проверяем статус
echo "[+] Статус сервисов:"
for service in enable-otg hid-gadget production-scanner; do
  if systemctl is-active --quiet "${service}.service"; then
    echo "[✓] $service.service работает"
  else
    echo "[!] $service.service НЕ РАБОТАЕТ"
    echo "[+] Логи: journalctl -u ${service}.service -n 20"
  fi
done

### 11. ИНСТРУКЦИЯ ПО УСТРАНЕНИЮ НЕПОЛАДОК ###
cat > /root/scanner-troubleshooting.txt <<'EOF'
УСТРАНЕНИЕ НЕПОЛАДОК PRODUCTION SCANNER
=======================================

1. ПРОВЕРКА СТАТУСА:
   sudo systemctl status production-scanner.service
   sudo journalctl -u production-scanner.service -f

2. ПРОВЕРКА USB OTG:
   ls /sys/class/udc/                    # Должен показать устройство
   ls /sys/kernel/config/usb_gadget/     # Должна быть папка hid_keyboard

3. ПРОВЕРКА СКАНЕРА:
   lsusb                                 # Должен показать подключенный сканер
   evtest                                # Для тестирования событий сканера

4. ЛОГИ:
   tail -f /var/log/production_scanner.log
   tail -f /var/log/hid-gadget.log

5. ПЕРЕЗАГРУЗКА СЕРВИСОВ:
   sudo systemctl restart enable-otg hid-gadget production-scanner

6. ЕСЛИ НЕ РАБОТАЕТ OTG:
   - Убедитесь что в /boot/armbianEnv.txt НЕТ usb0-device
   - Проверьте питание (нужно внешнее питание через GPIO)
   - Попробуйте другой USB кабель

7. ТЕСТОВЫЕ КОМАНДЫ:
   echo "test" > /dev/hidg0             # Проверка HID вывода
   python3 /opt/production_scanner.py   # Запуск вручную
EOF

echo "[+] ========================================="
echo "[✓] УСТАНОВКА ЗАВЕРШЕНА!"
echo "[+] ========================================="
echo ""
echo "КРАТКАЯ ИНСТРУКЦИЯ:"
echo "1. Подключите сканер QR-кодов к USB порту"
echo "2. Подключите Orange Pi Zero 2W к ПК через USB-C"
echo "3. Сканер должен эмулировать клавиатуру и отправлять выбранный сегмент"
echo ""
echo "КОМАНДЫ УПРАВЛЕНИЯ:"
echo "  Просмотр логов:      sudo tail -f /var/log/production_scanner.log"
echo "  Статус сервисов:     sudo systemctl status production-scanner"
echo "  Перезапуск:          sudo systemctl restart production-scanner"
echo "  Проверка HID:        ls /sys/class/udc/"
echo ""
echo "Сегмент для извлечения: $SEGMENT (часть после разделителя ';')"
echo ""

# Предупреждение о перезагрузке
if grep -q "usb0-device" /boot/armbianEnv.txt 2>/dev/null; then
  echo "[!] ВНИМАНИЕ: В armbianEnv.txt обнаружен usb0-device"
  echo "[!] Это может вызвать проблемы с загрузкой!"
  echo "[!] Рекомендуется проверить файл: /boot/armbianEnv.txt"
  echo "[!] И удалить 'usb0-device' если он есть"
fi

echo "[+] Подробная инструкция по устранению неполадок: /root/scanner-troubleshooting.txt"
echo "[+] Лог установки: $LOG"

# Запускаем тестовую проверку через 10 секунд
(sleep 10; echo "[+] Тестовая проверка через 10 секунд..."; systemctl is-active production-scanner.service && echo "[✓] Сервис активен" || echo "[!] Сервис не активен") &

exit 0

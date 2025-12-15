#!/bin/bash
# production-scanner-install.sh
# Установка Production Scanner для Orange Pi Zero H3
# Запуск: sudo bash install_scanner.sh <номер_сегмента>

set -e

# ================= КОНФИГУРАЦИЯ =================
SEGMENT="${1:-1}"  # По умолчанию второй сегмент
LOG_FILE="/var/log/scanner-install.log"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ================= ФУНКЦИИ =================
log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}✅ $1${NC}" | tee -a "$LOG_FILE"; }
warning() { echo -e "${YELLOW}⚠️  $1${NC}" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}❌ $1${NC}" | tee -a "$LOG_FILE"; }

# ================= ПРОВЕРКА =================
check_prerequisites() {
    log "Проверка предварительных условий..."
    
    if [[ $EUID -ne 0 ]]; then
        error "Запускай с sudo!"
        exit 1
    fi
    
    if ! [[ "$SEGMENT" =~ ^[0-2]$ ]]; then
        error "Сегмент должен быть 0, 1 или 2"
        echo "Использование: sudo bash $0 <сегмент>"
        echo "  0 = первый (123;456;789 → 123)"
        echo "  1 = второй (123;456;789 → 456)"
        echo "  2 = третий (123;456;789 → 789)"
        exit 1
    fi
    
    success "Используется сегмент: $SEGMENT"
}

# ================= ВОССТАНОВЛЕНИЕ СИСТЕМЫ =================
cleanup_system() {
    log "Восстановление системы..."
    
    # Останавливаем сервисы
    systemctl stop production-scanner.service 2>/dev/null || true
    systemctl disable production-scanner.service 2>/dev/null || true
    systemctl stop production-scanner.timer 2>/dev/null || true
    systemctl disable production-scanner.timer 2>/dev/null || true
    
    # Удаляем модули
    rmmod g_serial 2>/dev/null || true
    rmmod g_hid 2>/dev/null || true
    rmmod libcomposite 2>/dev/null || true
    
    # Удаляем старые файлы
    rm -f /etc/systemd/system/production-scanner.service
    rm -f /etc/systemd/system/production-scanner.timer
    rm -f /usr/local/bin/setup_hid_gadget.sh
    rm -f /usr/local/bin/test-scanner.sh
    rm -f /opt/production_scanner.py
    
    # Восстанавливаем armbianEnv.txt
    if [[ -f /boot/armbianEnv.txt ]]; then
        log "Восстановление /boot/armbianEnv.txt..."
        # Удаляем usb0-device из overlays если есть
        sed -i 's/usb0-device//g' /boot/armbianEnv.txt
        sed -i 's/,,/,/g' /boot/armbianEnv.txt
        sed -i 's/overlays=,/overlays=/g' /boot/armbianEnv.txt
        sed -i 's/,$//g' /boot/armbianEnv.txt
        
        # Оставляем только usbhost2 usbhost3
        if grep -q "overlays=" /boot/armbianEnv.txt; then
            CURRENT=$(grep "^overlays=" /boot/armbianEnv.txt | head -1)
            if [[ "$CURRENT" != *"usbhost2"* ]] || [[ "$CURRENT" != *"usbhost3"* ]]; then
                sed -i "s/^overlays=.*/overlays=usbhost2 usbhost3/" /boot/armbianEnv.txt
            fi
        fi
    fi
    
    success "Система восстановлена"
}

# ================= УСТАНОВКА ПАКЕТОВ =================
install_packages() {
    log "Установка пакетов..."
    
    apt-get update 2>&1 | tee -a "$LOG_FILE"
    
    # Базовые пакеты
    local packages=(
        python3
        python3-pip
        python3-serial
        python3-venv
        git
        xxd
        usbutils
        psmisc  # Для killall
    )
    
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            log "Установка $pkg..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"
        fi
    done
    
    # Python библиотеки
    if ! python3 -c "import evdev" 2>/dev/null; then
        if apt-cache show python3-evdev >/dev/null 2>&1; then
            apt-get install -y python3-evdev 2>&1 | tee -a "$LOG_FILE"
        else
            python3 -m pip install evdev --break-system-packages 2>&1 | tee -a "$LOG_FILE"
        fi
    fi
    
    success "Пакеты установлены"
}

# ================= СОЗДАНИЕ HID СКРИПТА =================
create_hid_script() {
    log "Создание скрипта HID..."
    
    cat > /usr/local/bin/setup_hid.sh << 'EOF'
#!/bin/bash
# Настройка HID клавиатуры для Orange Pi Zero H3
# Версия 2.0 - Исправленная

set -e

LOG="/tmp/hid-setup-$(date +%s).log"
echo "🔧 Настройка HID ($(date))" > "$LOG"

cleanup() {
    echo "🧹 Очистка..." >> "$LOG"
    # Удаляем старые гаджеты
    cd /sys/kernel/config/usb_gadget/ 2>/dev/null && {
        rm -rf g1 keyboard hid_gadget 2>/dev/null || true
    } >> "$LOG" 2>&1
    
    # Выгружаем модули
    rmmod g_hid 2>/dev/null || true
    rmmod g_serial 2>/dev/null || true
    rmmod libcomposite 2>/dev/null || true
    sleep 1
}

load_modules() {
    echo "📦 Загрузка модулей..." >> "$LOG"
    modprobe configfs 2>/dev/null || true
    modprobe libcomposite 2>/dev/null || true
    modprobe usb_f_hid 2>/dev/null || true
    
    # Для Orange Pi
    modprobe sunxi_udc 2>/dev/null || true
    modprobe sunxi_usb_udc 2>/dev/null || true
    
    # Монтируем configfs
    mount -t configfs none /sys/kernel/config 2>/dev/null || true
    sleep 1
}

create_gadget() {
    echo "🏗️  Создание гаджета..." >> "$LOG"
    cd /sys/kernel/config/usb_gadget/ || {
        echo "❌ Нет configfs" >> "$LOG"
        return 1
    }
    
    # Создаем директорию
    mkdir -p hid_keyboard
    cd hid_keyboard
    
    # Базовые настройки
    echo 0x1d6b > idVendor
    echo 0x0104 > idProduct
    echo 0x0100 > bcdDevice
    echo 0x0200 > bcdUSB
    
    # Информация
    mkdir -p strings/0x409
    echo "Production Scanner" > strings/0x409/manufacturer
    echo "HID Keyboard" > strings/0x409/product
    echo "001" > strings/0x409/serialnumber
    
    # Конфигурация
    mkdir -p configs/c.1/strings/0x409
    echo "Keyboard Config" > configs/c.1/strings/0x409/configuration
    echo 250 > configs/c.1/MaxPower
    
    # HID функция
    mkdir -p functions/hid.usb0
    echo 1 > functions/hid.usb0/protocol     # 1 = Keyboard
    echo 1 > functions/hid.usb0/subclass     # 1 = Boot interface
    echo 8 > functions/hid.usb0/report_length
    
    # Дескриптор клавиатуры HID (стандартный)
    echo -ne '\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0' > functions/hid.usb0/report_desc
    
    # Связываем
    ln -sf functions/hid.usb0 configs/c.1/
    
    echo "✅ Гаджет создан" >> "$LOG"
}

activate_gadget() {
    echo "🚀 Активация..." >> "$LOG"
    
    # Ищем UDC
    local udc_found=""
    for udc in /sys/class/udc/*; do
        if [[ -e "$udc" ]]; then
            udc_name=$(basename "$udc")
            echo "Найден UDC: $udc_name" >> "$LOG"
            
            # Пробуем активировать
            if echo "$udc_name" > UDC 2>/dev/null; then
                udc_found="$udc_name"
                echo "Активирован: $udc_name" >> "$LOG"
                break
            fi
        fi
    done
    
    # Если не нашли, пробуем стандартные
    if [[ -z "$udc_found" ]]; then
        echo "Поиск стандартных UDC..." >> "$LOG"
        for udc in "musb-hdrc.2.auto" "musb-hdrc.1.auto" "musb-hdrc.0.auto" "musb-hdrc"; do
            if echo "$udc" > UDC 2>/dev/null; then
                udc_found="$udc"
                echo "Активирован по имени: $udc" >> "$LOG"
                break
            fi
        done
    fi
    
    if [[ -n "$udc_found" ]]; then
        echo "UDC: $udc_found" >> "$LOG"
        return 0
    else
        echo "❌ Не удалось активировать UDC" >> "$LOG"
        return 1
    fi
}

main() {
    echo "=== НАЧАЛО НАСТРОЙКИ HID ==="
    
    cleanup
    load_modules
    create_gadget
    activate_gadget
    
    # Ждем создание устройства
    echo "⏳ Ожидание устройства..." >> "$LOG"
    for i in {1..15}; do
        if [[ -e "/dev/hidg0" ]]; then
            echo "✅ УСПЕХ! HID создан: /dev/hidg0"
            echo "✅ HID создан: /dev/hidg0" >> "$LOG"
            echo "   Лог: $LOG"
            return 0
        fi
        sleep 0.5
    done
    
    echo "❌ HID не создан"
    echo "❌ HID не создан" >> "$LOG"
    echo "   Проверь: cat $LOG"
    echo "   Проверь: dmesg | tail -20"
    return 1
}

main "$@"
EOF
    
    chmod +x /usr/local/bin/setup_hid.sh
    success "Скрипт HID создан"
}

# ================= СОЗДАНИЕ ГЛАВНОГО СКРИПТА =================
create_main_script() {
    log "Создание главного скрипта..."
    
    cat > /opt/production_scanner.py << 'SCRIPT_EOF'
#!/usr/bin/env python3
"""
🏭 PRODUCTION SCANNER для Orange Pi Zero H3
📟 QR-сканер → HID клавиатура → Станок
"""

import os
import sys
import time
import serial
import glob
from datetime import datetime

# ================= КОНФИГУРАЦИЯ =================
HID_DEVICE = "/dev/hidg0"
SEGMENT_NUMBER = __SEGMENT_NUMBER__
LOG_FILE = "/var/log/scanner.log"

# ================= КАРТА КЛАВИШ =================
HID_KEYMAP = {
    # Цифры
    '0': 0x27, '1': 0x1E, '2': 0x1F, '3': 0x20, '4': 0x21,
    '5': 0x22, '6': 0x23, '7': 0x24, '8': 0x25, '9': 0x26,
    
    # Латинские буквы (строчные)
    'a': 0x04, 'b': 0x05, 'c': 0x06, 'd': 0x07, 'e': 0x08,
    'f': 0x09, 'g': 0x0A, 'h': 0x0B, 'i': 0x0C, 'j': 0x0D,
    'k': 0x0E, 'l': 0x0F, 'm': 0x10, 'n': 0x11, 'o': 0x12,
    'p': 0x13, 'q': 0x14, 'r': 0x15, 's': 0x16, 't': 0x17,
    'u': 0x18, 'v': 0x19, 'w': 0x1A, 'x': 0x1B, 'y': 0x1C,
    'z': 0x1D,
    
    # Специальные символы
    ' ': 0x2C,          # Space
    '-': 0x2D,          # Minus
    '=': 0x2E,          # Equal
    '[': 0x2F,          # Left bracket
    ']': 0x30,          # Right bracket
    '\\': 0x31,         # Backslash
    ';': 0x33,          # Semicolon
    "'": 0x34,          # Quote
    '`': 0x35,          # Grave
    ',': 0x36,          # Comma
    '.': 0x37,          # Period
    '/': 0x38,          # Slash
    
    # Специальные символы с Shift
    '_': (0x2D, 0x02),   # Shift + -
    '+': (0x2E, 0x02),   # Shift + =
    '{': (0x2F, 0x02),   # Shift + [
    '}': (0x30, 0x02),   # Shift + ]
    '|': (0x31, 0x02),   # Shift + \
    ':': (0x33, 0x02),   # Shift + ;
    '"': (0x34, 0x02),   # Shift + '
    '~': (0x35, 0x02),   # Shift + `
    '<': (0x36, 0x02),   # Shift + ,
    '>': (0x37, 0x02),   # Shift + .
    '?': (0x38, 0x02),   # Shift + /
    
    # Цифровые символы с Shift
    '!': (0x1E, 0x02),   # Shift + 1
    '@': (0x1F, 0x02),   # Shift + 2
    '#': (0x20, 0x02),   # Shift + 3
    '$': (0x21, 0x02),   # Shift + 4
    '%': (0x22, 0x02),   # Shift + 5
    '^': (0x23, 0x02),   # Shift + 6
    '&': (0x24, 0x02),   # Shift + 7
    '*': (0x25, 0x02),   # Shift + 8
    '(': (0x26, 0x02),   # Shift + 9
    ')': (0x27, 0x02),   # Shift + 0
    
    # Управляющие клавиши
    '\n': 0x28,  # Enter
    '\t': 0x2B,  # Tab
    '\b': 0x2A,  # Backspace
}

# ================= ЛОГГИНГ =================
def log(message, level="INFO"):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_line = f"[{timestamp}] [{level}] {message}"
    
    print(f"📝 {log_line}")
    
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(log_line + "\n")
    except Exception:
        pass

# ================= HID КЛАВИАТУРА =================
class HIDKeyboard:
    def __init__(self, device=HID_DEVICE):
        self.device = device
        
    def send_key(self, keycode, modifiers=0):
        try:
            with open(self.device, "wb") as hid:
                report = bytes([
                    modifiers, 0, keycode, 0, 0, 0, 0, 0
                ])
                hid.write(report)
                time.sleep(0.01)
                
                hid.write(bytes([0]*8))
                time.sleep(0.01)
            return True
        except Exception as e:
            log(f"Ошибка отправки: {e}", "ERROR")
            return False
    
    def type_string(self, text):
        log(f"⌨️  Ввод: '{text}'")
        
        for char in text:
            if char in HID_KEYMAP:
                key_info = HID_KEYMAP[char]
                
                if isinstance(key_info, tuple):
                    keycode, modifiers = key_info
                else:
                    keycode = key_info
                    modifiers = 0x02 if char.isupper() else 0
                
                for attempt in range(3):
                    if self.send_key(keycode, modifiers):
                        break
                    time.sleep(0.05)
            else:
                log(f"⚠️  Неподдерживаемый символ: '{char}'", "WARNING")
        
        # Enter в конце
        self.send_key(HID_KEYMAP['\n'])
        log("↵ Enter отправлен")
        return True

# ================= АВТОПОИСК СКАНЕРА =================
def find_scanner_port():
    """Автоматический поиск порта сканера"""
    ports = []
    
    for pattern in ["ttyUSB*", "ttyACM*"]:
        ports.extend(glob.glob(f"/dev/{pattern}"))
    
    if not ports:
        ports = ["/dev/ttyUSB0", "/dev/ttyUSB1", "/dev/ttyACM0"]
    
    for port in ports:
        if os.path.exists(port):
            try:
                test_ser = serial.Serial(port, timeout=0.1)
                test_ser.close()
                return port
            except Exception:
                continue
    
    return None

# ================= ЧТЕНИЕ СКАНЕРА =================
def read_from_scanner():
    port = find_scanner_port()
    if not port:
        log("⚠️  Сканер не найден", "WARNING")
        return None
    
    try:
        with serial.Serial(
            port=port,
            baudrate=9600,
            timeout=1,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE
        ) as scanner:
            
            scanner.reset_input_buffer()
            
            while True:
                if scanner.in_waiting:
                    try:
                        data = scanner.readline().decode('utf-8').strip()
                    except UnicodeDecodeError:
                        data = scanner.readline().decode('latin-1').strip()
                    
                    if data:
                        log(f"📱 Получено: {data}")
                        return data
                
                time.sleep(0.01)
                
    except Exception as e:
        log(f"❌ Ошибка сканера: {e}", "ERROR")
        return None

# ================= ПАРСИНГ QR =================
def parse_qr_data(qr_string):
    try:
        parts = qr_string.strip().split(';')
        
        if len(parts) < 3:
            log(f"⚠️  Мало сегментов: {len(parts)}", "WARNING")
            return None
        
        if SEGMENT_NUMBER < len(parts):
            value = parts[SEGMENT_NUMBER].strip()
            
            if value:
                log(f"✅ Сегмент {SEGMENT_NUMBER}: '{value}'")
                return value
        
        return None
        
    except Exception as e:
        log(f"❌ Ошибка парсинга: {e}", "ERROR")
        return None

# ================= ГЛАВНЫЙ ЦИКЛ =================
def main():
    print("=" * 70)
    print("🏭 PRODUCTION SCANNER - Orange Pi Zero H3")
    print(f"📟 Сегмент: {SEGMENT_NUMBER}")
    print("=" * 70)
    
    # Проверяем HID
    if not os.path.exists(HID_DEVICE):
        log("❌ HID не найден, создаю...", "ERROR")
        os.system("/usr/local/bin/setup_hid.sh")
        time.sleep(2)
        
        if not os.path.exists(HID_DEVICE):
            log("❌ Не удалось создать HID", "ERROR")
            return
    
    log(f"✅ HID готов: {HID_DEVICE}")
    
    keyboard = HIDKeyboard()
    
    log("🚀 Система готова")
    log("📋 Формат QR: XXX;YYY;ZZZ")
    print("\n" + "=" * 70)
    
    cycle = 0
    
    while True:
        cycle += 1
        log(f"♻️  Цикл #{cycle} - ожидание QR...")
        
        try:
            qr_data = read_from_scanner()
            
            if not qr_data:
                time.sleep(0.1)
                continue
            
            value = parse_qr_data(qr_data)
            
            if not value:
                time.sleep(0.5)
                continue
            
            # Немедленная отправка (без задержки)
            log(f"🚀 Отправка: '{value}'")
            keyboard.type_string(value)
            log(f"✅ Отправлено: '{value}'")
            
            time.sleep(0.1)
            print("\n" + "-" * 50)
            
        except KeyboardInterrupt:
            log("🛑 Остановлено", "INFO")
            break
        except Exception as e:
            log(f"💥 Ошибка: {e}", "ERROR")
            time.sleep(1)

# ================= ЗАПУСК =================
if __name__ == "__main__":
    if os.geteuid() != 0:
        print("❌ Запускай с sudo!")
        sys.exit(1)
    
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    main()
SCRIPT_EOF

    # Заменяем placeholder на реальный номер сегмента
    sed -i "s/__SEGMENT_NUMBER__/$SEGMENT/" /opt/production_scanner.py
    
    chmod +x /opt/production_scanner.py
    success "Главный скрипт создан"
}

# ================= СОЗДАНИЕ СЕРВИСА =================
create_service() {
    log "Создание systemd сервиса..."
    
    cat > /etc/systemd/system/production-scanner.service << EOF
[Unit]
Description=Production QR Scanner
After=multi-user.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt

# Запускаем HID перед основным скриптом
ExecStartPre=/bin/bash -c "/usr/local/bin/setup_hid.sh 2>&1 | logger -t scanner-hid"
ExecStart=/usr/bin/python3 /opt/production_scanner.py

Restart=always
RestartSec=5
StartLimitInterval=0

StandardOutput=journal
StandardError=journal
SyslogIdentifier=production-scanner

[Install]
WantedBy=multi-user.target
EOF
    
    # Перезагружаем systemd
    systemctl daemon-reload
    systemctl enable production-scanner.service
    systemctl start production-scanner.service
    
    success "Сервис создан и запущен"
}

# ================= СОЗДАНИЕ ТЕСТОВОГО СКРИПТА =================
create_test_script() {
    log "Создание тестового скрипта..."
    
    cat > /usr/local/bin/test-scanner << 'EOF'
#!/bin/bash
# Тест Production Scanner

echo "🧪 ТЕСТ ПРОИЗВОДСТВЕННОГО СКАНЕРА"
echo "================================"

echo "1. Проверка HID..."
if [[ -e /dev/hidg0 ]]; then
    echo "   ✅ /dev/hidg0 существует"
    
    # Тестовая клавиша
    echo -ne '\x00\x00\x04\x00\x00\x00\x00\x00' > /dev/hidg0 2>/dev/null
    sleep 0.1
    echo -ne '\x00\x00\x00\x00\x00\x00\x00\x00' > /dev/hidg0 2>/dev/null
    echo "   ✅ Тестовая клавиша отправлена"
else
    echo "   ❌ /dev/hidg0 не найден"
    echo "   Запусти: sudo /usr/local/bin/setup_hid.sh"
fi

echo ""
echo "2. Проверка сканера..."
SCANNER_PORT=""
for port in /dev/ttyUSB* /dev/ttyACM*; do
    if [[ -e "$port" ]]; then
        SCANNER_PORT="$port"
        echo "   ✅ Найден порт: $port"
        break
    fi
done

if [[ -z "$SCANNER_PORT" ]]; then
    echo "   ⚠️  Сканер не подключен"
else
    echo "   📡 Сканер на порту: $SCANNER_PORT"
fi

echo ""
echo "3. Проверка сервиса..."
if systemctl is-active --quiet production-scanner.service; then
    echo "   ✅ Сервис запущен"
else
    echo "   ❌ Сервис не запущен"
fi

echo ""
echo "4. Последние логи:"
journalctl -u production-scanner.service -n 5 --no-pager

echo ""
echo "================================"
echo "📋 КОМАНДЫ:"
echo "• Просмотр логов: journalctl -u production-scanner.service -f"
echo "• Перезапуск: systemctl restart production-scanner.service"
echo "• Настройка HID: /usr/local/bin/setup_hid.sh"
echo "• Ручной запуск: python3 /opt/production_scanner.py"
echo "================================"
EOF
    
    chmod +x /usr/local/bin/test-scanner
    success "Тестовый скрипт создан"
}

# ================= ФИНАЛЬНАЯ НАСТРОЙКА =================
final_setup() {
    log "Финальная настройка..."
    
    # Создаем логи
    mkdir -p /var/log
    touch /var/log/scanner.log
    touch "$LOG_FILE"
    chmod 644 /var/log/scanner*.log
    
    # Алиасы
    cat >> /root/.bashrc << 'EOF'
# Production Scanner
alias scanner-logs='journalctl -u production-scanner.service -f'
alias scanner-restart='systemctl restart production-scanner.service'
alias scanner-status='systemctl status production-scanner.service'
alias scanner-test='/usr/local/bin/test-scanner'
EOF
    
    # Обновляем .bashrc
    source /root/.bashrc 2>/dev/null || true
    
    success "Финальная настройка завершена"
}

# ================= ОСНОВНАЯ ФУНКЦИЯ =================
main() {
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║         УСТАНОВКА PRODUCTION SCANNER                 ║"
    echo "║         Orange Pi Zero H3                           ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    
    # Создаем лог
    mkdir -p "$(dirname "$LOG_FILE")"
    > "$LOG_FILE"
    
    # Выполняем шаги
    check_prerequisites
    cleanup_system
    install_packages
    create_hid_script
    create_main_script
    create_service
    create_test_script
    final_setup
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║                УСТАНОВКА ЗАВЕРШЕНА!                  ║"
    echo "╠═══════════════════════════════════════════════════════╣"
    echo "║ 📋 КРАТКАЯ ИНСТРУКЦИЯ:                               ║"
    echo "║                                                     ║"
    echo "║ 1. Сканер → USB порт Orange Pi                      ║"
    echo "║ 2. Orange Pi (microUSB) → Ноутбук                   ║"
    echo "║ 3. Курсор в поле ввода на ноутбуке                  ║"
    echo "║ 4. Сканируй QR: XXX;YYY;ZZZ                         ║"
    echo "║ 5. Данные отправятся сразу!                         ║"
    echo "║                                                     ║"
    echo "║ 📊 Используется сегмент: $SEGMENT                          ║"
    echo "║    (0=первый, 1=второй, 2=третий)                   ║"
    echo "║                                                     ║"
    echo "║ 🔧 КОМАНДЫ:                                         ║"
    echo "║   • test-scanner - проверка системы                 ║"
    echo "║   • scanner-logs - логи в реальном времени          ║"
    echo "║   • scanner-status - статус                         ║"
    echo "║   • scanner-restart - перезапуск                    ║"
    echo "║                                                     ║"
    echo "║ ⚠️   ПЕРЕЗАГРУЗКА НЕ ТРЕБУЕТСЯ!                      ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "📋 Полный лог: $LOG_FILE"
}

# ================= ЗАПУСК =================
main "$@"

#!/bin/bash
# production-scanner-setup.sh
# Универсальный скрипт установки для Orange Pi Zero H3 / Pi Zero 2W
# Запуск: sudo bash production-scanner-setup.sh <номер_сегмента>

set -e  # Прерывать при ошибках

# ================= КОНФИГУРАЦИЯ =================
SEGMENT_NUMBER="${1:-1}"  # По умолчанию второй сегмент
LOG_FILE="/var/log/scanner-install.log"
REPO_URL="https://github.com/olqwertyeg/idoors_production.git"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ================= ФУНКЦИИ ЛОГГИНГА =================
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}✅ $1${NC}" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}⚠️  $1${NC}" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}❌ $1${NC}" | tee -a "$LOG_FILE"
}

# ================= ПРОВЕРКА ПРАВ И АРГУМЕНТОВ =================
check_prerequisites() {
    log "Проверка предварительных условий..."
    
    # Проверка прав
    if [[ $EUID -ne 0 ]]; then
        error "Запускай с sudo, брат!"
        exit 1
    fi
    
    # Проверка аргумента
    if ! [[ "$SEGMENT_NUMBER" =~ ^[0-2]$ ]]; then
        error "Номер сегмента должен быть 0, 1 или 2"
        echo "Использование: sudo bash $0 <номер_сегмента>"
        echo "  где <номер_сегмента>:"
        echo "    0 - первый сегмент (123;456;789 -> 123)"
        echo "    1 - второй сегмент (123;456;789 -> 456)"
        echo "    2 - третий сегмент (123;456;789 -> 789)"
        exit 1
    fi
    
    success "Проверка пройдена. Используется сегмент: $SEGMENT_NUMBER"
}

# ================= ОПРЕДЕЛЕНИЕ ПЛАТЫ =================
detect_board() {
    log "Определение типа платы..."
    
    # Проверяем разные методы определения платы
    if [[ -f /proc/device-tree/model ]]; then
        BOARD_MODEL=$(tr -d '\0' < /proc/device-tree/model)
        log "Модель из device-tree: $BOARD_MODEL"
    fi
    
    # Проверяем по /proc/cpuinfo
    if grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null || [[ "$BOARD_MODEL" == *"Raspberry"* ]]; then
        BOARD_TYPE="raspberry"
        if [[ "$BOARD_MODEL" == *"Zero 2"* ]] || [[ "$BOARD_MODEL" == *"Zero2"* ]]; then
            BOARD="pi_zero_2w"
        elif [[ "$BOARD_MODEL" == *"Zero"* ]]; then
            BOARD="pi_zero"
        else
            BOARD="raspberry"
        fi
    elif [[ "$BOARD_MODEL" == *"Orange Pi Zero"* ]] || grep -q "sun8i" /proc/cpuinfo 2>/dev/null; then
        BOARD_TYPE="orange"
        BOARD="orange_pi_zero_h3"
    else
        warning "Неизвестная плата, использую универсальные настройки"
        BOARD_TYPE="generic"
        BOARD="unknown"
    fi
    
    success "Определена плата: $BOARD ($BOARD_MODEL)"
    echo "$BOARD_TYPE" > /tmp/board_type.txt
    echo "$BOARD" > /tmp/board_name.txt
}

# ================= УСТАНОВКА ПАКЕТОВ =================
install_packages() {
    log "Установка необходимых пакетов..."
    
    # Обновление списка пакетов
    apt-get update 2>&1 | tee -a "$LOG_FILE"
    
    # Базовые пакеты
    local base_packages=(
        python3
        python3-pip
        python3-venv
        python3-serial
        git
        vim
        xxd
        usbutils
    )
    
    # Установка с проверкой
    for pkg in "${base_packages[@]}"; do
        if dpkg -l | grep -q "^ii  $pkg "; then
            log "Пакет $pkg уже установлен"
        else
            log "Установка $pkg..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"
        fi
    done
    
    # Установка evdev с учетом новых ограничений Debian 12+
    log "Установка Python библиотек..."
    if python3 -c "import evdev" 2>/dev/null; then
        log "evdev уже установлен"
    else
        # Пробуем установить через apt
        if apt-cache show python3-evdev >/dev/null 2>&1; then
            apt-get install -y python3-evdev 2>&1 | tee -a "$LOG_FILE"
        else
            # Устанавливаем через pip с --break-system-packages
            warning "Установка evdev через pip с флагом --break-system-packages"
            python3 -m pip install evdev --break-system-packages 2>&1 | tee -a "$LOG_FILE"
        fi
    fi
    
    success "Пакеты установлены"
}

# ================= НАСТРОЙКА USB GADGET =================
setup_usb_gadget() {
    log "Настройка USB Gadget режима..."
    
    local board_type=$(cat /tmp/board_type.txt 2>/dev/null || echo "generic")
    
    case $board_type in
        "raspberry")
            setup_raspberry_usb
            ;;
        "orange")
            setup_orange_pi_usb
            ;;
        *)
            warning "Неизвестная плата, настраиваю универсальный режим"
            setup_generic_usb
            ;;
    esac
}

setup_raspberry_usb() {
    log "Настройка USB для Raspberry Pi..."
    
    # Проверяем и добавляем dtoverlay
    local config_file="/boot/firmware/config.txt"
    if [[ ! -f "$config_file" ]]; then
        config_file="/boot/config.txt"
    fi
    
    if grep -q "dtoverlay=dwc2" "$config_file" 2>/dev/null; then
        log "dtoverlay=dwc2 уже настроен"
    else
        log "Добавляю dtoverlay=dwc2 в $config_file"
        echo -e "\n# Production Scanner USB Gadget\ndtoverlay=dwc2" >> "$config_file"
        warning "Требуется перезагрузка для применения настроек USB"
    fi
    
    # Настройка cmdline.txt
    local cmdline_file="/boot/firmware/cmdline.txt"
    if [[ ! -f "$cmdline_file" ]]; then
        cmdline_file="/boot/cmdline.txt"
    fi
    
    if grep -q "modules-load=dwc2,g_hid" "$cmdline_file" 2>/dev/null; then
        log "Модули уже добавлены в cmdline.txt"
    else
        log "Добавляю модули в cmdline.txt"
        
        # Читаем файл
        local cmdline_content=$(cat "$cmdline_file")
        
        # Убираем возможные старые настройки
        cmdline_content=$(echo "$cmdline_content" | sed 's/modules-load=[^ ]*//g')
        
        # Добавляем наши модули
        if [[ "$cmdline_content" == *\" ]]; then
            # Если заканчивается кавычкой
            cmdline_content="${cmdline_content%?} modules-load=dwc2,g_hid\""
        else
            cmdline_content="$cmdline_content modules-load=dwc2,g_hid"
        fi
        
        # Записываем обратно
        echo "$cmdline_content" > "$cmdline_file"
        warning "Требуется перезагрузка для загрузки модулей"
    fi
    
    success "Настройки Raspberry Pi применены"
}

setup_orange_pi_usb() {
    log "Настройка USB для Orange Pi..."
    
    # Для Orange Pi обычно не нужно редактировать конфиги
    # Просто загружаем модули
    
    # Создаем файл для автозагрузки модулей
    local modules_file="/etc/modules-load.d/scanner.conf"
    cat > "$modules_file" << EOF
# Загрузка модулей для USB Gadget
sunxi_udc
libcomposite
EOF
    
    log "Создан конфиг для автозагрузки модулей: $modules_file"
    success "Настройки Orange Pi применены"
}

setup_generic_usb() {
    log "Универсальная настройка USB..."
    
    # Пробуем определить доступные модули
    if modprobe -n dwc2 2>/dev/null; then
        setup_raspberry_usb
    elif modprobe -n sunxi_udc 2>/dev/null; then
        setup_orange_pi_usb
    else
        warning "Не удалось определить USB контроллер"
        log "Будет использован configfs напрямую"
    fi
}

# ================= СОЗДАНИЕ СКРИПТА HID ГАДЖЕТА =================
create_hid_script() {
    log "Создание скрипта настройки HID..."
    
    local hid_script="/usr/local/bin/setup_hid_gadget.sh"
    
    cat > "$hid_script" << 'EOF'
#!/bin/bash
# Автоматическая настройка HID гаджета для Production Scanner
# Поддерживает разные UDC контроллеры

set -e

LOG_FILE="/var/log/hid-setup.log"
HID_DEVICE="/dev/hidg0"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Проверяем, не создан ли уже гаджет
if [[ -e "$HID_DEVICE" ]]; then
    log "HID устройство уже существует"
    exit 0
fi

log "Начало настройки HID гаджета..."

# Загружаем необходимые модули
modprobe libcomposite 2>/dev/null || true

# Монтируем configfs если не смонтирован
if ! mountpoint -q /sys/kernel/config; then
    mount -t configfs none /sys/kernel/config 2>/dev/null || true
fi

# Ждем стабилизации
sleep 1

# Переходим в директорию гаджетов
cd /sys/kernel/config/usb_gadget/ 2>/dev/null || {
    log "Ошибка: нет доступа к /sys/kernel/config/usb_gadget/"
    exit 1
}

# Удаляем старые гаджеты с таким же именем
rm -rf production_scanner 2>/dev/null || true

# Создаем новый гаджет
mkdir -p production_scanner
cd production_scanner

# Устанавливаем VID/PID (можно менять)
echo 0x1d6b > idVendor   # Linux Foundation
echo 0x0104 > idProduct  # Composite Gadget

# Информация об устройстве
mkdir -p strings/0x409
echo "Production Scanner" > strings/0x409/manufacturer
echo "Virtual Keyboard" > strings/0x409/product
echo "001" > strings/0x409/serialnumber

# Конфигурация
mkdir -p configs/c.1/strings/0x409
echo "HID Keyboard Config" > configs/c.1/strings/0x409/configuration

# HID функция
mkdir -p functions/hid.usb0
echo 1 > functions/hid.usb0/protocol    # Keyboard
echo 1 > functions/hid.usb0/subclass    # Boot interface
echo 8 > functions/hid.usb0/report_length

# Дескриптор клавиатуры HID с поддержкой расширенного набора символов
cat > /tmp/hid-descriptor.hex << 'DESC_EOF'
05010906A101050719E029E715002501750195088102950175088103950575010508
19012905910295017503910395067508150025650507190029658100050919012915
00250175019508810295017508810395067501050819012905910295017503910395
067508150025650507190029658100C0050C0901A1018501050C15002501095E7501
951509017501951009027501950181028501050C0901A1018502050C15002501095E
750195150901750195100902750195018102C0
DESC_EOF

# Конвертируем hex в binary
xxd -r -p /tmp/hid-descriptor.hex > functions/hid.usb0/report_desc
rm -f /tmp/hid-descriptor.hex

# Связываем функцию с конфигурацией
ln -sf functions/hid.usb0 configs/c.1/

# Находим доступный UDC контроллер
UDC_FOUND=""
for udc in /sys/class/udc/*; do
    if [[ -e "$udc" ]]; then
        UDC_NAME=$(basename "$udc")
        log "Найден UDC: $UDC_NAME"
        
        # Пробуем активировать
        if echo "$UDC_NAME" > UDC 2>/dev/null; then
            UDC_FOUND="$UDC_NAME"
            log "Успешно активирован UDC: $UDC_NAME"
            break
        fi
    fi
done

# Если не нашли, пробуем стандартные имена
if [[ -z "$UDC_FOUND" ]]; then
    log "Поиск UDC по стандартным именам..."
    
    for udc_name in "musb-hdrc.4.auto" "musb-hdrc.2.auto" "musb-hdrc.1.auto" "20980000.usb" "dwc2"; do
        if echo "$udc_name" > UDC 2>/dev/null; then
            UDC_FOUND="$udc_name"
            log "Активирован UDC по имени: $udc_name"
            break
        fi
    done
fi

if [[ -z "$UDC_FOUND" ]]; then
    log "Предупреждение: не удалось активировать UDC. Проверьте: ls /sys/class/udc/"
else
    log "UDC контроллер активирован: $UDC_FOUND"
fi

# Ждем создание устройства
for i in {1..10}; do
    if [[ -e "$HID_DEVICE" ]]; then
        log "✅ HID устройство успешно создано: $HID_DEVICE"
        exit 0
    fi
    sleep 0.5
done

log "❌ HID устройство не создано. Проверьте dmesg."
exit 1
EOF
    
    chmod +x "$hid_script"
    success "Скрипт настройки HID создан: $hid_script"
}

# ================= СОЗДАНИЕ ГЛАВНОГО СКРИПТА =================
create_main_script() {
    log "Создание главного рабочего скрипта..."
    
    local main_script="/opt/production_scanner.py"
    local segment=$SEGMENT_NUMBER
    
    cat > "$main_script" << EOF
#!/usr/bin/env python3
"""
🏭 АВТОМАТИЗАЦИЯ ПРОИЗВОДСТВА - PRODUCTION SCANNER
📟 QR-сканер → HID клавиатура → Станок/Ноутбук
"""

import os
import sys
import time
import serial
import re
from datetime import datetime

# ================= КОНФИГУРАЦИЯ =================
SCANNER_PORT = "/dev/ttyUSB0"      # Порт сканера
SCANNER_BAUDRATE = 9600           # Скорость сканера
HID_DEVICE = "/dev/hidg0"         # HID устройство
SEGMENT_NUMBER = $segment         # Сегмент (0, 1, 2)
LOG_FILE = "/var/log/scanner.log" # Файл логов

# ================= КАРТА КЛАВИШ =================
# Расширенная карта HID кодов с поддержкой всех необходимых символов
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
    
    # Специальные символы (без Shift)
    '-': 0x2D, '=': 0x2E, '[': 0x2F, ']': 0x30, '\\\\': 0x31,
    ';': 0x33, "'": 0x34, '`': 0x35, ',': 0x36, '.': 0x37,
    '/': 0x38,
    
    # Специальные символы (с Shift)
    '_': (0x2D, 0x02),   # Shift + -
    '+': (0x2E, 0x02),   # Shift + =
    '{': (0x2F, 0x02),   # Shift + [
    '}': (0x30, 0x02),   # Shift + ]
    '|': (0x31, 0x02),   # Shift + \\
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
    '\$': (0x21, 0x02),  # Shift + 4
    '%': (0x22, 0x02),   # Shift + 5
    '^': (0x23, 0x02),   # Shift + 6
    '&': (0x24, 0x02),   # Shift + 7
    '*': (0x25, 0x02),   # Shift + 8
    '(': (0x26, 0x02),   # Shift + 9
    ')': (0x27, 0x02),   # Shift + 0
    
    # Управляющие клавиши
    '\\n': 0x28,  # Enter
    '\\t': 0x2B,  # Tab
    ' ': 0x2C,    # Space
    '\\b': 0x2A,  # Backspace
}

# ================= ЛОГГИНГ =================
def log(message, level="INFO"):
    """Запись лога с timestamp"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_line = f"[{timestamp}] [{level}] {message}"
    
    # Вывод в консоль
    print(f"📝 {log_line}")
    
    # Запись в файл
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(log_line + "\\n")
    except Exception:
        pass
    
    return log_line

# ================= HID КЛАВИАТУРА =================
class HIDKeyboard:
    def __init__(self, device=HID_DEVICE):
        self.device = device
        
    def send_key(self, keycode, modifiers=0):
        """Отправка нажатия клавиши"""
        try:
            with open(self.device, "wb") as hid:
                # Формат HID отчета: 8 байт
                report = bytes([
                    modifiers,    # Модификаторы
                    0x00,         # Reserved
                    keycode,      # Key 1
                    0x00, 0x00, 0x00, 0x00, 0x00  # Keys 2-6
                ])
                hid.write(report)
                hid.flush()
                time.sleep(0.01)
                
                # Отпускаем клавишу
                hid.write(bytes([0x00] * 8))
                hid.flush()
                time.sleep(0.01)
            
            return True
        except Exception as e:
            log(f"Ошибка отправки клавиши: {e}", "ERROR")
            return False
    
    def type_string(self, text):
        """Ввод строки с поддержкой всех символов"""
        log(f"⌨️  Ввод текста: '{text}'")
        
        for char in text:
            if char in HID_KEYMAP:
                # Получаем код клавиши и модификаторы
                key_info = HID_KEYMAP[char]
                
                if isinstance(key_info, tuple):
                    # Если нужен Shift
                    keycode, modifiers = key_info
                else:
                    # Простая клавиша
                    keycode = key_info
                    modifiers = 0x02 if char.isupper() else 0
                
                # Отправляем клавишу
                success = False
                for attempt in range(3):
                    if self.send_key(keycode, modifiers):
                        success = True
                        break
                    time.sleep(0.05)
                
                if not success:
                    log(f"⚠️  Не удалось ввести символ: '{char}'", "WARNING")
            else:
                log(f"⚠️  Неподдерживаемый символ: '{char}' (код: {ord(char)})", "WARNING")
        
        # Enter в конце (как у сканера)
        self.send_key(HID_KEYMAP['\\n'])
        log("↵ Enter отправлен")
        
        return True

# ================= ПАРСИНГ QR =================
def parse_qr_data(qr_string):
    """Парсит QR код формата 'сегмент1;сегмент2;сегмент3'"""
    try:
        log(f"📊 Получен QR код: {qr_string}")
        
        # Убираем лишние пробелы и символы
        qr_clean = qr_string.strip()
        
        # Разделяем по точке с запятой
        segments = qr_clean.split(';')
        
        # Проверяем количество сегментов
        if len(segments) < 3:
            log(f"⚠️  Мало сегментов: {len(segments)} (нужно 3)", "WARNING")
            return None
        
        # Выбираем нужный сегмент
        if SEGMENT_NUMBER < len(segments):
            value = segments[SEGMENT_NUMBER].strip()
            
            if value:
                log(f"✅ Извлечен сегмент {SEGMENT_NUMBER}: '{value}'")
                return value
            else:
                log(f"⚠️  Пустой сегмент {SEGMENT_NUMBER}", "WARNING")
                return None
        else:
            log(f"❌ Нет сегмента номер {SEGMENT_NUMBER}", "ERROR")
            return None
            
    except Exception as e:
        log(f"❌ Ошибка парсинга QR: {e}", "ERROR")
        return None

# ================= ЧТЕНИЕ СО СКАНЕРА =================
def read_from_scanner():
    """Чтение данных со сканера QR кодов"""
    try:
        log("📡 Ожидание данных от сканера...")
        
        # Автопоиск порта сканера
        port = SCANNER_PORT
        if not os.path.exists(port):
            # Ищем возможные порты
            for possible_port in ["/dev/ttyUSB0", "/dev/ttyUSB1", "/dev/ttyACM0", "/dev/ttyACM1"]:
                if os.path.exists(possible_port):
                    port = possible_port
                    log(f"🔍 Найден сканер на порту: {port}")
                    break
        
        with serial.Serial(
            port=port,
            baudrate=SCANNER_BAUDRATE,
            timeout=1,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE
        ) as scanner:
            
            # Сбрасываем буфер
            scanner.reset_input_buffer()
            
            while True:
                if scanner.in_waiting:
                    # Читаем строку
                    try:
                        data = scanner.readline().decode('utf-8', errors='ignore').strip()
                    except UnicodeDecodeError:
                        data = scanner.readline().decode('latin-1', errors='ignore').strip()
                    
                    if data:
                        log(f"📱 Получены данные: {data}")
                        return data
                
                # Небольшая пауза
                time.sleep(0.01)
                
    except serial.SerialException as e:
        log(f"❌ Ошибка подключения к сканеру: {e}", "ERROR")
        log("🔧 Проверьте подключение сканера и порт", "INFO")
        return None
    except Exception as e:
        log(f"❌ Неожиданная ошибка сканера: {e}", "ERROR")
        return None

# ================= ГЛАВНЫЙ ЦИКЛ =================
def main():
    """Основной цикл работы программы"""
    
    print("=" * 70)
    print("🏭 АВТОМАТИЗАЦИЯ ПРОИЗВОДСТВА - PRODUCTION SCANNER")
    print(f"📟 Используется сегмент: {SEGMENT_NUMBER}")
    print("=" * 70)
    
    # Проверяем HID устройство
    if not os.path.exists(HID_DEVICE):
        log(f"❌ HID устройство не найдено: {HID_DEVICE}", "ERROR")
        log("🔧 Запускаю настройку HID...", "INFO")
        os.system("/usr/local/bin/setup_hid_gadget.sh")
        time.sleep(2)
        
        if not os.path.exists(HID_DEVICE):
            log("❌ Не удалось создать HID устройство", "ERROR")
            return
    
    log(f"✅ HID устройство готово: {HID_DEVICE}")
    
    # Создаем объект клавиатуры
    keyboard = HIDKeyboard()
    
    log("🚀 Система готова к работе")
    log("📋 Просто сканируйте QR коды формата: XXX;YYY;ZZZ")
    print("\\n" + "=" * 70)
    
    cycle_count = 0
    
    while True:
        cycle_count += 1
        log(f"♻️  Цикл #{cycle_count} - ожидание QR кода...")
        
        try:
            # 1. Чтение QR кода
            qr_data = read_from_scanner()
            
            if not qr_data:
                time.sleep(0.1)
                continue
            
            # 2. Парсинг
            value = parse_qr_data(qr_data)
            
            if not value:
                log("⏭️  Пропускаю невалидный QR код", "WARNING")
                time.sleep(0.5)
                continue
            
            # 3. Немедленная отправка (без задержки)
            log(f"🚀 Отправка сегмента на станок: '{value}'")
            
            success = keyboard.type_string(value)
            
            if success:
                log(f"✅ УСПЕХ! Сегмент отправлен: '{value}'")
            else:
                log(f"❌ ОШИБКА отправки сегмента", "ERROR")
            
            # Короткая пауза между циклами
            time.sleep(0.1)
            
            print("\\n" + "─" * 50)
            
        except KeyboardInterrupt:
            log("🛑 Программа остановлена пользователем", "INFO")
            break
        except Exception as e:
            log(f"💥 КРИТИЧЕСКАЯ ОШИБКА: {e}", "ERROR")
            time.sleep(1)

# ================= ТОЧКА ВХОДА =================
if __name__ == "__main__":
    # Проверка прав
    if os.geteuid() != 0:
        print("❌ Запускайте с правами root!")
        print("   sudo python3 /opt/production_scanner.py")
        sys.exit(1)
    
    # Создаем директорию для логов
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    
    log("🚀 Запуск Production Scanner", "INFO")
    main()
EOF
    
    chmod +x "$main_script"
    success "Главный скрипт создан: $main_script"
}

# ================= СОЗДАНИЕ SYSTEMD СЕРВИСА =================
create_systemd_service() {
    log "Создание systemd сервиса..."
    
    local service_file="/etc/systemd/system/production-scanner.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=Production QR Scanner Service
After=multi-user.target network.target
Wants=network.target
Requires=syslog.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt

# Запускаем настройку HID перед основным скриптом
ExecStartPre=/bin/bash -c "/usr/local/bin/setup_hid_gadget.sh || true"
ExecStart=/usr/bin/python3 /opt/production_scanner.py

# Перезапуск при ошибках
Restart=always
RestartSec=5
StartLimitInterval=0

# Логирование
StandardOutput=journal
StandardError=journal
SyslogIdentifier=production-scanner

# Безопасность
NoNewPrivileges=true
ProtectSystem=strict
PrivateTmp=true
PrivateDevices=false
ProtectHome=true
ReadWritePaths=/var/log /opt

[Install]
WantedBy=multi-user.target
EOF
    
    # Создаем также таймер для проверки состояния
    local timer_file="/etc/systemd/system/production-scanner.timer"
    
    cat > "$timer_file" << EOF
[Unit]
Description=Check and restart scanner service periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
    
    # Перезагружаем systemd и включаем сервисы
    systemctl daemon-reload
    systemctl enable production-scanner.service
    systemctl enable production-scanner.timer
    systemctl start production-scanner.service
    systemctl start production-scanner.timer
    
    success "Systemd сервис создан и запущен"
}

# ================= СОЗДАНИЕ СКРИПТА ПРОВЕРКИ =================
create_test_script() {
    log "Создание тестового скрипта..."
    
    local test_script="/usr/local/bin/test-scanner.sh"
    
    cat > "$test_script" << 'EOF'
#!/bin/bash
# Тестовый скрипт для проверки работы Production Scanner

echo "🧪 ТЕСТ ПРОИЗВОДСТВЕННОГО СКАНЕРА"
echo "================================"

# Проверка HID устройства
echo "1. Проверка HID устройства..."
if [[ -e /dev/hidg0 ]]; then
    echo "   ✅ /dev/hidg0 существует"
    
    # Тестовая отправка клавиши
    echo -ne '\x00\x00\x04\x00\x00\x00\x00\x00' | dd of=/dev/hidg0 bs=8 count=1 2>/dev/null
    sleep 0.1
    echo -ne '\x00\x00\x00\x00\x00\x00\x00\x00' | dd of=/dev/hidg0 bs=8 count=1 2>/dev/null
    echo "   ✅ Тестовая клавиша отправлена (A)"
else
    echo "   ❌ /dev/hidg0 не существует"
    echo "   Запустите: sudo /usr/local/bin/setup_hid_gadget.sh"
fi

# Проверка сканера
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
    echo "   ⚠️  Сканер не найден"
else
    echo "   📡 Сканер подключен к: $SCANNER_PORT"
fi

# Проверка сервиса
echo ""
echo "3. Проверка сервиса..."
if systemctl is-active --quiet production-scanner.service; then
    echo "   ✅ Сервис запущен"
else
    echo "   ❌ Сервис не запущен"
    echo "   Запустите: sudo systemctl start production-scanner.service"
fi

# Проверка логов
echo ""
echo "4. Последние логи:"
journalctl -u production-scanner.service -n 10 --no-pager

echo ""
echo "================================"
echo "📋 КОМАНДЫ ДЛЯ УПРАВЛЕНИЯ:"
echo "• Просмотр логов: sudo journalctl -u production-scanner.service -f"
echo "• Перезапуск: sudo systemctl restart production-scanner.service"
echo "• Тест HID: sudo /usr/local/bin/setup_hid_gadget.sh"
echo "• Ручной запуск: sudo python3 /opt/production_scanner.py"
echo "================================"
EOF
    
    chmod +x "$test_script"
    success "Тестовый скрипт создан: $test_script"
}

# ================= ФИНАЛЬНАЯ НАСТРОЙКА =================
final_setup() {
    log "Финальная настройка..."
    
    # Устанавливаем корректные права на логи
    mkdir -p /var/log
    touch /var/log/scanner.log
    touch /var/log/scanner-install.log
    chmod 644 /var/log/scanner*.log
    
    # Создаем алиас для удобства
    cat >> /root/.bashrc << 'EOF'
# Production Scanner aliases
alias scanner-logs='journalctl -u production-scanner.service -f'
alias scanner-restart='systemctl restart production-scanner.service'
alias scanner-status='systemctl status production-scanner.service'
alias scanner-test='/usr/local/bin/test-scanner.sh'
EOF
    
    # Применяем изменения .bashrc
    source /root/.bashrc 2>/dev/null || true
    
    success "Финальная настройка завершена"
}

# ================= ОСНОВНОЙ ПРОЦЕСС =================
main() {
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║         УСТАНОВКА PRODUCTION SCANNER SYSTEM           ║"
    echo "║         Для Orange Pi Zero H3 / Pi Zero 2W           ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    # Создаем лог файл
    mkdir -p "$(dirname "$LOG_FILE")"
    > "$LOG_FILE"
    
    # Выполняем все шаги
    check_prerequisites
    detect_board
    install_packages
    setup_usb_gadget
    create_hid_script
    create_main_script
    create_systemd_service
    create_test_script
    final_setup
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║                УСТАНОВКА ЗАВЕРШЕНА!                  ║"
    echo "╠═══════════════════════════════════════════════════════╣"
    echo "║ 📋 КРАТКАЯ ИНСТРУКЦИЯ:                               ║"
    echo "║                                                     ║"
    echo "║ 1. Подключите сканер в USB порт                     ║"
    echo "║ 2. Подключите плату к ноутбуку через microUSB       ║"
    echo "║ 3. Откройте программу станка на ноутбуке           ║"
    echo "║ 4. Поставьте курсор в поле ввода                    ║"
    echo "║ 5. Сканируйте QR коды формата: XXX;YYY;ZZZ          ║"
    echo "║ 6. Данные будут отправляться автоматически!         ║"
    echo "║                                                     ║"
    echo "║ 📊 Используется сегмент номер: $SEGMENT_NUMBER                ║"
    echo "║    (0=первый, 1=второй, 2=третий)                   ║"
    echo "║                                                     ║"
    echo "║ 🔧 КОМАНДЫ ДЛЯ УПРАВЛЕНИЯ:                          ║"
    echo "║   • test-scanner.sh - проверка системы              ║"
    echo "║   • scanner-logs - просмотр логов в реальном времени║"
    echo "║   • scanner-status - статус сервиса                 ║"
    echo "║   • scanner-restart - перезапуск сервиса            ║"
    echo "║                                                     ║"
    if grep -q "Требуется перезагрузка" "$LOG_FILE"; then
        echo "║ ⚠️   ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА!                           ║"
        echo "║    Выполните: sudo reboot                        ║"
    fi
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "📋 Полный лог установки: $LOG_FILE"
}

# ================= ЗАПУСК =================
main "$@"

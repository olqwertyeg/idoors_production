#!/bin/bash
# ================================================
# 🏭 ПОЛНАЯ УСТАНОВКА АВТОМАТИЗАЦИИ ПРОИЗВОДСТВА
# Orange Pi Zero H3 - QR сканер → HID клавиатура
# ================================================
# Запуск: sudo ./install_scanner.sh
# ================================================

set -e  # Останавливаться при ошибках

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ================= ПРОВЕРКА ПРАВ =================
if [[ $EUID -ne 0 ]]; then
   print_error "Запускай с sudo!"
   print_error "  sudo $0"
   exit 1
fi

print_info "========================================"
print_info "🏭 УСТАНОВКА АВТОМАТИЗАЦИИ ПРОИЗВОДСТВА"
print_info "Orange Pi Zero H3 - QR → HID клавиатура"
print_info "========================================"

# ================= 1. ОБНОВЛЕНИЕ СИСТЕМЫ =================
print_info "1. Обновление системы..."
apt update -y
apt upgrade -y

# ================= 2. УСТАНОВКА ПАКЕТОВ =================
print_info "2. Установка необходимых пакетов..."
apt install -y \
    python3 \
    python3-pip \
    python3-serial \
    git \
    vim \
    screen \
    htop \
    usbutils \
    xxd \
    curl \
    wget

# Python библиотеки
print_info "3. Установка Python библиотек..."
pip3 install evdev

# ================= 4. ФУНКЦИЯ ДЛЯ АВТООПРЕДЕЛЕНИЯ UDC =================
print_info "4. Создание функции определения UDC..."

cat > /usr/local/bin/find_udc.sh << 'EOF'
#!/bin/bash
# Автоматическое определение правильного UDC контроллера

echo "🔍 Поиск UDC контроллера..."

# Проверяем доступные UDC контроллеры
if [ -d /sys/class/udc ]; then
    UDC_LIST=$(ls /sys/class/udc/ 2>/dev/null)
    
    if [ -n "$UDC_LIST" ]; then
        echo "✅ Найдены UDC контроллеры:"
        for udc in $UDC_LIST; do
            echo "   - $udc"
        done
        
        # Берем первый попавшийся (обычно правильный)
        SELECTED_UDC=$(echo "$UDC_LIST" | head -1)
        echo "📱 Выбран UDC: $SELECTED_UDC"
        echo "$SELECTED_UDC"
        exit 0
    fi
fi

# Если не нашли в /sys/class/udc, пробуем другие варианты
echo "⚠️  UDC не найден в /sys/class/udc, ищу альтернативные пути..."

# Варианты для Orange Pi Zero H3
POSSIBLE_UDCS=(
    "musb-hdrc.4.auto"  # Твой случай
    "musb-hdrc.1.auto"  # Частый случай
    "musb-hdrc"         # Без номера
    "20980000.usb"      # Для некоторых плат
    "fe800000.usb"      # Для некоторых плат
)

# Проверяем sysfs на наличие контроллеров
for udc in "${POSSIBLE_UDCS[@]}"; do
    if [ -d "/sys/class/udc/$udc" ] || dmesg | grep -q "$udc"; then
        echo "✅ Найден возможный UDC в sysfs/dmesg: $udc"
        echo "$udc"
        exit 0
    fi
done

# Последний вариант - ищем в dmesg
echo "🔍 Поиск в dmesg..."
DMESG_UDC=$(dmesg | grep -i "udc\|musb\|dwc" | grep -oE "musb-hdrc[^ ]*" | head -1)

if [ -n "$DMESG_UDC" ]; then
    echo "✅ Найден UDC в dmesg: $DMESG_UDC"
    echo "$DMESG_UDC"
    exit 0
fi

# Если ничего не нашли
echo "❌ UDC контроллер не найден!"
echo "ℹ️  Возможные причины:"
echo "   1. Драйвер USB gadget не загружен"
echo "   2. Плата не поддерживает USB gadget режим"
echo "   3. Нужно перезагрузиться"
exit 1
EOF

chmod +x /usr/local/bin/find_udc.sh

# ================= 5. СОЗДАНИЕ СКРИПТА HID ГАДЖЕТА =================
print_info "5. Создание скрипта HID гаджета..."

cat > /usr/local/bin/setup_hid.sh << 'EOF'
#!/bin/bash
# Настройка HID клавиатуры для Orange Pi Zero H3
# Автоматически создает /dev/hidg0

echo "🔧 Настройка HID клавиатуры..."

# Загружаем модули
modprobe sunxi_udc 2>/dev/null
modprobe usb_f_hid 2>/dev/null
modprobe g_hid 2>/dev/null

# Монтируем configfs если не смонтирован
mount -t configfs none /sys/kernel/config 2>/dev/null

# Переходим в директорию гаджетов
cd /sys/kernel/config/usb_gadget/ 2>/dev/null || {
    echo "❌ Не могу перейти в configfs"
    exit 1
}

# Удаляем старый если есть
rm -rf g1 2>/dev/null

# Создаем новый гаджет
mkdir g1
cd g1

# Базовые настройки
echo 0x1d6b > idVendor   # Linux Foundation
echo 0x0104 > idProduct  # Composite Gadget

# Информация об устройстве
mkdir strings/0x409
echo "Orange Pi Zero" > strings/0x409/manufacturer
echo "Production Scanner" > strings/0x409/product
echo "001" > strings/0x409/serialnumber

# Конфигурация
mkdir configs/c.1
mkdir configs/c.1/strings/0x409
echo "HID Config" > configs/c.1/strings/0x409/configuration

# Создаем HID функцию (клавиатура)
mkdir functions/hid.usb0
echo 1 > functions/hid.usb0/protocol    # Keyboard
echo 1 > functions/hid.usb0/subclass    # Boot interface
echo 8 > functions/hid.usb0/report_length

# Дескриптор клавиатуры HID (стандартный)
echo -ne \\x05\\x01\\x09\\x06\\xA1\\x01\\x05\\x07\\x19\\xE0\\x29\\xE7\\x15\\x00\\x25\\x01\\x75\\x01\\x95\\x08\\x81\\x02\\x95\\x01\\x75\\x08\\x81\\x03\\x95\\x05\\x75\\x01\\x05\\x08\\x19\\x01\\x29\\x05\\x91\\x02\\x95\\x01\\x75\\x03\\x91\\x03\\x95\\x06\\x75\\x08\\x15\\x00\\x25\\x65\\x05\\x07\\x19\\x00\\x29\\x65\\x81\\x00\\xC0 > functions/hid.usb0/report_desc

# Связываем функцию с конфигурацией
ln -s functions/hid.usb0 configs/c.1/

# ========== АВТООПРЕДЕЛЕНИЕ И АКТИВАЦИЯ UDC ==========
echo "🔍 Определение UDC контроллера..."

# Используем нашу функцию поиска
UDC_CONTROLLER=$(/usr/local/bin/find_udc.sh)

if [ $? -eq 0 ] && [ -n "$UDC_CONTROLLER" ]; then
    echo "✅ Найден UDC: $UDC_CONTROLLER"
    echo "🚀 Активация гаджета..."
    
    # Пробуем активировать
    if echo "$UDC_CONTROLLER" > UDC 2>/dev/null; then
        echo "✅ Гаджет активирован с UDC: $UDC_CONTROLLER"
    else
        echo "⚠️  Не удалось активировать с $UDC_CONTROLLER, пробую другие варианты..."
        
        # Пробуем варианты по порядку
        for udc_try in "musb-hdrc.4.auto" "musb-hdrc.1.auto" "musb-hdrc" "musb-hdrc.0.auto"; do
            if echo "$udc_try" > UDC 2>/dev/null; then
                echo "✅ Гаджет активирован с UDC: $udc_try"
                UDC_CONTROLLER="$udc_try"
                break
            fi
        done
    fi
else
    echo "⚠️  Не удалось определить UDC автоматически"
    echo "🔄 Пробую стандартные варианты..."
    
    # Пробуем стандартные варианты
    for udc_try in "musb-hdrc.4.auto" "musb-hdrc.1.auto" "musb-hdrc" "musb-hdrc.0.auto"; do
        if echo "$udc_try" > UDC 2>/dev/null; then
            echo "✅ Гаджет активирован с UDC: $udc_try"
            UDC_CONTROLLER="$udc_try"
            break
        fi
    done
fi

# Проверяем активацию
if [ -z "$UDC_CONTROLLER" ] || ! grep -q "$UDC_CONTROLLER" UDC 2>/dev/null; then
    echo "⚠️  Не удалось активировать гаджет"
    echo "ℹ️  Проверьте:"
    echo "   1. Подключен ли кабель к ноутбуку?"
    echo "   2. Загружены ли модули? (lsmod | grep hid)"
    echo "   3. dmesg | tail -20"
else
    echo "📱 UDC контроллер активирован: $(cat UDC 2>/dev/null)"
fi

# Ждем создание устройства
echo "⏳ Ожидание создания HID устройства..."
sleep 3

if [ -e /dev/hidg0 ]; then
    echo "✅ HID клавиатура создана: /dev/hidg0"
    
    # Дополнительная проверка
    echo "🔍 Дополнительные проверки:"
    ls -la /dev/hidg*
    echo "📊 Размер дескриптора: $(wc -c < functions/hid.usb0/report_desc) байт"
else
    echo "⚠️  /dev/hidg0 не создан"
    echo "ℹ️  Возможные причины:"
    echo "   1. Неправильный UDC контроллер"
    echo "   2. Не загружены модули ядра"
    echo "   3. Нет подключения к хосту (ноутбуку)"
    echo "🔧 Попробуйте:"
    echo "   1. Подключите кабель к ноутбуку"
    echo "   2. Перезагрузите Orange Pi"
    echo "   3. Проверьте dmesg: dmesg | tail -30"
fi

# Сохраняем использованный UDC для логов
if [ -n "$UDC_CONTROLLER" ]; then
    echo "💾 Использованный UDC: $UDC_CONTROLLER" > /tmp/last_udc.txt
fi
EOF

chmod +x /usr/local/bin/setup_hid.sh

# ================= 6. СОЗДАНИЕ УЛУЧШЕННОЙ ВЕРСИИ С ПРОВЕРКОЙ =================
print_info "6. Создание улучшенной версии скрипта..."

cat > /usr/local/bin/setup_hid_smart.sh << 'EOF'
#!/bin/bash
# Умный скрипт настройки HID с перебором UDC

MAX_ATTEMPTS=3
ATTEMPT=1

echo "🤖 УМНАЯ НАСТРОЙКА HID КЛАВИАТУРЫ"
echo "=================================="

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo ""
    echo "🔄 Попытка $ATTEMPT из $MAX_ATTEMPTS"
    
    # Выполняем стандартную настройку
    /usr/local/bin/setup_hid.sh
    
    # Проверяем результат
    if [ -e /dev/hidg0 ]; then
        echo ""
        echo "🎉 УСПЕХ! HID устройство создано"
        echo "📱 Проверьте: ls -la /dev/hidg*"
        exit 0
    fi
    
    echo ""
    echo "⚠️  Попытка $ATTEMPT не удалась"
    
    # На последней попытке пробуем ручной перебор UDC
    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        echo "🔄 Ручной перебор UDC контроллеров..."
        
        # Список возможных UDC
        UDC_CANDIDATES=(
            "musb-hdrc.4.auto"
            "musb-hdrc.1.auto" 
            "musb-hdrc.0.auto"
            "musb-hdrc"
            "20980000.usb"
            "fe800000.usb"
            "ff400000.usb"
        )
        
        # Пробуем каждый
        for udc in "${UDC_CANDIDATES[@]}"; do
            echo "🔧 Пробую UDC: $udc"
            
            # Пересоздаем гаджет
            cd /sys/kernel/config/usb_gadget/ 2>/dev/null && rm -rf g1 2>/dev/null
            /usr/local/bin/setup_hid.sh 2>/dev/null | grep -q "активирован"
            
            # Пробуем активировать с этим UDC
            if echo "$udc" > /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null; then
                echo "✅ UDC $udc принят"
                sleep 2
                
                if [ -e /dev/hidg0 ]; then
                    echo "🎉 НАЙДЕН РАБОЧИЙ UDC: $udc"
                    echo "💾 Сохраняю в конфиг..."
                    echo "WORKING_UDC=\"$udc\"" > /etc/hid_udc.conf
                    exit 0
                fi
            fi
        done
    fi
    
    ATTEMPT=$((ATTEMPT + 1))
    sleep 2
done

echo ""
echo "❌ ВСЕ ПОПЫТКИ НЕ УДАЛИСЬ"
echo "ℹ️  Что делать:"
echo "   1. Проверьте подключение к ноутбуку"
echo "   2. Перезагрузите Orange Pi"
echo "   3. Запустите вручную: dmesg | grep -i udc"
echo "   4. Посмотрите какие UDC есть: ls /sys/class/udc/"
exit 1
EOF

chmod +x /usr/local/bin/setup_hid_smart.sh

# ================= 7. СОЗДАНИЕ ГЛАВНОГО РАБОЧЕГО СКРИПТА =================
print_info "7. Создание главного рабочего скрипта..."

cat > /opt/production_scanner.py << 'EOF'
#!/usr/bin/env python3
"""
🏭 АВТОМАТИЗАЦИЯ ПРОИЗВОДСТВА - ORANGE PI ZERO H3
📟 Сканер (USB host) → HID клавиатура (USB OTG) → Ноутбук
"""

import os
import sys
import time
import serial
import subprocess
from datetime import datetime

# ========== КОНФИГУРАЦИЯ ==========
SCANNER_PORT = "/dev/ttyUSB0"  # Порт сканера
HID_DEVICE = "/dev/hidg0"      # HID устройство
SEGMENT = 1                    # Какой сегмент брать: 0=первый, 1=второй, 2=третий
DELAY = 5                      # Задержка перед отправкой (секунд)
LOG_FILE = "/var/log/scanner.log"

# ========== ЛОГГИНГ ==========
def log(message, level="INFO"):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_line = f"[{timestamp}] [{level}] {message}"
    
    # Вывод в консоль с эмодзи
    if level == "ERROR":
        print(f"❌ {log_line}")
    elif level == "WARNING":
        print(f"⚠️  {log_line}")
    else:
        print(f"📝 {log_line}")
    
    # Запись в файл
    try:
        with open(LOG_FILE, "a") as f:
            f.write(log_line + "\n")
    except:
        pass

# ========== HID КЛАВИАТУРА ==========
class HIDKeyboard:
    def __init__(self, device=HID_DEVICE):
        self.device = device
        # HID коды для цифр и Enter
        self.keymap = {
            '0': 0x27, '1': 0x1E, '2': 0x1F, '3': 0x20, '4': 0x21,
            '5': 0x22, '6': 0x23, '7': 0x24, '8': 0x25, '9': 0x26,
            '\n': 0x28,  # Enter
        }
    
    def send_key(self, keycode):
        """Отправка нажатия одной клавиши"""
        try:
            with open(self.device, "wb") as hid:
                # HID отчет: 8 байт
                report = bytes([0, 0, keycode, 0, 0, 0, 0, 0])
                hid.write(report)
                hid.flush()
                time.sleep(0.05)
                
                # Отпускаем клавишу
                report = bytes([0]*8)
                hid.write(report)
                hid.flush()
                time.sleep(0.02)
            return True
        except Exception as e:
            log(f"Ошибка отправки клавиши: {e}", "ERROR")
            return False
    
    def type_digits(self, digits):
        """Ввод цифр"""
        log(f"⌨️  Ввод цифр: {digits}")
        
        for digit in digits:
            if digit in self.keymap:
                self.send_key(self.keymap[digit])
                time.sleep(0.05)
            else:
                log(f"⚠️  Пропускаю не-цифру: '{digit}'", "WARNING")
        
        # Enter в конце (как сканер)
        self.send_key(self.keymap['\n'])
        log("↵ Enter отправлен")
        return True

# ========== ПАРСИНГ QR ==========
def parse_qr(qr_string):
    """Парсит '123;456;789' и возвращает нужный сегмент"""
    try:
        parts = qr_string.strip().split(';')
        
        log(f"📊 Получен QR: {qr_string}")
        log(f"📊 Сегментов: {len(parts)}")
        
        if len(parts) < 3:
            log(f"⚠️  Мало сегментов: {len(parts)} (нужно 3)", "WARNING")
            return None
        
        if SEGMENT < len(parts):
            value = parts[SEGMENT].strip()
            
            # Проверяем что только цифры
            if value and value.isdigit():
                log(f"✅ Извлечен сегмент {SEGMENT}: {value}")
                return value
            else:
                log(f"❌ В сегменте не цифры: '{value}'", "ERROR")
                return None
        else:
            log(f"❌ Нет сегмента номер {SEGMENT}", "ERROR")
            return None
            
    except Exception as e:
        log(f"❌ Ошибка парсинга: {e}", "ERROR")
        return None

# ========== ЧТЕНИЕ СКАНЕРА ==========
def read_scanner():
    """Чтение данных со сканера QR"""
    try:
        log("📡 Ожидание данных от сканера...")
        
        with serial.Serial(
            port=SCANNER_PORT,
            baudrate=9600,
            timeout=1,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE
        ) as ser:
            
            while True:
                if ser.in_waiting:
                    # Читаем строку (сканер обычно отправляет с \r\n)
                    data = ser.readline().decode('utf-8', errors='ignore').strip()
                    
                    if data:
                        log(f"📱 Получено с сканера: {data}")
                        return data
                
                time.sleep(0.1)
                
    except serial.SerialException as e:
        log(f"❌ Ошибка подключения к сканеру: {e}", "ERROR")
        return None
    except Exception as e:
        log(f"❌ Неожиданная ошибка сканера: {e}", "ERROR")
        return None

# ========== ПРОВЕРКА И ВОССТАНОВЛЕНИЕ HID ==========
def check_and_fix_hid():
    """Проверка и восстановление HID устройства"""
    
    if os.path.exists(HID_DEVICE):
        log(f"✅ HID устройство готово: {HID_DEVICE}")
        return True
    
    log(f"⚠️  HID устройство не найдено: {HID_DEVICE}", "WARNING")
    log("🔧 Пробую восстановить HID...")
    
    # Пробуем простую настройку
    result = subprocess.run(["/usr/local/bin/setup_hid.sh"], 
                          capture_output=True, text=True)
    log(f"📋 Результат настройки: {result.stdout}")
    
    if result.returncode != 0:
        log(f"❌ Ошибка настройки: {result.stderr}", "ERROR")
    
    time.sleep(2)
    
    if os.path.exists(HID_DEVICE):
        log(f"✅ HID восстановлен: {HID_DEVICE}")
        return True
    
    # Пробуем умную настройку
    log("🔄 Пробую умную настройку...")
    result = subprocess.run(["/usr/local/bin/setup_hid_smart.sh"],
                          capture_output=True, text=True)
    
    if "НАЙДЕН РАБОЧИЙ UDC" in result.stdout:
        log("🎉 Найден рабочий UDC!", "INFO")
        time.sleep(2)
        
        if os.path.exists(HID_DEVICE):
            log(f"✅ HID создан после умной настройки")
            return True
    
    log("❌ Не удалось восстановить HID", "ERROR")
    return False

# ========== ПРОВЕРКА УСТРОЙСТВ ==========
def check_devices():
    """Проверка наличия необходимых устройств"""
    
    # Проверяем HID
    if not check_and_fix_hid():
        return False
    
    # Проверяем COM порты
    com_ports = [f for f in os.listdir('/dev') if f.startswith('ttyUSB') or f.startswith('ttyACM')]
    if com_ports:
        log(f"✅ Найдены COM порты: {', '.join(com_ports)}")
    else:
        log(f"⚠️  COM порты не найдены", "WARNING")
        log(f"ℹ️  Подключите сканер к USB порту", "INFO")
    
    return True

# ========== ГЛАВНЫЙ ЦИКЛ ==========
def main():
    """Главный цикл программы"""
    
    print("=" * 70)
    print("🏭 АВТОМАТИЗАЦИЯ ПРОИЗВОДСТВА - ORANGE PI ZERO H3")
    print("📟 QR-сканер → HID клавиатура → Станок/Ноутбук")
    print("=" * 70)
    
    # Проверяем устройства
    if not check_devices():
        log("❌ Не все устройства готовы", "ERROR")
        log("ℹ️  Проверьте подключение:", "INFO")
        log("   1. Сканер → USB порт (большой)", "INFO")
        log("   2. Ноутбук → microUSB порт", "INFO")
        log("   3. Перезагрузите Orange Pi", "INFO")
        return
    
    log(f"✅ Все устройства готовы")
    log(f"⚙️  Конфигурация:")
    log(f"   Порт сканера: {SCANNER_PORT}")
    log(f"   Сегмент QR: {SEGMENT} (0=первый, 1=второй, 2=третий)")
    log(f"   Задержка: {DELAY} секунд")
    log(f"   Лог файл: {LOG_FILE}")
    
    print("\n" + "=" * 70)
    print("📋 ИНСТРУКЦИЯ ДЛЯ ОПЕРАТОРА:")
    print("1. Сканер → USB порт (большой)")
    print("2. Ноутбук → microUSB порт (OTG)")
    print("3. Курсор в поле ввода программы станка")
    print("4. Сканируй QR-код: XXX;YYY;ZZZ")
    print("5. Через 5 сек данные отправятся автоматически")
    print("=" * 70 + "\n")
    
    # Создаем объект клавиатуры
    keyboard = HIDKeyboard()
    
    cycle_count = 0
    
    while True:
        cycle_count += 1
        log(f"♻️  Цикл #{cycle_count} - ожидание QR-кода...")
        
        try:
            # 1. Чтение QR-кода
            qr_data = read_scanner()
            
            if not qr_data:
                log("⏭️  Пустые данные от сканера, продолжаю ожидание...")
                continue
            
            # 2. Парсинг QR
            value = parse_qr(qr_data)
            
            if not value:
                log("⏭️  Не удалось извлечь значение, жду следующий QR...")
                continue
            
            # 3. Задержка с обратным отсчетом
            log(f"⏳ Задержка {DELAY} секунд перед отправкой...")
            for i in range(DELAY, 0, -1):
                log(f"   Отправка через: {i} сек")
                time.sleep(1)
            
            # 4. Отправка на станок
            log(f"🚀 ОТПРАВКА СЕГМЕНТА НА СТАНОК: {value}")
            
            success = keyboard.type_digits(value)
            
            if success:
                log(f"✅ УСПЕХ! Отправлено: {value}")
                log(f"✅ Цикл #{cycle_count} завершен успешно")
            else:
                log(f"❌ ОШИБКА отправки", "ERROR")
            
            # 5. Короткая пауза между циклами
            log("⏸️  Пауза 2 секунды перед следующим сканированием...")
            time.sleep(2)
            
            print("\n" + "=" * 50)
            
        except KeyboardInterrupt:
            log("🛑 Программа остановлена пользователем")
            break
        except Exception as e:
            log(f"💥 КРИТИЧЕСКАЯ ОШИБКА: {e}", "ERROR")
            time.sleep(5)

# ========== ТОЧКА ВХОДА ==========
if __name__ == "__main__":
    # Проверяем права
    if os.geteuid() != 0:
        print("❌ Запускай с правами root!")
        print("   sudo python3 /opt/production_scanner.py")
        sys.exit(1)
    
    # Создаем директорию для логов если нет
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    
    # Запускаем
    main()
EOF

chmod +x /opt/production_scanner.py

# ================= 8. СОЗДАНИЕ СЕРВИСА ДЛЯ АВТОЗАПУСКА =================
print_info "8. Создание сервиса для автозапуска..."

cat > /etc/systemd/system/production-scanner.service << EOF
[Unit]
Description=Production QR Scanner Service
After=multi-user.target
Requires=network.target

[Service]
Type=simple
User=root
ExecStartPre=/bin/bash -c "/usr/local/bin/find_udc.sh > /tmp/udc_detected.txt"
ExecStartPre=/usr/local/bin/setup_hid_smart.sh
ExecStart=/usr/bin/python3 /opt/production_scanner.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1

# Лимиты
LimitCORE=infinity
LimitNOFILE=65535
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF

# ================= 9. СОЗДАНИЕ СКРИПТА ДЛЯ РУЧНОГО ТЕСТА =================
print_info "9. Создание тестового скрипта..."

cat > /usr/local/bin/test_scanner.sh << 'EOF'
#!/bin/bash
# Тестовый скрипт для проверки работы системы

echo "🧪 ТЕСТ СИСТЕМЫ АВТОМАТИЗАЦИИ"
echo "=============================="

# Проверка UDC
echo "1. Проверка UDC контроллеров..."
UDC_INFO=$(/usr/local/bin/find_udc.sh)
if [ $? -eq 0 ]; then
    echo "   ✅ UDC найден: $UDC_INFO"
else
    echo "   ❌ UDC не найден"
fi

# Проверка доступных UDC
echo "2. Доступные UDC в системе:"
if [ -d /sys/class/udc ]; then
    ls /sys/class/udc/ 2>/dev/null | while read udc; do
        echo "   - $udc"
    done
else
    echo "   ⚠️  Директория /sys/class/udc не существует"
fi

# Проверка HID
echo "3. Проверка HID устройства..."
if [ -e /dev/hidg0 ]; then
    echo "   ✅ /dev/hidg0 существует"
    echo "   📊 Информация:"
    ls -la /dev/hidg*
else
    echo "   ❌ /dev/hidg0 не найден"
    echo "   🔄 Пробую создать..."
    /usr/local/bin/setup_hid_smart.sh
    sleep 2
fi

# Проверка сканера
echo "4. Проверка COM портов..."
ls -la /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -5 || echo "   ⚠️  COM порты не найдены"

# Проверка Python скрипта
echo "5. Проверка Python скрипта..."
if [ -x /opt/production_scanner.py ]; then
    echo "   ✅ Скрипт найден и исполняемый"
    python3 -m py_compile /opt/production_scanner.py 2>/dev/null && echo "   ✅ Синтаксис Python OK"
else
    echo "   ❌ Скрипт не найден"
fi

# Проверка сервиса
echo "6. Проверка сервиса..."
systemctl is-enabled production-scanner.service >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "   ✅ Сервис включен в автозагрузку"
else
    echo "   ⚠️  Сервис не в автозагрузке"
fi

systemctl is-active production-scanner.service >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "   ✅ Сервис запущен"
else
    echo "   ⚠️  Сервис не запущен"
fi

# Проверка логов
echo "7. Проверка логов..."
if [ -e /var/log/scanner.log ]; then
    echo "   ✅ Лог файл существует"
    echo "   📄 Последние 5 строк лога:"
    tail -5 /var/log/scanner.log 2>/dev/null || echo "      (пусто)"
else
    echo "   ⚠️  Лог файл не найден"
fi

# Проверка dmesg
echo "8. Проверка сообщений ядра (последние USB/gadget):"
dmesg | tail -20 | grep -E "(USB|udc|gadget|hid|musb)" | tail -5 || echo "   (нет сообщений)"

echo ""
echo "📋 КОМАНДЫ ДЛЯ УПРАВЛЕНИЯ:"
echo "  sudo systemctl start production-scanner.service    # Запустить"
echo "  sudo systemctl stop production-scanner.service     # Остановить"
echo "  sudo systemctl restart production-scanner.service  # Перезапустить"
echo "  sudo journalctl -u production-scanner.service -f   # Логи в реальном времени"
echo "  sudo /usr/local/bin/test_scanner.sh                # Этот тест"
echo "  sudo /usr/local/bin/find_udc.sh                    # Определить UDC"
echo ""
echo "🧪 Быстрый тест HID (отправит цифру 1):"
echo "  sudo bash -c 'echo -ne \"\\x00\\x00\\x1E\\x00\\x00\\x00\\x00\\x00\" > /dev/hidg0; sleep 0.1; echo -ne \"\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\" > /dev/hidg0'"
echo ""
echo "🔧 Ручная настройка HID:"
echo "  sudo /usr/local/bin/setup_hid.sh                   # Простая настройка"
echo "  sudo /usr/local/bin/setup_hid_smart.sh            # Умная настройка с перебором UDC"
EOF

chmod +x /usr/local/bin/test_scanner.sh

# ================= 10. СОЗДАНИЕ КОНФИГУРАЦИОННОГО ФАЙЛА =================
print_info "10. Создание конфигурационного файла..."

cat > /etc/scanner.conf << 'EOF'
# Конфигурация системы автоматизации производства
# Orange Pi Zero H3 - QR сканер → HID клавиатура

# Порт сканера (автоматически определится как ttyUSB0 или ttyACM0)
SCANNER_PORT="/dev/ttyUSB0"

# Какой сегмент QR кода использовать
# Формат: "123;456;789"
# 0 = первый сегмент (123)
# 1 = второй сегмент (456) 
# 2 = третий сегмент (789)
SEGMENT_NUMBER=1

# Задержка перед отправкой (секунд)
DELAY_BEFORE_SEND=5

# Файл логов
LOG_FILE="/var/log/scanner.log"

# Скорость сканера (обычно 9600 для USB сканеров)
SCANNER_BAUDRATE=9600

# UDC контроллер (определяется автоматически)
# Если система не находит правильный UDC, можно задать вручную:
# UDC_CONTROLLER="musb-hdrc.4.auto"
# UDC_CONTROLLER="musb-hdrc.1.auto"
# UDC_CONTROLLER="musb-hdrc"

# ========== СХЕМА ПОДКЛЮЧЕНИЯ ==========
# 1. Сканер QR → USB порт (большой USB-A)
# 2. Ноутбук/станок → microUSB порт (OTG)
# 3. Питание → через GPIO или дополнительный адаптер
EOF

# ================= 11. ДОБАВЛЕНИЕ UDC В КОНФИГ =================
print_info "11. Определение UDC и добавление в конфиг..."

# Пробуем определить UDC
UDC_RESULT=$(/usr/local/bin/find_udc.sh 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$UDC_RESULT" ]; then
    print_info "✅ Найден UDC: $UDC_RESULT"
    echo "# Автоматически определенный UDC" >> /etc/scanner.conf
    echo "DETECTED_UDC=\"$UDC_RESULT\"" >> /etc/scanner.conf
else
    print_warn "⚠️  UDC не определен автоматически"
    echo "# UDC не определен автоматически" >> /etc/scanner.conf
    echo "# DETECTED_UDC=\"\"" >> /etc/scanner.conf
fi

# ================= 12. ВКЛЮЧЕНИЕ АВТОЗАПУСКА =================
print_info "12. Включение автозапуска..."
systemctl daemon-reload
systemctl enable production-scanner.service

# ================= 13. СОЗДАНИЕ ЛОГ-ФАЙЛА =================
print_info "13. Создание лог-файла..."
mkdir -p /var/log
touch /var/log/scanner.log
chmod 644 /var/log/scanner.log

# ================= 14. ИЗМЕНЕНИЕ НАСТРОЕК СИСТЕМЫ =================
print_info "14. Настройка системы..."

# Отключаем энергосбережение USB
if [ -f /etc/rc.local ]; then
    if ! grep -q "usb_autosuspend" /etc/rc.local; then
        sed -i '/^exit 0/i\# Отключение энергосбережения USB\necho "0" > /sys/module/usbcore/parameters/autosuspend\n' /etc/rc.local
    fi
fi

# ================= 15. ЗАПУСК ТЕСТОВОЙ НАСТРОЙКИ HID =================
print_info "15. Тестовая настройка HID..."
echo ""
print_info "🔧 ПРОБНАЯ НАСТРОЙКА HID..."
print_info "============================="

/usr/local/bin/setup_hid_smart.sh

# ================= 16. ФИНАЛЬНЫЕ ПРОВЕРКИ =================
print_info "16. Финальные проверки..."

echo ""
echo "🔍 ПРОВЕРКА УСТАНОВКИ:"
echo "======================"

# Проверка 1: UDC определение
UDC_TEST=$(/usr/local/bin/find_udc.sh 2>/dev/null)
if [ $? -eq 0 ]; then
    echo "✅ UDC определен: $UDC_TEST"
else
    echo "❌ UDC не определен"
fi

# Проверка 2: HID устройство
if [ -e /dev/hidg0 ]; then
    echo "✅ HID устройство: /dev/hidg0 создано"
    echo "   📊 Размер: $(ls -la /dev/hidg0 | awk '{print $5}') байт"
else
    echo "⚠️  HID устройство не создано"
    echo "   ℹ️  Оно появится при подключении к ноутбуку"
fi

# Проверка 3: Скрипты
SCRIPT_COUNT=0
for script in /usr/local/bin/setup_hid.sh /usr/local/bin/setup_hid_smart.sh /usr/local/bin/find_udc.sh /usr/local/bin/test_scanner.sh /opt/production_scanner.py; do
    if [ -x "$script" ]; then
        SCRIPT_COUNT=$((SCRIPT_COUNT + 1))
    fi
done

if [ $SCRIPT_COUNT -eq 5 ]; then
    echo "✅ Все 5 скриптов созданы и исполняемы"
else
    echo "❌ Проблема со скриптами: $SCRIPT_COUNT/5"
fi

# Проверка 4: Сервис
systemctl is-enabled production-scanner.service >/dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✅ Сервис добавлен в автозагрузку"
else
    echo "❌ Проблема с сервисом"
fi

# Проверка 5: Python библиотеки
python3 -c "import evdev, serial" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "✅ Python библиотеки установлены"
else
    echo "❌ Проблема с Python библиотеками"
fi

echo ""
print_info "========================================"
print_info "🎉 УСТАНОВКА ЗАВЕРШЕНА!"
print_info "========================================"
echo ""
echo "📋 ЧТО ДЕЛАТЬ ДАЛЬШЕ:"
echo "===================="
echo "1. ПОДКЛЮЧЕНИЕ:"
echo "   • Сканер → USB порт (большой)"
echo "   • Ноутбук → microUSB порт (OTG)"
echo "   • Питание → через адаптер или GPIO"
echo ""
echo "2. ЗАПУСК:"
echo "   • Система запустится автоматически при загрузке"
echo "   • Или вручную: sudo systemctl start production-scanner.service"
echo ""
echo "3. ТЕСТ:"
echo "   • Запусти тест: sudo /usr/local/bin/test_scanner.sh"
echo "   • Смотри логи: sudo journalctl -u production-scanner.service -f"
echo ""
echo "4. ИСПОЛЬЗОВАНИЕ:"
echo "   • Открой на ноутбуке блокнот или программу станка"
echo "   • Установи курсор в поле ввода"
echo "   • Отсканируй QR-код: XXX;YYY;ZZZ"
echo "   • Через 5 секунд данные отправятся автоматически"
echo ""
echo "5. ЕСЛИ НЕ РАБОТАЕТ:"
echo "   • Проверь подключение кабелей"
echo "   • Запусти: sudo /usr/local/bin/setup_hid_smart.sh"
echo "   • Посмотри: dmesg | tail -30"
echo "   • Определи UDC: sudo /usr/local/bin/find_udc.sh"
echo ""
echo "6. НАСТРОЙКИ:"
echo "   • Конфиг: /etc/scanner.conf"
echo "   • Основной скрипт: /opt/production_scanner.py"
echo "   • UDC определитель: /usr/local/bin/find_udc.sh"
echo ""
echo "🚀 ДЛЯ ЗАПУСКА СИСТЕМЫ:"
echo "   sudo systemctl start production-scanner.service"
echo ""
echo "📞 ДЛЯ ДИАГНОСТИКИ:"
echo "   • Логи: sudo journalctl -u production-scanner.service -f"
echo "   • UDC: sudo /usr/local/bin/find_udc.sh"
echo "   • Тест: sudo /usr/local/bin/test_scanner.sh"
echo ""
print_info "========================================"

# ================= 17. ПРЕДЛОЖЕНИЕ ПЕРЕЗАГРУЗИТЬ =================
echo ""
read -p "Перезагрузить сейчас? (y/n): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_info "Перезагружаюсь..."
    reboot
fi

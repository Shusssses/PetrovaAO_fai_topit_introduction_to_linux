#!/bin/bash

die() {
  echo "Ошибка выполнения $1" >&2
  exit $1
}

usage() {
    echo "Использование: $0 [ИМЯ_ФАЙЛА_ОТЧЁТА]"
    echo "По умолчанию отчёт сохраняется в PASSPORT/inventory.txt"
    echo "Скрипт требует прав root или пользователя с рабочим sudo."
    echo "Коды ошибок: 100 - права, 200 - функция, 250 - утилита"
	echo "Для вывода этой справки добавьте ключ -h или --help"
}


check_privileges () {
  if [ "$EUID" -ne 0 ]; then
    echo "У вас недостаточно прав для запуска скрипта"
    exit 100
  fi
}

check_tool() {
  if [[ $(which "$1") == "" ]]; then
    echo "Команда $1 не найдена, перед запуском необходимо её установить"
    die 250
  fi
}

log_run() {
  cur_date=$(date +"%Y.%m.%d")
  echo "Скрипт был запущен: $cur_date" >> PASSPORT/log/report.log
  echo "Используемая версия скрипта: V3" >> PASSPORT/log/report.log
  echo "===================================" >> PASSPORT/log/report.log
}

write_section() {
  local title="$1"
  local content_file="$2"
  echo "=== $title ===" >> "$name".txt
  if [ -s "$content_file" ]; then
    cat "$content_file" >> "$name".txt
  else
    echo "Нет данных" >> "$name".txt
  fi
  echo "" >> "$name".txt
}

clean_up() {
  find . -type f -name "*.tmp" -delete
}

mkdir -p PASSPORT/log
mkdir -p PASSPORT/tmp

if [[ $1 != "" ]]; then
  name=$1
else
  name="inventory"
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

check_privileges
log_run

date > PASSPORT/tmp/date.tmp
hostname > PASSPORT/tmp/hostname.tmp
whoami > PASSPORT/tmp/whoami.tmp
who > PASSPORT/tmp/who.tmp
pwd > PASSPORT/tmp/pwd.tmp
ls -la > PASSPORT/tmp/ls.tmp

#проверка наличия утилит
check_tool lspci
check_tool dmidecode
check_tool lscpu
check_tool lastlog2
check_tool uname
check_tool lsmem

#ядро и разрядность
uname -a > PASSPORT/tmp/uname.tmp
uname -m > PASSPORT/tmp/arch.tmp

#версия ОС
cat /etc/os-release > PASSPORT/tmp/os.tmp

#инфо о процессоре
lscpu > PASSPORT/tmp/lscpu.tmp

#инфо о памяти
lsmem > PASSPORT/tmp/lsmem.tmp

#устройства PCI
lspci > PASSPORT/tmp/lspci.tmp

#инфо о мат плате и биос
dmidecode -t baseboard > PASSPORT/tmp/baseboard.tmp
dmidecode -t bios > PASSPORT/tmp/bios.tmp

#пользователи (root и UID >= 1000)
> PASSPORT/tmp/users.tmp
# getent passwd выводит список всех пользователей, разделенный двоеточиями (имя:пароль:UID:...)
# awk отбирает строки, где 3-е поле (UID) равно 0 или больше/равно 1000 (но меньше 65534, чтобы отсечь nobody)
USERS=$(getent passwd | awk -F: '$3 == 0 || ($3 >= 1000 && $3 < 65534) {print $1}')
for user in $USERS; do
    echo "Пользователь: $user (UID: $(id -u "$user"))" >> PASSPORT/tmp/users.tmp
    echo "  Группы: $(id -nG "$user")" >> PASSPORT/tmp/users.tmp
    
    # Последний вход
    # lastlog -u показывает последний вход; tail -n 1 отрезает шапку таблицы, оставляя только строку с данными
    login_info=$(lastlog2 -u "$user" | tail -n 1)
    echo "  Последний вход: $login_info" >> PASSPORT/tmp/users.tmp
    
    # chage -l показывает информацию о пароле; grep оставляет строку со сменой пароля; cut берет текст после двоеточия
    pwd_changed=$(sudo LC_ALL=C chage -l "$user" | grep -E "Last password change" | cut -d: -f2 | xargs)
    echo "  Последняя смена пароля: ${pwd_changed:-Нет данных}" >> PASSPORT/tmp/users.tmp
    echo "-----------------------------------" >> PASSPORT/tmp/users.tmp
done

#параметры sshd
sshd -T | grep -E "^(permitrootlogin|port|logingracetime|maxauthtries|passwordauthentication|pubkeyauthentication) " > PASSPORT/tmp/sshd.tmp

#топ 5 процессов по памяти
ps -eo pid,ppid,user,%mem,cmd --sort=-%mem | head -n 6 > PASSPORT/tmp/top5.tmp

#подозрительные учетные записи
> PASSPORT/tmp/suspicious.tmp
echo "Пользователи с UID 0 (кроме root):" >> PASSPORT/tmp/suspicious.tmp
awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd >> PASSPORT/tmp/suspicious.tmp
echo "Пользователи с пустым паролем:" >> PASSPORT/tmp/suspicious.tmp
sudo awk -F: 'length($2) == 0 {print $1}' /etc/shadow 2>/dev/null >> PASSPORT/tmp/suspicious.tmp

#файлы с suid
find /usr/bin /usr/sbin -type f -perm -4000 > PASSPORT/tmp/suid.tmp

cat > "$name".txt << EOF
===========ДИАГНОСТИЧЕСКИЙ ОТЧЕТ О СИСТЕМЕ (v3) ===============

=== Информация о хосте ===
Дата формирования: $(cat PASSPORT/tmp/date.tmp)
Имя хоста: $(cat PASSPORT/tmp/hostname.tmp)

=== Информация о пользователях ===
Пользователь, запустивший скрипт: $(cat PASSPORT/tmp/whoami.tmp)
Залогиненные пользователи: $(cat PASSPORT/tmp/who.tmp)

=== Информация о текущем каталоге ===
Текущий каталог: $(cat PASSPORT/tmp/pwd.tmp)
Содержимое каталога: $(cat PASSPORT/tmp/ls.tmp)

=== Информация о ядре и системе ===
Версия ядра: $(cat PASSPORT/tmp/uname.tmp)
Разрядность системы: $(cat PASSPORT/tmp/arch.tmp)

=== Версия ОС ===
$( grep -E "^(PRETTY_NAME|NAME|VERSION)=" PASSPORT/tmp/os.tmp | sed 's/"//g')

=== Информация о процессоре ===
Модель процессора: $(grep "Model name" PASSPORT/tmp/lscpu.tmp | sed 's/Model name: *//')
Частота CPU (MHz): $(grep "CPU MHz" PASSPORT/tmp/lscpu.tmp | head -1 | sed 's/CPU MHz: *//')
Количество логических ядер: $(grep "CPU(s):" PASSPORT/tmp/lscpu.tmp | head -1 | sed 's/CPU(s): *//')

=== Кэш процессора ===
$( grep -E "L1d cache|L1i cache|L2 cache|L3 cache" PASSPORT/tmp/lscpu.tmp)

=== Оперативная память ===
$( grep -E "Total online memory|Memory block size" PASSPORT/tmp/lsmem.tmp | head -2)

=== Материнская плата ===
$( grep -E "Manufacturer|Product Name|Version|Serial Number" PASSPORT/tmp/baseboard.tmp)

=== BIOS ===
$( grep -E "Vendor|Version|Release Date" PASSPORT/tmp/bios.tmp)

=== Устройства PCI ===
$(cat PASSPORT/tmp/lspci.tmp)

=========================================================
EOF

write_section "Пользователи (root и обычные, UID >= 1000)" PASSPORT/tmp/users.tmp
write_section "Параметры sshd (эффективные значения)" PASSPORT/tmp/sshd.tmp
write_section "Топ-5 процессов по потреблению памяти (%MEM)" PASSPORT/tmp/top5.tmp
write_section "Подозрительные учётные записи" PASSPORT/tmp/suspicious.tmp
write_section "Файлы с установленным битом SUID в /usr/bin и /usr/sbin" PASSPORT/tmp/suid.tmp

echo "Скрипт был запущен: $(date)" >> PASSPORT/log/report.log

clean_up

echo "Отчёт успешно сформирован: PASSPORT/$name.txt"


#!/bin/sh
# Sony VAIO VGN-P31ZK / Option GTM382 GPS GUI switch for Debian 12 i386.
# Review before running. Run once as root: sh install-vaio-gps-gui.sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo 'Run this installer as root: su -c "sh install-vaio-gps-gui.sh"' >&2
    exit 1
fi
if [ ! -c /dev/ttyHS1 ] || [ ! -c /dev/ttyHS2 ]; then
    echo 'Missing /dev/ttyHS1 or /dev/ttyHS2. Check the hso driver and WWAN power.' >&2
    exit 1
fi

# Install only common Debian 12 packages; polkit agent supplies graphical auth dialogs.
apt-get install -y zenity pkexec policykit-1-gnome gpsd gpsd-clients

# The user already confirmed an AppArmor denial for /dev/ttyHS1.
PROFILE=/etc/apparmor.d/usr.sbin.gpsd
LOCAL=/etc/apparmor.d/local/usr.sbin.gpsd
if [ -f "$PROFILE" ]; then
    if ! grep -Fq 'include <local/usr.sbin.gpsd>' "$PROFILE"; then
        echo "AppArmor profile does not include $LOCAL. Configure this before proceeding." >&2
        exit 1
    fi
    mkdir -p /etc/apparmor.d/local
    touch "$LOCAL"
    if ! grep -Fq '/dev/ttyHS1 rw,' "$LOCAL"; then
        printf '%s\n' '/dev/ttyHS1 rw,' >> "$LOCAL"
    fi
    apparmor_parser -r "$PROFILE"
fi

# Restore kernel's regular device ownership (the gpsd user is in group dialout).
chown root:dialout /dev/ttyHS1
chmod 660 /dev/ttyHS1

# Configure Debian's gpsd.service to open the already-running NMEA stream.
if [ -f /etc/default/gpsd ]; then
    cp -p /etc/default/gpsd "/etc/default/gpsd.vaio-backup-$(date +%Y%m%d-%H%M%S)"
fi
cat > /etc/default/gpsd <<'GPSD_DEFAULTS'
START_DAEMON="false"
GPSD_OPTIONS="-n -b"
DEVICES="/dev/ttyHS1"
USBAUTO="false"
GPSD_DEFAULTS

# Prevent background auto-restart: the GUI is responsible for ON/OFF.
systemctl disable --now gpsd.service gpsd.socket >/dev/null 2>&1 || true

# Root-only backend. pkexec can run only this fixed, root-owned script.
cat > /usr/local/sbin/vaio-gpsctl <<'BACKEND'
#!/bin/sh
set -eu
if [ "$(id -u)" -ne 0 ] || [ "$#" -ne 1 ]; then
    echo 'Usage (as root): vaio-gpsctl on|off' >&2
    exit 2
fi
[ -c /dev/ttyHS2 ] || { echo 'GPS Control port is missing' >&2; exit 1; }
case "$1" in
    on)
        [ -c /dev/ttyHS1 ] || { echo 'GPS Data port is missing' >&2; exit 1; }
        printf 'AT_OGPSP=7,1\r' > /dev/ttyHS2
        sleep 1
        printf 'AT_OGPS=2\r' > /dev/ttyHS2
        sleep 1
        systemctl start gpsd.socket
        systemctl start gpsd.service
        systemctl is-active --quiet gpsd.service
        ;;
    off)
        systemctl stop gpsd.socket gpsd.service
        printf 'AT_OGPS=0\r' > /dev/ttyHS2
        ;;
    *) echo 'Usage: vaio-gpsctl on|off' >&2; exit 2 ;;
esac
BACKEND
chown root:root /usr/local/sbin/vaio-gpsctl
chmod 0755 /usr/local/sbin/vaio-gpsctl

# Desktop dialog (runs as the logged-in user, not as root).
cat > /usr/local/bin/vaio-gps-gui <<'FRONTEND'
#!/bin/sh
if systemctl is-active --quiet gpsd.service; then
    state='gpsd запущен (это не обязательно означает GPS-фиксацию)'
else
    state='gpsd остановлен'
fi
choice=$(zenity --list \
    --title='VAIO GPS' \
    --text="Текущее состояние: $state\nВыберите действие:" \
    --column='Действие' \
    'Включить GPS' \
    'Выключить GPS' \
    --width=490 --height=255) || exit 0
case "$choice" in
    'Включить GPS') action=on; message='GPS включён. Можно открыть cgps или Navit.' ;;
    'Выключить GPS') action=off; message='GPS выключен.' ;;
    *) exit 0 ;;
esac
if pkexec /usr/local/sbin/vaio-gpsctl "$action"; then
    zenity --info --title='VAIO GPS' --text="$message"
else
    zenity --error --title='VAIO GPS' \
        --text='Не удалось выполнить операцию. Проверьте авторизацию polkit и журнал gpsd.'
fi
FRONTEND
chown root:root /usr/local/bin/vaio-gps-gui
chmod 0755 /usr/local/bin/vaio-gps-gui

# Visible in applications menu; users can add it to desktop/panel.
mkdir -p /usr/local/share/applications
cat > /usr/local/share/applications/vaio-gps.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=VAIO GPS
Comment=Enable or disable the built-in GPS receiver
Comment[ru]=Включение и выключение встроенного GPS
Exec=/usr/local/bin/vaio-gps-gui
Icon=network-wireless
Terminal=false
Categories=Utility;System;
StartupNotify=false
DESKTOP
chmod 0644 /usr/local/share/applications/vaio-gps.desktop

echo 'Installed: VAIO GPS is now available in the desktop applications menu.'
echo 'If no password dialog appears, log out and log in to start the polkit agent.'

#!/bin/sh
# Sony VAIO P / Debian 12 LXDE: system-wide Fn+F9/F10 font DPI shortcuts
set -eu
if [ "$(id -u)" -ne 0 ]; then
    echo 'Run as root: sh install-vaio-font-zoom.sh' >&2
    exit 1
fi

apt-get install -y xbindkeys x11-xserver-utils

install -d -m 0755 /etc/vaio /etc/udev/hwdb.d /usr/local/bin

cat > /usr/local/bin/vaio-font-zoom <<'ZOOM'
#!/bin/sh
# Run as the logged-in X11 desktop user; no root privileges needed.
set -eu
case "${1:-}" in
    in|out|reset|status) ;;
    *) echo 'Usage: vaio-font-zoom {in|out|reset|status}' >&2; exit 2 ;;
esac

current=$(xrdb -query 2>/dev/null | awk '$1 == "Xft.dpi:" {print $2; exit}')
case "$current" in
    ''|*[!0-9]*) current=120 ;;
esac

case "$1" in
    in) next=$((current + 12)) ;;
    out) next=$((current - 12)) ;;
    reset) next=120 ;;
    status) printf '%s DPI\n' "$current"; exit 0 ;;
esac
[ "$next" -ge 96 ] || next=96
[ "$next" -le 180 ] || next=180

printf 'Xft.dpi: %s\n' "$next" | xrdb -merge
# Some X11 clients read the X server DPI rather than Xft.dpi.
xrandr --dpi "$next" >/dev/null 2>&1 || true
if command -v notify-send >/dev/null 2>&1; then
    notify-send -t 1600 'Sony VAIO' "Масштаб шрифтов: ${next} DPI" || true
fi
printf '%s DPI\n' "$next"
ZOOM
chmod 0755 /usr/local/bin/vaio-font-zoom

# Previously reported Sony Vaio Keys: scan 0d = Fn+F9, scan 0e = Fn+F10.
# Remap Linux keycodes above X11's traditional range to standard F13/F14.
cat > /etc/udev/hwdb.d/70-vaio-p-zoom.hwdb <<'HWDB'
evdev:name:Sony Vaio Keys:dmi:*
 KEYBOARD_KEY_0d=f13
 KEYBOARD_KEY_0e=f14
HWDB

if command -v systemd-hwdb >/dev/null 2>&1; then
    systemd-hwdb update
else
    udevadm hwdb --update
fi

if [ ! -f /etc/vaio/keys.conf ]; then
    cat > /etc/vaio/keys.conf <<'KEYS'
# Sony VAIO P: special buttons
"/usr/local/bin/vaio-gps-gui"
    XF86Launch1
"/usr/bin/xgps"
    XF86Launch2
KEYS
fi
if ! grep -Fq '# VAIO_FN_ZOOM_BEGIN' /etc/vaio/keys.conf; then
    cat >> /etc/vaio/keys.conf <<'KEYS'

# VAIO_FN_ZOOM_BEGIN
# Sony VAIO P: Fn+F9 decreases font DPI, Fn+F10 increases it
"/usr/local/bin/vaio-font-zoom out"
    F13
"/usr/local/bin/vaio-font-zoom in"
    F14
# VAIO_FN_ZOOM_END
KEYS
fi
chmod 0644 /etc/vaio/keys.conf

if [ ! -e /etc/xdg/autostart/vaio-hotkeys.desktop ]; then
    install -d -m 0755 /etc/xdg/autostart
    cat > /etc/xdg/autostart/vaio-hotkeys.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Sony VAIO Hotkeys
Comment=VAIO GPS and Zoom keys
Exec=/usr/bin/xbindkeys -n -f /etc/vaio/keys.conf
Terminal=false
OnlyShowIn=LXDE;
DESKTOP
    chmod 0644 /etc/xdg/autostart/vaio-hotkeys.desktop
fi

cat <<'MESSAGE'
Installed.
Reboot once so udev's Sony Vaio Keys remapping (Fn+F9/F10 -> F13/F14) applies.
After graphical login, xbindkeys will launch using /etc/vaio/keys.conf.
Test in the LXDE session as a normal user:
    vaio-font-zoom in
    vaio-font-zoom out
    vaio-font-zoom status
    xmodmap -pke | grep -E 'F13|F14'
Existing S1 and S2 shortcuts were preserved if keys.conf already existed.
Changes to DPI update some windows only after reopening them; 120 DPI is the reset setting.
MESSAGE

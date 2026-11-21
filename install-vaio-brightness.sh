#!/bin/sh
# Sony VAIO P Fn+F5/Fn+F6 brightness keys for Debian 12 i386
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo 'Run as root: sh install-vaio-brightness.sh' >&2
    exit 1
fi

if [ ! -d /sys/class/backlight ] || ! ls /sys/class/backlight/*/brightness >/dev/null 2>&1; then
    echo 'No /sys/class/backlight/*/brightness interface found.' >&2
    echo 'The backlight driver must be fixed before brightness hotkeys can work.' >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get install -y python3-evdev evtest

cat > /usr/local/sbin/vaio-brightness-keys <<'PY'
#!/usr/bin/python3
"""Adjust VAIO P LCD hardware backlight from brightness key input events."""
import os
import select
import sys
import time
from evdev import InputDevice, ecodes, list_devices

PREFERRED_BACKLIGHTS = ("psb-bl", "sony", "intel_backlight", "acpi_video0")
BRIGHT_UP = ecodes.KEY_BRIGHTNESSUP
BRIGHT_DOWN = ecodes.KEY_BRIGHTNESSDOWN


def find_backlight():
    root = '/sys/class/backlight'
    try:
        available = os.listdir(root)
    except OSError:
        return None
    ordered = [p for p in PREFERRED_BACKLIGHTS if p in available]
    ordered.extend(p for p in available if p not in ordered)
    for name in ordered:
        path = os.path.join(root, name)
        if all(os.path.isfile(os.path.join(path, field)) for field in ('brightness', 'max_brightness')):
            return path
    return None


def adjust(direction):
    path = find_backlight()
    if not path:
        print('No hardware backlight device found', flush=True)
        return False
    try:
        with open(os.path.join(path, 'max_brightness'), encoding='ascii') as f:
            maximum = int(f.read().strip())
        with open(os.path.join(path, 'brightness'), encoding='ascii') as f:
            current = int(f.read().strip())
        if maximum < 1:
            raise ValueError('max_brightness < 1')
        # One step on 8-level screens; about 5% on fine-grained devices.
        step = max(1, round(maximum * 0.05))
        updated = max(1, min(maximum, current + direction * step))
        if updated != current:
            with open(os.path.join(path, 'brightness'), 'w', encoding='ascii') as f:
                f.write(str(updated) + '\n')
        print(f'{os.path.basename(path)}: {current} -> {updated} (max {maximum})', flush=True)
        return True
    except (OSError, ValueError) as exc:
        print(f'Brightness adjustment failed: {exc}', flush=True)
        return False


def devices_with_hotkeys():
    found = {}
    for path in list_devices():
        try:
            dev = InputDevice(path)
            caps = dev.capabilities().get(ecodes.EV_KEY, [])
            if BRIGHT_UP in caps or BRIGHT_DOWN in caps:
                found[dev.fd] = dev
            else:
                dev.close()
        except (OSError, PermissionError):
            continue
    return found


def diagnose():
    print('Hardware backlight:', find_backlight() or 'NOT FOUND')
    print('Input devices that advertise brightness keys:')
    devices = devices_with_hotkeys()
    if not devices:
        print('  NONE. Check key events with evtest or acpi_listen.')
    for dev in devices.values():
        print(f'  {dev.path}: {dev.name}')
        dev.close()


def main():
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg == '--check':
            diagnose()
            return
        if arg in ('up', 'down'):
            sys.exit(0 if adjust(+1 if arg == 'up' else -1) else 1)
        print('Usage: vaio-brightness-keys [--check|up|down]', file=sys.stderr)
        sys.exit(2)

    path = find_backlight()
    if not path:
        print('No hardware backlight device available; retrying', flush=True)
    else:
        print(f'Backlight device: {path}', flush=True)
    # Never grab devices: X11/Wayland can keep using the keyboard.
    while True:
        devices = devices_with_hotkeys()
        if not devices:
            print('Waiting for a brightness-capable input device...', flush=True)
            time.sleep(5)
            continue
        print('Listening on ' + ', '.join(f'{d.name} ({d.path})' for d in devices.values()), flush=True)
        try:
            while True:
                ready, _, _ = select.select(list(devices.values()), [], [], 5)
                for dev in ready:
                    for event in dev.read():
                        if event.type != ecodes.EV_KEY or event.value not in (1, 2):
                            continue
                        if event.code == BRIGHT_UP:
                            adjust(+1)
                        elif event.code == BRIGHT_DOWN:
                            adjust(-1)
                # Re-enumerate periodically to recover after suspend/udev replacement.
                known = {d.path for d in devices.values()}
                current = set(list_devices())
                if not known.issubset(current):
                    print('Input devices changed; reopening', flush=True)
                    break
        except (OSError, ValueError) as exc:
            print(f'Input device changed: {exc}', flush=True)
        finally:
            for dev in devices.values():
                dev.close()
        time.sleep(1)


if __name__ == '__main__':
    main()
PY

chmod 755 /usr/local/sbin/vaio-brightness-keys

cat > /etc/systemd/system/vaio-brightness-keys.service <<'SERVICE'
[Unit]
Description=Sony VAIO P brightness hotkeys (Fn+F5/Fn+F6)
After=systemd-udevd.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u /usr/local/sbin/vaio-brightness-keys
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now vaio-brightness-keys.service

echo
echo 'Installed. Backlight and available input devices:'
/usr/local/sbin/vaio-brightness-keys --check
echo
echo 'Press Fn+F5 and Fn+F6. Follow logs with:'
echo '  journalctl -u vaio-brightness-keys.service -f'
echo 'If a key does nothing, run evtest as root and check the emitted keycode.'

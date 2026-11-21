#!/bin/sh
# Sony VAIO P / Debian 12: sleep, AC profiles, firmware-controlled fan.
set -eu

[ "$(id -u)" -eq 0 ] || { echo 'Run as root: sh install-vaio-power.sh' >&2; exit 1; }

PROFILE_SCRIPT=/usr/local/sbin/vaio-power-profile
SERVICE=/etc/systemd/system/vaio-power-profile.service
UDEV_RULE=/etc/udev/rules.d/80-vaio-power-profile.rules
RESUME_HOOK=/lib/systemd/system-sleep/vaio-power-profile
SLEEP_CONF=/etc/systemd/sleep.conf.d/zz-vaio-power.conf
LOGIND_CONF=/etc/systemd/logind.conf.d/zz-vaio-power.conf

if [ "${1:-}" = '--uninstall' ]; then
    systemctl disable --now vaio-power-profile.service 2>/dev/null || true
    rm -f "$PROFILE_SCRIPT" "$SERVICE" "$UDEV_RULE" "$RESUME_HOOK" "$SLEEP_CONF" "$LOGIND_CONF"
    systemctl daemon-reload
    udevadm control --reload-rules
    echo 'VAIO power automation removed. Earlier systemd/LXDE settings are untouched.'
    echo 'Reboot or log out/in to apply previous lid behaviour.'
    exit 0
fi
[ "$#" -eq 0 ] || { echo "Usage: sh $0 [--uninstall]" >&2; exit 2; }

SONY=/sys/devices/platform/sony-laptop
AC=/sys/class/power_supply/AC/online
[ -r "$AC" ] && [ -w "$SONY/thermal_control" ] && [ -r "$SONY/thermal_profiles" ] || {
    echo 'AC and Sony thermal profile sysfs interfaces are required; nothing installed.' >&2
    exit 1
}
for p in balanced performance; do
    case " $(cat "$SONY/thermal_profiles") " in
        *" $p "*) : ;;
        *) echo "Profile $p unavailable; nothing installed." >&2; exit 1 ;;
    esac
done

install -d -m 0755 /usr/local/sbin /etc/systemd/system /etc/udev/rules.d \
    /lib/systemd/system-sleep /etc/systemd/sleep.conf.d /etc/systemd/logind.conf.d

cat > "$PROFILE_SCRIPT" <<'EOF'
#!/bin/sh
# Re-read the power source each time. Keep firmware in control of fan speed.
set -eu
AC=/sys/class/power_supply/AC/online
P=/sys/devices/platform/sony-laptop
[ -r "$AC" ] && [ -w "$P/thermal_control" ] && [ -r "$P/thermal_profiles" ] || exit 0
case "$(cat "$AC")" in
    1) profile=performance ;;
    0) profile=balanced ;;
    *) exit 0 ;;
esac
case " $(cat "$P/thermal_profiles") " in
    *" $profile "*) : ;;
    *) exit 0 ;;
esac
current=$(cat "$P/thermal_control")
if [ "$current" != "$profile" ]; then
    printf '%s\n' "$profile" > "$P/thermal_control"
    logger -t vaio-power-profile "Changed Sony thermal profile: $current -> $profile"
fi
EOF
chmod 0755 "$PROFILE_SCRIPT"

cat > "$SERVICE" <<'EOF'
[Unit]
Description=Select Sony VAIO thermal profile for AC/battery
ConditionPathExists=/sys/devices/platform/sony-laptop/thermal_control

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vaio-power-profile

[Install]
WantedBy=multi-user.target
EOF

cat > "$UDEV_RULE" <<'EOF'
# AC change event: switch Sony thermal profile. This action runs quickly.
ACTION=="change", SUBSYSTEM=="power_supply", KERNEL=="AC", RUN+="/usr/local/sbin/vaio-power-profile"
EOF

cat > "$RESUME_HOOK" <<'EOF'
#!/bin/sh
# Recheck power source after a suspend/resume cycle.
[ "${1:-}" = post ] && /usr/local/sbin/vaio-power-profile || true
exit 0
EOF
chmod 0755 "$RESUME_HOOK"

cat > "$SLEEP_CONF" <<'EOF'
[Sleep]
AllowSuspend=yes
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
SuspendState=mem
EOF

cat > "$LOGIND_CONF" <<'EOF'
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF

systemctl daemon-reload
udevadm control --reload-rules
systemctl enable --now vaio-power-profile.service

echo 'Installed VAIO power policy:'
printf '  AC adapter: %s\n' "$(cat "$AC")"
printf '  Sony profile: %s\n' "$(cat "$SONY/thermal_control")"
printf '  Sleep mode: %s\n' "$(cat /sys/power/mem_sleep)"
printf '  Fan reading: %s (firmware controlled)\n' "$(cat "$SONY/fanspeed")"
echo 'Lid policy takes effect after a reboot; LXDE power manager may override logind lid handling.'

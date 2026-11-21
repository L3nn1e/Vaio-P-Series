#!/usr/bin/env bash
# Sony VAIO P / Option GTM382: synchronize GPS and modem clocks from Debian.
set -euo pipefail

if (( EUID != 0 )); then
    echo 'Run this installer as root: sudo bash install-vaio-gtm382-clock.sh' >&2
    exit 1
fi
for tool in systemctl timedatectl flock; do
    command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 1; }
done

cat > /usr/local/sbin/vaio-gtm382-clock-sync <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
PORT=/dev/ttyHS2

# GTM382 has no battery-backed modem/GPS clock. Never copy an unverified OS date.
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" != yes ]]; then
    echo 'Debian clock is not NTP-synchronized. Skipping GTM382 clock update.'
    exit 0
fi
if [[ ! -c "$PORT" ]]; then
    echo "GTM382 control port $PORT is not available. Skipping."
    exit 0
fi

# Prevent simultaneous invocations of this time-sync script.
exec 9>/run/lock/vaio-gtm382-clock.lock
flock -w 5 9 || { echo 'Clock sync already running.' >&2; exit 1; }

# The hso driver already handles the port configuration; no stty required.
exec 3<>"$PORT"

send_at() {
    local cmd="$1" reply n
    printf '%s\r' "$cmd" >&3
    for ((n=0; n<12; n++)); do
        if IFS= read -r -t 2 reply <&3; then
            reply="${reply%$'\r'}"
            case "$reply" in
                OK) return 0 ;;
                ERROR|*ERROR:*)
                    printf 'GTM382 rejected %s: %s\n' "${cmd%%=*}" "$reply" >&2
                    return 1
                    ;;
            esac
        fi
    done
    printf 'No OK response for %s\n' "${cmd%%=*}" >&2
    return 1
}

# Use UTC for both clocks. Firmware 2.9.5.0Hd supports AT_OGCLK.
failed=0
send_at "AT_OGCLK=\"$(date -u '+%y/%m/%d,%H:%M:%S+00')\"" || failed=1
send_at "AT+CCLK=\"$(date -u '+%y/%m/%d,%H:%M:%S+00')\"" || failed=1
if (( failed )); then
    echo "One or both GTM382 clocks could not be synchronized." >&2
    exit 1
fi
echo "GTM382 GPS and modem clocks synchronized: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
SCRIPT
chmod 755 /usr/local/sbin/vaio-gtm382-clock-sync

cat > /etc/systemd/system/vaio-gtm382-clock.service <<'SERVICE'
[Unit]
Description=Synchronize Sony VAIO GTM382 GPS and modem clocks

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vaio-gtm382-clock-sync
SERVICE

cat > /etc/systemd/system/vaio-gtm382-clock.timer <<'TIMER'
[Unit]
Description=Keep GTM382 GPS and modem clocks up to date

[Timer]
OnBootSec=90s
OnUnitInactiveSec=15min
AccuracySec=30s
Unit=vaio-gtm382-clock.service

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now vaio-gtm382-clock.timer

if [[ "$(timedatectl show -p NTP --value 2>/dev/null || true)" != yes ]]; then
    if ! timedatectl set-ntp true; then
        echo 'Could not enable NTP. Check your time sync provider (systemd-timesyncd/chrony).' >&2
    fi
fi

echo
printf 'Installed. GPS clock sync schedule:\n'
systemctl list-timers --all vaio-gtm382-clock.timer --no-pager
printf '\nCheck Debian time: timedatectl status\n'
printf 'Force a check: systemctl start vaio-gtm382-clock.service\n'
printf 'Check result: journalctl -u vaio-gtm382-clock.service -n 20 --no-pager\n'

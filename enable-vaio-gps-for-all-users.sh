#!/bin/sh
# Enable passwordless VAIO GPS on/off for any active local user.
# Debian 12 / polkit / existing /usr/local/sbin/vaio-gpsctl backend.
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo 'Run as root: sh enable-vaio-gps-for-all-users.sh' >&2
  exit 1
fi

BACKEND=/usr/local/sbin/vaio-gpsctl
POLICY=/usr/share/polkit-1/actions/org.vaio.gpsctl.policy

if [ ! -f "$BACKEND" ] || [ ! -x "$BACKEND" ]; then
  echo "Missing $BACKEND. Install VAIO GPS GUI first." >&2
  exit 1
fi
if ! command -v pkexec >/dev/null 2>&1; then
  echo 'pkexec not installed. Install package pkexec first.' >&2
  exit 1
fi

# The helper must not be editable by regular users. It accepts only on/off.
chown root:root "$BACKEND"
chmod 0755 "$BACKEND"

mkdir -p /usr/share/polkit-1/actions
TMP=$(mktemp /usr/share/polkit-1/actions/.org.vaio.gpsctl.XXXXXX)
trap 'rm -f "$TMP"' EXIT HUP INT TERM
cat > "$TMP" <<'POLICY_XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD polkit Policy Configuration 1.0//EN"
  "http://www.freedesktop.org/software/polkit/policyconfig-1.dtd">
<policyconfig>
  <action id="org.vaio.gpsctl">
    <description>Control built-in Sony VAIO GPS</description>
    <message>Permission is required to switch the built-in VAIO GPS</message>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/sbin/vaio-gpsctl</annotate>
  </action>
</policyconfig>
POLICY_XML
chown root:root "$TMP"
chmod 0644 "$TMP"
mv -f "$TMP" "$POLICY"
trap - EXIT HUP INT TERM

if command -v pkaction >/dev/null 2>&1; then
  pkaction --action-id org.vaio.gpsctl --verbose || true
fi

echo 'Installed: all active local desktop users may run VAIO GPS on/off without an admin password.'
echo 'Test as a regular user: /usr/local/bin/vaio-gps-gui'
echo "To revoke: rm '$POLICY'"

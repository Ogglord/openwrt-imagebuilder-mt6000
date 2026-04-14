# ASU server — consuming branches.json

## Published URL

```
https://raw.githubusercontent.com/Ogglord/openwrt-imagebuilder-mt6000/releases/branches.json
```

Updated automatically after each successful imagebuilder CI run.

## Update script

Save as e.g. `/opt/asu/update-branches.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

BRANCHES_URL="https://raw.githubusercontent.com/Ogglord/openwrt-imagebuilder-mt6000/releases/branches.json"
ENV_FILE="/opt/asu/.env"

# Fetch and validate
JSON=$(curl -fsSL "$BRANCHES_URL")
echo "$JSON" | jq empty   # exits non-zero if invalid JSON

# Compact to a single line for the .env value
BRANCHES=$(echo "$JSON" | jq -c .)

# Update or insert BRANCHES= in .env
if grep -q '^BRANCHES=' "$ENV_FILE"; then
  sed -i "s|^BRANCHES=.*|BRANCHES=${BRANCHES}|" "$ENV_FILE"
else
  echo "BRANCHES=${BRANCHES}" >> "$ENV_FILE"
fi

# Restart the ASU stack
podman-compose -f /opt/asu/docker-compose.yml up -d
```

## Systemd timer (hourly)

`/etc/systemd/system/asu-update-branches.service`:
```ini
[Unit]
Description=Update ASU branches.json
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/asu/update-branches.sh
```

`/etc/systemd/system/asu-update-branches.timer`:
```ini
[Unit]
Description=Update ASU branches.json hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

Enable with:
```bash
systemctl enable --now asu-update-branches.timer
```

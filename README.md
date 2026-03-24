# garage — Raspberry Pi 5 LTE Internet Sharing

Ansible automation for a Raspberry Pi 5 (`garage`, Debian 13 Trixie) that shares LTE internet over Ethernet, monitors a UPS HAT, and provides remote SSH access via Twingate.

## Hardware

| Component | Details |
|---|---|
| Board | Raspberry Pi 5 |
| Modem | Waveshare A7670E Cat-1 HAT (USB, RNDIS mode) |
| UPS | Waveshare UPS HAT B (INA219, I2C bus 1, addr 0x42, 2S LiPo) |
| LTE | Orange Poland, APN: `internet` |

## Network Layout

```
Internet
    │
    │  LTE (Cat-1)
    │
[A7670E modem] ── USB ── [Raspberry Pi 5 — garage]
                              │                  │
                           usb0               eth0
                       192.168.0.x       192.168.10.1/24
                      (modem DHCP)      (DHCP for LAN clients)
```

Twingate tunnels management traffic through `usb0` for remote SSH access.

---

## Quick Start

### Fresh Pi

```bash
# On the Pi — installs Ansible, collections, then runs the full playbook
cp secrets.yml.example secrets.yml
# edit secrets.yml
sudo bash bootstrap.sh
```

### Re-run / Update

```bash
# Full playbook
ansible-playbook pi-router.yml -e @secrets.yml

# Single role
ansible-playbook pi-router.yml -e @secrets.yml --tags waveshare_ups
ansible-playbook pi-router.yml -e @secrets.yml --tags modem
ansible-playbook pi-router.yml -e @secrets.yml --tags connector
ansible-playbook pi-router.yml -e @secrets.yml --tags speedtest

# Dry-run
ansible-playbook pi-router.yml -e @secrets.yml --check
```

### Secrets

Copy `secrets.yml.example` → `secrets.yml` and fill in:

| Key | Description |
|---|---|
| `slack_webhook_url` | Incoming webhook URL |
| `twingate_network` | Twingate network name |
| `twingate_access_token` | Connector access token |
| `twingate_refresh_token` | Connector refresh token |

---

## Roles

### `slack_notify`
Installs `/usr/local/lib/slack_notify.py` and `/etc/slack.env` (webhook URL).
All notifications follow the format: `[YYYY-MM-DD HH:MM] garage <event> — <details>`

### `waveshare_ups`
Monitors the UPS HAT via a systemd timer every 30 seconds.

**Slack notifications:**
- `garage up — 7.80V charging` / `garage up — 29.5% (7.14V) battery`
- `garage AC off — 29.5% (7.14V) battery`
- `garage AC on — 7.80V charging`
- `garage battery 29.5% (7.14V)` (at 50%, 25%, 10%)
- `garage shutdown — 8.0% (6.19V) battery`

**Auto-shutdown and auto-boot:**
- Battery critical (≤25%) → Slack alert → `systemctl halt`
- UPS HAT keeps 5V on GPIO → Pi reboots immediately after halt
- `ups-boot-check.service` runs early in boot — re-halts if AC still absent, allows full boot if AC restored

**Useful commands:**
```bash
battery                  # show current voltage / current / SoC
sudo python3 /usr/local/lib/ups_monitor.py --status
journalctl -u ups-monitor -n 20 --no-pager
journalctl -u ups-boot-check -n 10 --no-pager
```

### `modem`
Switches the A7670E to RNDIS mode (USB ethernet), persists it via udev, configures NetworkManager.

**Important:** ModemManager is intentionally blocked (`ID_MM_DEVICE_IGNORE=1`). Never use `mmcli` — always write AT commands directly to `/dev/ttyUSB1`.

**Useful commands:**
```bash
gsm                      # live GSM signal TUI (RSSI, dBm, band, operator)
ip addr show usb0        # verify LTE interface has IP
nmcli connection show    # verify usb0-lte connection
```

### `twingate_connector`
Installs the Twingate connector via apt, tunnels through `usb0`. A loopback alias (`192.168.10.1/32` on `lo`) allows Twingate to proxy SSH to the Pi itself.

```bash
systemctl status twingate-connector
journalctl -u twingate-connector -n 20 --no-pager
```

### `docker`
Installs Docker CE via the official apt repository.

### `speedtest`
Runs Ookla speedtest via Docker on a schedule. Results logged to `/var/lib/speedtest/results.jsonl`. Daily Slack report at 08:00:

```
[2026-03-24 08:00] garage speedtest — 6 readings
Download  min 12.3 / avg 15.1 / max 18.4 Mbps
Upload    min 4.1 / avg 5.2 / max 6.3 Mbps
Ping      min 28.0 / avg 35.4 / max 52.1 ms
```

```bash
speed    # run a test immediately, print Download/Upload
```

### `router`
Configures eth0 as LAN gateway (static `192.168.10.1/24`), dnsmasq DHCP, nftables NAT.
**Run only after Twingate SSH is confirmed working** — switching eth0 to router mode loses direct ethernet SSH.

```bash
ansible-playbook pi-router.yml -e @secrets.yml --tags router
```

---

## Configuration

All defaults in `roles/*/defaults/main.yml`. Key variables:

| Variable | Default | Description |
|---|---|---|
| `ups_critical_battery_threshold` | `25` | % — triggers shutdown |
| `ups_battery_warn_thresholds` | `[50, 25, 10]` | % — Slack warnings |
| `ups_check_interval_sec` | `30` | timer interval |
| `ups_current_deadband` | `0.1` | A — below this = on battery |
| `ups_rtc_wake_interval_sec` | `300` | RTC wake after halt |
| `modem_tty` | `/dev/ttyUSB1` | AT command port |
| `lan_ip` | `192.168.10.1` | Pi LAN gateway IP |

---

## Troubleshooting

**usb0 has no IP:**
```bash
journalctl -u NetworkManager -n 30 --no-pager
nmcli connection up usb0-lte
```

**Modem not switching to RNDIS:**
```bash
sudo stty -F /dev/ttyUSB1 115200 raw -echo
sudo bash -c 'printf "AT+DIALMODE=0\r" > /dev/ttyUSB1'
```

**Pi not booting after critical shutdown:**
Check if `ups-boot-check.service` is halting due to stale test threshold:
```bash
grep CRITICAL_THRESHOLD /usr/local/lib/ups_monitor.py
# Re-deploy to restore defaults:
ansible-playbook pi-router.yml -e @secrets.yml --tags waveshare_ups
```

**Twingate SSH not connecting:**
```bash
ip addr show lo          # must show 192.168.10.1/32
systemctl status loopback-alias
journalctl -u twingate-connector -n 30 --no-pager
```

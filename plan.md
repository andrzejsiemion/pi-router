# Raspberry Pi 5 LTE Internet Sharing — Implementation Reference

## Status: Implemented and Running

All roles are deployed on `garage` (Raspberry Pi 5, Debian 13 Trixie, user `newton`).

---

## Repository Structure

```
/code/
├── pi-router.yml
├── bootstrap.sh
├── secrets.yml.example
├── ansible.cfg
├── inventory/
│   └── hosts.ini
└── roles/
    ├── slack_notify/
    ├── waveshare_ups/
    ├── modem/
    ├── twingate_connector/
    ├── docker/
    ├── speedtest/
    └── router/
```

**`pi-router.yml` role order:**
```yaml
roles:
  - { role: slack_notify,        tags: [slack_notify] }
  - { role: waveshare_ups,       tags: [waveshare_ups] }
  - { role: modem,               tags: [modem] }
  - { role: twingate_connector,  tags: [connector] }
  - { role: docker,              tags: [docker] }
  - { role: speedtest,           tags: [speedtest] }
```

---

## Role Details

### `slack_notify`

- Script: `/usr/local/lib/slack_notify.py` — reads `SLACK_WEBHOOK_URL` from `/etc/slack.env`, posts `sys.argv[1]` as `{"text": ...}`
- All Slack messages follow the format: `[YYYY-MM-DD HH:MM] garage <event> — <details>`

---

### `waveshare_ups`

**INA219 configuration** (matches Waveshare reference `UPS_HAT/INA219.py`):
- I2C bus 1, address `0x42`
- Config register: `0x0EEF` (16V range, gain /2 = 80mV, 12-bit 32-sample)
- Calibration: `26868` (for 0.01 Ω shunt)
- Current LSB: `0.1524 mA/bit`
- Bus voltage LSB: `4 mV/bit` (raw >> 3)

**Key variables** (`roles/waveshare_ups/defaults/main.yml`):
- `ups_critical_battery_threshold: 25` — triggers shutdown
- `ups_current_deadband: 0.1` — amps; negative below this = on battery
- `ups_battery_confirm_count: 2` — consecutive readings before alerting
- `ups_check_interval_sec: 30`
- `ups_rtc_wake_interval_sec: 300`

**SoC formula:** `(voltage - 6.0) / (8.4 - 6.0) * 100` — valid only when discharging (on battery). Shows `--` while charging.

**Script** (`/usr/local/lib/ups_monitor.py`) modes:
- Default: check loop — reads INA219, sends alerts, triggers shutdown
- `--status`: prints voltage/current/SoC to stdout, no side effects
- `--startup`: sends device-up notification once
- `--boot-check`: early-boot guard (see below)

**Systemd units:**
- `ups-monitor.timer` + `ups-monitor.service` — runs every 30s
- `ups-boot-check.service` — runs at `basic.target`, re-halts if AC not restored

**Auto-boot after AC restore:**
- UPS HAT powers Pi via GPIO 5V continuously — Pi reboots immediately after `systemctl halt`
- `shutdown()` writes RTC wake alarm (`+300s`) then calls `systemctl halt`
- `POWER_OFF_ON_HALT=0` set in EEPROM (keeps PMIC in low-power mode on halt)
- `ups-boot-check.service` runs before `basic.target` — if still on battery + critical: halts again; if AC present: allows full boot

**Slack notifications:**
- `[ts] garage up — 7.80V charging`
- `[ts] garage up — 29.5% (7.14V) battery`
- `[ts] garage AC off — 29.5% (7.14V) battery`
- `[ts] garage AC on — 7.80V charging`
- `[ts] garage battery 29.5% (7.14V)`
- `[ts] garage shutdown — 8.0% (6.19V) battery`

**Utility commands:**
- `battery` — runs `ups_monitor.py --status`

---

### `modem`

**Key facts:**
- Modem operates in RNDIS mode (USB ethernet), NOT GSM/ppp
- ModemManager intentionally blocked via udev `ID_MM_DEVICE_IGNORE=1`
- Never use `mmcli` — use direct TTY writes to `/dev/ttyUSB1`
- NM connection type: `type=ethernet` (not `type=gsm`)

**Templates deployed:**
- `99-a7670e.rules` → `/etc/udev/rules.d/` — blocks MM, triggers init script on hotplug
- `a7670e-init.sh` → `/usr/local/sbin/` — sends `AT+DIALMODE=0` + `AT$MYCONFIG="usbnetmode",0`
- `usb0.nmconnection` → `/etc/NetworkManager/system-connections/` (mode 0600) — `type=ethernet`, `route-metric=50`
- `modem-poweroff.service` → `/etc/systemd/system/` — sends `AT+CPOF` before shutdown (enabled, not started at deploy time)
- `gsm` → `/usr/local/bin/gsm` — curses TUI showing live RSSI, dBm, quality label, best/worst tracker

---

### `twingate_connector`

- Installed via apt (`packages.twingate.com/apt/`, package `twingate-connector`)
- Conf: `/etc/twingate/connector.conf`
- `loopback-alias.service` — adds `192.168.10.1/32` to `lo` so Twingate can proxy to the Pi itself
- Resource in Twingate admin: `192.168.10.1`, remote network `kolejowa`, connector `kolejowa-garage`

---

### `docker`

- Installs Docker CE via official apt repo

---

### `speedtest`

- Runs Ookla speedtest via Docker (`gists/speedtest-cli`)
- `speed` command: runs test, prints only Download/Upload lines
- Results logged as JSONL to `/var/lib/speedtest/results.jsonl`
- Daily report sent to Slack at 08:00: `[ts] garage speedtest — N readings` + min/avg/max per metric

---

### `router` (NOT deployed)

Waiting for operator confirmation that Twingate SSH is stable before running `--tags router`.

When deployed, will:
- Set eth0 static `192.168.10.1/24`
- Deploy dnsmasq for DHCP on eth0 (`192.168.10.100-200`)
- Configure nftables NAT/masquerade (eth0 → usb0)
- Enable `net.ipv4.ip_forward`

---

## Key Architectural Decisions

| Decision | Rationale |
|---|---|
| RNDIS mode, `type=ethernet` in NM | Modem presents as USB ethernet in RNDIS mode, not serial/GSM |
| Direct TTY (never mmcli) | ModemManager blocked by udev; mmcli resets modem settings |
| NM keyfiles over `nmcli con add` | Idempotent — no duplicate connections on re-runs |
| Systemd timer for UPS (not daemon) | Clean environment per run; auto-retries on crash |
| `ansible.builtin.fail` on I2C reboot | `reboot` module would kill the localhost Ansible session |
| Twingate via apt (not binary download) | Official package, maintained updates |
| `ups-boot-check.service` at basic.target | HAT keeps 5V on GPIO so Pi reboots immediately after halt; boot-check re-halts until AC restored |
| `systemctl halt` not `poweroff` | `POWER_OFF_ON_HALT=0` only affects halt — keeps PMIC in low-power mode, RTC ticking |

---

## Pre-Router Verification Checklist

Before `--tags router` is ever run:
- [ ] `ip addr show usb0` shows `192.168.0.x`
- [ ] `ping -c 3 8.8.8.8 -I usb0` succeeds
- [ ] `systemctl is-active twingate-connector` → `active`
- [ ] SSH from external machine through Twingate works reliably
- [ ] `systemctl is-active ups-monitor.timer` → `active`
- [ ] `battery` shows expected voltage/current
- [ ] `gsm` TUI displays signal strength

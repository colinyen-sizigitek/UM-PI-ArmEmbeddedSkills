# MX3 device diagnostics on TX8

Run these before writing runtime code, after any driver/runtime update, and whenever the
accelerator misbehaves. All commands are read-only unless stated. `scripts/mx3_diag.sh` runs
the whole list and prints one report:
```bash
ssh umpi 'bash -s' < scripts/mx3_diag.sh | tee diag_$(date +%Y%m%d_%H%M).txt
```
Some commands need `sudo` (e.g. full `lspci -vv` capability output). The script uses
`sudo -n` (non-interactive) and reports "needs sudo" instead of prompting.

## 1. Packages and versions
```bash
ssh umpi 'apt policy memx-drivers memx-accl 2>/dev/null'
ssh umpi 'dpkg -l | grep -i memx'
ssh umpi 'dpkg -L memx-accl | grep -E "\.h$|\.so|cmake|pkgconfig" | head -50'
ssh umpi 'cat /sys/memx0/verinfo'
```
- `memx-drivers` = kernel module + firmware; `memx-accl` = C++ runtime (`libmx_accl`), tools
  (`acclBench`) and mxa-manager. Record both versions with every measurement.
- `/sys/memx0/verinfo`: driver/firmware version info as exposed by the driver (format not
  documented — store it verbatim).
- The CMake package / target name of the runtime is **not documented**: read
  `dpkg -L memx-accl` output (look for `*Config.cmake` or `.pc` files) before writing
  `find_package`/link lines. Headers live under `/usr/include/memx/accl/` (`MxAccl.h`,
  `MxAcclBase.h`, `MxAcclMT.h`, `utils/mxTypes.h`, `utils/featureMap.h`).
- Python runtime (`memryx` pip package) may or may not be installed on the board; it is only
  for prototypes/tests.

## 2. Device nodes and kernel
```bash
ssh umpi 'ls -l /dev/memx* ; ls /sys/memx0/'
ssh umpi 'lsmod | grep -i memx; dmesg | grep -i memx | tail -50'
ssh umpi 'acclBench --hello 2>/dev/null || mx_bench --hello'
```
- Expect `/dev/memx0` (one logical device for the 4 chained chips = group 0).
- `--hello` prints group, number of chips (expect 4), interface (PCIe 3.0) and device map.
  `acclBench` (C++ tool from `memx-accl`) uses `--hello`/`-H`; `mx_bench` (Python SDK tool)
  uses `--hello` in its examples (the flag table spells `-hello`). Use whichever is installed.

## 3. Temperature
```bash
ssh umpi 'cat /sys/memx0/temperature'
ssh umpi 'for i in $(seq 10); do cat /sys/memx0/temperature; sleep 1; done'
```
- MemryX's troubleshooting page uses `watch cat /sys/memx0/temperature` to monitor temperature
  and throttling. The exact text format is not documented — parse numbers defensively and
  store raw text in reports.
- Each MX3 must stay **below 100 deg C**; above that it throttles (frequency halved per MemryX).
- A chip reporting **255 deg C** is in a lock-up state: only a reboot clears the PCIe bus.
- Module operating range -40..+85 deg C (ambient/module spec; verify the TX8 enclosure airflow).

## 4. PCIe link (x2 vs x4)
```bash
ssh umpi 'lspci -nn | grep -i -E "memryx|1fe9|processing accelerator"'
ssh umpi 'sudo -n lspci -vv -s <BDF> | grep -E "LnkCap|LnkSta|LnkCtl2"'
```
- The MemryX M.2 module datasheet/FAQ states **PCIe Gen3 x2**; the TX8 slot is Gen3 x4. The
  negotiated link is what matters: `LnkSta: Speed 8GT/s, Width x2` is the expected healthy state;
  `Speed 5GT/s` or `2.5GT/s` = downgraded (signal integrity, slot config) -> report as a HW issue.
- Vendor ID: find the device by name or class in `lspci -nn` output; do not assume an ID.
- MemryX ships `mx_arm_setup` for Raspberry Pi 5 to force Gen3; it changes system configuration
  and is **not** for TX8 without the product owner's approval.

## 5. mxa-manager (shared mode service)
```bash
ssh umpi 'systemctl status mxa-manager --no-pager | head -20'
ssh umpi 'cat /etc/memryx/mxa_manager.conf'
ssh umpi 'ls -l /run/mxa_manager/ 2>/dev/null'
ssh umpi 'journalctl -u mxa-manager --no-pager -n 50'
```
- Service name `mxa-manager`; config `/etc/memryx/mxa_manager.conf` (`LISTEN_ADDRESS` default
  `/run/mxa_manager/` UNIX sockets, `BASE_PORT` default 10000, sockets `1000{0,1,2}.sock`).
- Debug logging needs `systemctl edit mxa-manager` (adds `SPDLOG_LEVEL=debug`) and a restart —
  a system change: ask first.
- Shared mode is the runtime default. Local mode (`local_mode=true`) bypasses the manager
  (single process, single DFP). See `multi-chip.md`.

## 6. Clock / power mode configuration
```bash
ssh umpi 'ls -l /etc/memryx/; cat /etc/memryx/power.conf 2>/dev/null'
```
- `MxFrequencyOption::FREQ_USE_CONF` means "use the current `/etc/memryx/power.conf`" (runtime
  header). `sudo mx_set_powermode` is an **interactive** tool that edits the power mode for 4-chip
  and 2-chip DFPs (200-850 MHz). ARM default = 500 MHz.
- Do not run `mx_set_powermode` without approval; our application sets the clock per session via
  `set_operating_frequency()` instead (see `cpp-api-usage.md`).

## 7. Quick throughput sanity check
```bash
ssh umpi 'acclBench -d ~/models/<name>/current/<name>_c4.dfp -f 1000 --set_freq 300'
ssh umpi 'mx_bench -v -d ~/models/<name>/current/<name>_c4.dfp -f 1000'
```
- `acclBench` flags (from the MxAccl source, verify with `acclBench --help` on the board): `-d` DFP,
  `-f` frames (default 1000), `-n` streams, `-s` shared mode (default local), `--device_ids`,
  `--set_freq <MHz>`, `--power`, `-b` (no live table), `--mt` (manual threading), `-c` convert threads.
- `mx_bench` flags (docs): `-d` DFP, `-f` frames (default 100; MemryX recommends >= 500), `-v`,
  `--hello`. No clock option: it runs at the configured power mode. Prefer `acclBench --set_freq`.
- Changing the clock is a power setting change: ask before running `--set_freq`.
- FPS/latency include host driver and interface time. Random input; real pipeline fps will be lower.

## 8. CPU and board context (for every report)
```bash
ssh umpi 'uname -a; cat /etc/os-release | head -3; nproc; free -m'
ssh umpi 'grep -E "CPU (part|revision)" /proc/cpuinfo | sort | uniq -c'
ssh umpi 'cat /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp 2>/dev/null'
ssh umpi 'ls /sys/class/hwmon/ && cat /sys/class/hwmon/hwmon*/name 2>/dev/null'
```
- RAM: EVT 2 GB / MP 4 GB — detect, never assume.
- SoC thermal zones and any hwmon power sensors (INA2xx etc.) are board-specific — the UM-PI
  manual is not available; record what exists.

## Interpreting the report
| Symptom | Likely cause | Action |
|---|---|---|
| No `/dev/memx0` | driver not loaded, module not detected | `dmesg`, `lspci`; check M.2 seating/power; escalate HW |
| `--hello` shows fewer than 4 chips | module/firmware issue | report; do not run 4-chip DFPs |
| Link Gen1/Gen2 or x1 | signal integrity / slot config | HW issue; measure impact with acclBench |
| Temperature 255 | chip lock-up | reboot board; log as FAULT; check cooling |
| Idle temperature > 70 deg C | poor airflow / heatsink | fix cooling before stability tests |
| mxa-manager failed | service crash/config | collect journal; local mode works without it |

# TX8 board facts, unknowns and how to probe them

This file lists what is known about the TX8 SOM (UM-PI platform) from the vendor documents,
what is **not** known, and the exact command that confirms each fact on a real board. All board
commands are written as `ssh umpi '<cmd>'`; `scripts/board_probe.sh` runs all of them at once.

Rule: a fact is usable in code or advice only if it is (a) in the "documented" column and does
not vary per board, or (b) probed on the board in this session. Everything else is
"verify on TX8".

## 1. Fact table

| Item | Documented value | Varies / unknown | Probe |
|---|---|---|---|
| SoC | Unimap UM21A646 (datasheet UM2xA646-DS Rev.3, die "TX5") | — | `ssh umpi 'cat /proc/device-tree/model; cat /proc/device-tree/compatible \| tr "\0" " "'` |
| CPU | 4x Cortex-A53, AArch64, up to 1200 MHz (600 MHz low-speed) | actual max freq set by BSP | `ssh umpi 'lscpu; nproc'` |
| ISA features | Armv8.0-A, NEON (asimd), CRC32, crypto in HW | — | `ssh umpi 'grep -m1 Features /proc/cpuinfo'` (expect `fp asimd ... aes pmull sha1 sha2 crc32`, **no** `atomics`, `asimddp`, `fphp`, `sve`) |
| CPU revision | not documented | **unknown, probe** | `ssh umpi 'grep -E "CPU (implementer\|part\|variant\|revision)" /proc/cpuinfo \| sort -u'` |
| L1 / L2 cache | 32 KB I + 32 KB D per core; shared L2 1 MB; no L3; line 64 B | — | `ssh umpi 'lscpu -C 2>/dev/null \|\| ls /sys/devices/system/cpu/cpu0/cache/'`, `getconf LEVEL1_DCACHE_LINESIZE` |
| DRAM | DDR4-2400 32-bit; **EVT 2 GB, MP 4 GB** | **per board** | `ssh umpi 'free -h; grep MemTotal /proc/meminfo'` |
| Storage | 8 GB eMMC + microSD | partition layout, free space | `ssh umpi 'lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE; df -h /'` |
| PCIe | Gen3 x4 RC (Synopsys DWC), M.2 M-key | **negotiated width/speed** (module datasheet says x2) | `ssh umpi 'sudo lspci -vv \| grep -E "^[0-9a-f]\|LnkCap:\|LnkSta:"'` |
| USB | USB 3.2 Gen1 x1, USB 2.0 x2 | which port the camera is on | `ssh umpi 'lsusb; lsusb -t'` |
| Cameras | USB UVC, MJPEG (no MIPI CSI, no ISP) | device nodes, formats | `ssh umpi 'v4l2-ctl --list-devices; v4l2-ctl -d /dev/video0 --list-formats-ext'` |
| Video/JPEG HW | none (no NPU, no HW codec) | — | nothing to probe; JPEG decode is CPU |
| OS | Ubuntu 22.04, Linux 5.15 | exact kernel build, BSP | `ssh umpi 'uname -a; cat /etc/os-release'` |
| Toolchain | GCC 11, glibc 2.35 | patch versions, default fix flags | `ssh umpi 'gcc --version; g++ --version; ldd --version \| head -1; cmake --version'` |
| MemryX packages | `memx-drivers` + `memx-accl` installed | versions | `ssh umpi 'dpkg -l \| grep -E "memx\|turbojpeg\|libjpeg"; apt policy memx-drivers'` |
| MemryX device | Cascade 100M (4x MX3), `/sys/memx0` | firmware/driver version, chip count seen | `ssh umpi 'cat /sys/memx0/verinfo; cat /sys/memx0/temperature'` |
| CPU frequency policy | not documented | governor, min/max | `ssh umpi 'cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_{min,max,cur}_freq'` |
| Thermal | not documented (no operating temperature in `Spec/`) | zones, trip points | `ssh umpi 'for z in /sys/class/thermal/thermal_zone*; do echo $z $(cat $z/type) $(cat $z/temp); done'` |
| SoC power | not documented | **unknown** | no software probe; measure at the supply if needed |
| PMU | Cortex-A53 PMU (6 counters) | whether exposed by the kernel | `ssh umpi 'dmesg 2>/dev/null \| grep -i pmu; cat /proc/sys/kernel/perf_event_paranoid'` |
| Network | GbE x2 | interface names, addresses | `ssh umpi 'ip -br addr'` |

Unknown in the vendor documents (never invent values; write "verify on TX8" or ask the hardware
team): UM-PI user manual, BSP/toolchain details, operating temperature range, SoC power,
whether the carrier can switch M.2 slot power by GPIO.

## 2. CPU revision and Cortex-A53 errata flags

The MIDR fields appear in `/proc/cpuinfo`:

```
CPU implementer : 0x41      # Arm
CPU architecture: 8
CPU variant     : 0x0       # the "r" in rNpM
CPU part        : 0xd03     # Cortex-A53
CPU revision    : 4         # the "p" in rNpM  -> r0p4
```

Two A53 errata have compiler/linker workarounds:

| Erratum | Problem class | Workaround flag |
|---|---|---|
| 835769 | 64-bit multiply-accumulate after a load/store may give a wrong result | `-mfix-cortex-a53-835769` (compiler inserts a NOP) |
| 843419 | ADRP-based address may be wrong at certain page offsets | `-mfix-cortex-a53-843419` (passed to the linker as `--fix-cortex-a53-843419`) |

Decision procedure:
1. Read `CPU variant` and `CPU revision` on the board (all four cores should match).
2. Look the revision up in the Arm *Cortex-A53 Software Developers Errata Notice* (SDEN) on
   developer.arm.com. The Linux kernel Kconfig help for `ARM64_ERRATUM_835769` /
   `ARM64_ERRATUM_843419` lists affected parts as revisions up to r0p4; confirm with the SDEN.
3. Check what the native compiler already does by default (Ubuntu GCC may be configured with
   these fixes enabled):
   ```
   ssh umpi 'gcc -Q --help=target | grep -i fix-cortex'
   ssh umpi 'gcc -v 2>&1 | tr " " "\n" | grep -i fix-cortex'
   ```
4. If the revision is affected, or the revision cannot be determined, enable both flags
   (`TX8_A53_ERRATA=ON` in `TX8Flags.cmake`). The cost is small (a few NOPs / veneers).
   Record the decision and the probed revision in the project README.
5. Cross-compiling: the cross GCC defaults may differ from the board's; set the flags explicitly.

## 3. Memory and storage facts that affect code

- Always read RAM size at runtime (`sysconf(_SC_PHYS_PAGES) * sysconf(_SC_PAGESIZE)` or
  `/proc/meminfo`) and size buffer pools from it; EVT boards have 2 GB.
- `nproc` is 4; leave one core for the system and the camera/USB stack unless measured otherwise.
- eMMC is 8 GB: keep logs in journald with a size cap, do not write per-frame files in production.
- Check free space before deploying large DFPs: `ssh umpi 'df -h / /opt'`.

## 4. PCIe link

MemryX lists the Cascade 100M as PCIe Gen3 x2; the TX8 slot is x4. Read both lines for the MemryX
device (vendor-specific; find it by `lspci -nn`):

```
LnkCap: Port #0, Speed 8GT/s, Width x2 ...     # what the device can do
LnkSta: Speed 8GT/s, Width x2 ...              # what was negotiated
```

Report `LnkSta` speed and width. If speed is below 8GT/s or width below the device `LnkCap`,
flag it (seating, power, BSP settings) before any performance work. `lspci -vv` needs root for
capability fields: use `sudo -n` and ask the user if a password would be needed.

## 5. Cameras

```
ssh umpi 'v4l2-ctl --list-devices'
ssh umpi 'v4l2-ctl -d /dev/video0 --list-formats-ext'   # expect MJPG 1920x1080@30 and 640x640@30
ssh umpi 'lsusb -t'                                       # 5000M = USB3, 480M = USB2
```

A UVC camera usually exposes two `/dev/video*` nodes per stream (capture + metadata). Use stable
paths from `/dev/v4l/by-id/` or `/dev/v4l/by-path/` in configuration, not `/dev/video0`.
Two MJPEG streams (1080p30 + 640x640@30) on one USB 2.0 port may exceed bandwidth; check `lsusb -t`.

## 6. Thermal and frequency

- Governor and frequencies affect every measurement. Record them in every benchmark report.
  Do not change the governor without user approval; if a test needs `performance`, ask, and
  restore afterwards.
- Thermal zone names and trip points are BSP-specific; list them with the probe loop in §1
  plus `cat $z/trip_point_*_temp`. MX3 temperature: `/sys/memx0/temperature` or the runtime API
  (see skill `mx3-runtime-integration`).

## 7. Software stack versions

```
ssh umpi 'dpkg -l | grep -E "memx|turbojpeg|libjpeg"'
ssh umpi 'dpkg -L memx-accl | grep -E "\.so|cmake|\.pc|include" | head -50'
ssh umpi 'cat /sys/memx0/verinfo'
```

Use the output to: pin the documented SDK version in the README, find the real library and CMake
config names (the CMake target name is not documented by MemryX), and check that
`libturbojpeg0-dev` (TurboJPEG API headers) is present before writing decode code.

## 8. Recording facts

Save the probe output as `docs/board-report-<hostname>-<date>.md` in the application project
(ask before writing into the repo). Quote the relevant lines when you rely on a fact.

Sources: UM2xA646-DS Rev.3 (Unimap), UM-PI Product Introduction, MemryX developer docs
(https://developer.memryx.com/), Arm Cortex-A53 TRM DDI0500 and SDEN (developer.arm.com).

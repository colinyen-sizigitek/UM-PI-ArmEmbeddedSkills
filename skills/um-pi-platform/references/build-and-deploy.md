# Build, deploy and run on the TX8

Default build path: **native build on the board over SSH** (same GCC 11 / glibc 2.35 as the
runtime, no ABI mismatch). Optional: cross-compile in WSL2 Ubuntu 22.04 with
`aarch64-linux-gnu-g++-11` and a sysroot copied from the board.

Assets in this skill (copy into the application repo, then adapt):
- `assets/cmake/TX8Flags.cmake` — `tx8_apply_flags(<target>)`, `tx8_hot_file(<files...>)`
- `assets/cmake/tx8-toolchain-aarch64.cmake` — cross toolchain file
- `assets/systemd/tx8-app.service` — service template

## 1. Project skeleton

```
myapp/
  CMakeLists.txt
  CMakePresets.json
  cmake/TX8Flags.cmake
  cmake/tx8-toolchain-aarch64.cmake
  src/main.cpp
  src/postproc_neon.cpp        # hot file -> -O3
  config/myapp.conf
  systemd/myapp.service
  tests/
```

```cmake
cmake_minimum_required(VERSION 3.16)
project(myapp VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)       # for clang-tidy
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
include(TX8Flags)

find_package(Threads REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(TURBOJPEG REQUIRED IMPORTED_TARGET libturbojpeg)

add_executable(myapp src/main.cpp src/postproc_neon.cpp)
tx8_apply_flags(myapp)
tx8_hot_file(src/postproc_neon.cpp)
target_link_libraries(myapp PRIVATE Threads::Threads PkgConfig::TURBOJPEG)
# MemryX runtime: see section 5 -- discover the real names first.

install(TARGETS myapp RUNTIME DESTINATION bin)
```

## 2. Flags (DESIGN §3.3)

| Scope | Flags |
|---|---|
| Global (all TUs) | `-O2 -mcpu=cortex-a53 -mno-outline-atomics -Wall -Wextra -Werror` |
| Hot files only | `-O3 -fopt-info-vec-missed` (vectorization report to stderr) |
| Crypto (only if AES/SHA used) | `-mcpu=cortex-a53+crypto` (option `TX8_ENABLE_CRYPTO`) |
| Errata | `-mfix-cortex-a53-835769 -mfix-cortex-a53-843419` after checking CPU revision (option `TX8_A53_ERRATA`, see `board-facts.md` §2) |
| Tests | `-fsanitize=address,undefined -fno-omit-frame-pointer -O1 -g` (option `TX8_SANITIZE`; never in release) |

Notes:
- `-mno-outline-atomics`: A53 has no LSE; outline atomics add a runtime dispatch per atomic.
- `-Werror` applies to your targets only; do not apply it to third-party subprojects.
- Do not add `-march=armv8.2-a`, `+dotprod`, `+fp16`, `-ffast-math` globally. Fine tuning of
  hot loops belongs to skill `um-pi-cpp-performance`.

## 3. Presets

```json
{
  "version": 3,
  "configurePresets": [
    { "name": "release", "binaryDir": "build/release",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Release" } },
    { "name": "debug", "binaryDir": "build/debug",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Debug" } },
    { "name": "asan", "binaryDir": "build/asan",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Debug", "TX8_SANITIZE": "ON" } },
    { "name": "cross-release", "binaryDir": "build/cross-release",
      "toolchainFile": "${sourceDir}/cmake/tx8-toolchain-aarch64.cmake",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Release" } }
  ],
  "buildPresets": [
    { "name": "release", "configurePreset": "release", "jobs": 4 },
    { "name": "debug",   "configurePreset": "debug",   "jobs": 4 },
    { "name": "asan",    "configurePreset": "asan",    "jobs": 4 }
  ]
}
```

Presets version 3 needs CMake ≥ 3.21. If the board has 3.22 (Ubuntu 22.04 default) this works;
otherwise use plain `-D` options as shown below.

## 4. Native build on the board (default)

```bash
# from WSL / Linux / Git Bash on the dev host
rsync -az --delete --exclude build/ --exclude .git/ ./ umpi:~/src/myapp/
ssh umpi 'cd ~/src/myapp && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j4'
```

`scripts/deploy.sh --name myapp --src .` does the same with an scp/tar fallback when rsync is
missing. A 4x A53 with 2 GB RAM can run out of memory with `-j4` on heavy template code; use
`-j2` if the compiler is OOM-killed (`dmesg | grep -i oom`).

Run tests on the board: `ssh umpi 'cd ~/src/myapp && ctest --test-dir build --output-on-failure'`.

## 5. Linking libturbojpeg and the MemryX runtime

TurboJPEG (Ubuntu 22.04 package `libturbojpeg0-dev`, pkg-config name `libturbojpeg`):

```bash
ssh umpi 'dpkg -l | grep -E "turbojpeg|libjpeg"; pkg-config --modversion libturbojpeg'
```

MemryX runtime: the CMake package/target name is **not documented**. Discover it before writing
any `find_package` or link line:

```bash
ssh umpi 'dpkg -L memx-accl | grep -E "cmake|\.pc$|\.so"'
ssh umpi 'ls /usr/include/memx/accl/ 2>/dev/null'
```

Then, depending on what exists:
- A `*Config.cmake` file → `find_package(<Name> REQUIRED)` and read the file for the exported target.
- A `.pc` file → `pkg_check_modules(MEMX REQUIRED IMPORTED_TARGET <name>)`.
- Only a `.so` → `find_library(MEMX_ACCL_LIB NAMES <basename-without-lib-prefix>)` and
  `find_path(MEMX_INC memx/accl/MxAccl.h)`.

Copy the discovered names into the project README. Reference the official examples
(https://github.com/memryx/MemryX_eXamples) for how MemryX links its own C++ samples. Runtime
usage itself is covered by skill `um-pi-mx3-runtime-integration`.

## 6. Cross-compile in WSL2 (optional)

1. Install (engineer, in WSL Ubuntu 22.04): `sudo apt install g++-11-aarch64-linux-gnu`.
2. Pull a sysroot from the board (contains glibc 2.35, MemryX and TurboJPEG):
   ```bash
   export TX8_SYSROOT=$HOME/tx8-sysroot
   mkdir -p "$TX8_SYSROOT"
   rsync -az --relative umpi:/usr/include umpi:/usr/lib/aarch64-linux-gnu umpi:/lib/aarch64-linux-gnu "$TX8_SYSROOT"/
   rsync -az --relative umpi:/usr/lib/pkgconfig umpi:/usr/share/pkgconfig "$TX8_SYSROOT"/ 2>/dev/null || true
   ```
   Also copy any MemryX paths reported by `dpkg -L memx-accl` that are outside these trees.
   On Ubuntu 22.04 `/lib` is a symlink to `/usr/lib`; rsync may copy symlinks with absolute
   targets — fix them with `symlinks -rc "$TX8_SYSROOT"` or re-run rsync with `--copy-unsafe-links`.
3. Configure: `cmake -S . -B build/cross -DCMAKE_TOOLCHAIN_FILE=cmake/tx8-toolchain-aarch64.cmake -DCMAKE_BUILD_TYPE=Release`
4. Copy only the binary: `scp build/cross/myapp umpi:/tmp/` and test on the board.

Caveats: refresh the sysroot after any `apt upgrade` on the board; a binary linked against a
newer host glibc fails on the board with `GLIBC_2.xx not found` (check with
`aarch64-linux-gnu-objdump -T myapp | grep GLIBC_ | sort -u`). Never use Arm GNU Toolchain 13–15.

## 7. Deploy layout

| Path | Content |
|---|---|
| `/opt/<app>/bin/<app>` | binary |
| `/opt/<app>/models/*.dfp` | compiled models |
| `/etc/<app>/<app>.conf` | configuration (chip count, model, transport) |
| journald (`journalctl -u <app>`) | logs; optional `/var/log/<app>/` only for explicit dump files |

Install commands (require sudo; ask first):

```bash
ssh umpi 'sudo install -D -m 0755 ~/src/myapp/build/myapp /opt/myapp/bin/myapp'
ssh umpi 'sudo install -D -m 0644 ~/src/myapp/config/myapp.conf /etc/myapp/myapp.conf'
```

Cap journald size if not already: `SystemMaxUse=200M` in `/etc/systemd/journald.conf`
(system config change → ask the user).

## 8. systemd service

Template: `assets/systemd/tx8-app.service`. Key choices:

- `Type=simple` (or `Type=notify` if the app calls `sd_notify`), `Restart=on-failure`,
  `RestartSec=2`, `StartLimitIntervalSec=60`, `StartLimitBurst=5`.
- `TimeoutStartSec=10`, `TimeoutStopSec=10`: the app must release `MxAccl` and stop camera
  capture on SIGTERM within that time.
- `After=network-online.target mxa-manager.service` and `Wants=mxa-manager.service` when using
  the shared-mode manager (check that the unit exists: `systemctl list-unit-files | grep mxa`).
- `LimitRTPRIO=` only if you use `SCHED_FIFO` threads; prefer normal priorities until measured.
- `CPUAffinity=` restricts all threads; usually better to pin specific threads in code with
  `pthread_setaffinity_np`. Leave CPU 0 for IRQs/USB unless measured otherwise.
- Logging: `StandardOutput=journal`, `SyslogIdentifier=<app>`. Log rate-limited, not per frame.
- Run as a dedicated user in groups `video` (cameras) and whatever group owns `/dev/memx*`
  (check `ls -l /dev/memx*`); fall back to root only with the user's approval.

Install and start (ask first; `deploy.sh --install --yes` does this):

```bash
scp systemd/myapp.service umpi:/tmp/
ssh umpi 'sudo install -m 0644 /tmp/myapp.service /etc/systemd/system/myapp.service && sudo systemctl daemon-reload'
ssh umpi 'sudo systemctl enable --now myapp && systemctl status myapp --no-pager'
ssh umpi 'journalctl -u myapp -n 100 --no-pager'
```

## 9. Measure after deploy

- Start time: `systemd-analyze` is not per-app; log a timestamp at process start and at first
  output and compute the delta, or `journalctl -u myapp -o short-monotonic`.
- Steady state (10 min): `ssh umpi 'top -b -d 5 -n 120 -p $(pidof myapp)'`, thermal zones,
  `/sys/memx0/temperature`.
- Restart behaviour: `ssh umpi 'sudo kill -SEGV $(pidof myapp)'` in a test session (ask first),
  then `systemctl status` shows the restart.

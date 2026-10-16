# Engineer workstation (Windows dev host) setup and checks

Engineers use their own Windows machines; the TX8 is reached over SSH. The agent **checks and
advises**. It never installs system software, edits system settings or enables Windows features
on its own. When something is missing, report it with the advice below and let the engineer run
the command (or approve it explicitly).

Run the automated check first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\host_env_check.ps1
```

Inside WSL or on a Linux host: `bash scripts/host_env_check.sh`.

## 1. Recommended configuration

| Component | Recommendation | Why |
|---|---|---|
| CPU | x86_64 with **AVX2** | `mx_nc` (MemryX Neural Compiler) requires AVX2 on x86 |
| RAM | ≥ 8 GB, **16 GB recommended** | model compilation is memory hungry |
| WSL2 + Ubuntu 22.04 | required for `mx_nc` and the optional cross toolchain | MemryX SDK runs on Linux; 22.04 matches the board's glibc 2.35 |
| Git for Windows | latest | source control, also provides Git Bash for `deploy.sh` |
| CMake | ≥ 3.16 (Windows and/or WSL) | `CMakePresets.json`, toolchain files |
| Python 3.11 (Windows) | python.org installer or `winget` | Windows base-station viewer (skill `basestation-viewer`) |
| Python in WSL | 3.9–3.12 in a venv | `pip install memryx` for `mx_nc` (skill `mx3-model-compile`) |
| OpenSSH client | Windows built-in (`ssh`, `ssh-keygen`, `scp`) | board access via `ssh umpi` |
| `aarch64-linux-gnu-g++-11` (WSL) | optional | cross-compile; native build on board is the default |
| VS Code (Remote-SSH / WSL) or other IDE | optional | editing; not required by the skills |
| Arm Performance Studio (Streamline) | optional | GUI profiling with `gatord` on the board (skill `tx8-cpp-performance`) |

## 2. Checks and advice per item

### 2.1 CPU AVX2 and RAM
- Check (PowerShell): `(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB`.
- AVX2: inside WSL `grep -o -m1 avx2 /proc/cpuinfo`. Windows has no built-in one-liner; the
  WSL check is authoritative for `mx_nc`.
- Advice if missing AVX2: compile models on another x86 machine or an ARM64 Linux host with
  ≥ 8 GB RAM. Do **not** compile models on the TX8.

### 2.2 WSL2 and Ubuntu 22.04
- Check: `wsl -l -v` (version column must be `2`), then `wsl -d Ubuntu-22.04 -e lsb_release -a`.
  Output of `wsl.exe` is UTF-16; the PowerShell script handles it.
- Advice: `wsl --install -d Ubuntu-22.04` (needs admin and a reboot; engineer runs it).
  Configure memory in `%UserProfile%\.wslconfig` if compilation runs out of RAM:
  ```ini
  [wsl2]
  memory=12GB
  swap=8GB
  ```

### 2.3 Git
- Check: `git --version`.
- Advice: install Git for Windows; set `core.autocrlf=input` for repos that contain shell
  scripts, or add `.gitattributes` with `*.sh text eol=lf`. CRLF line endings break bash scripts
  on the board (`/bin/bash^M: bad interpreter`).

### 2.4 CMake ≥ 3.16
- Check: `cmake --version` on Windows and `wsl -e cmake --version`; on the board
  `ssh umpi 'cmake --version'` (the board version is the one that matters for native builds).
- Advice: Windows installer from cmake.org or `winget install Kitware.CMake`; WSL
  `sudo apt install cmake`.

### 2.5 Python 3.11 on Windows
- Check: `py -3.11 --version`, then `python --version`.
- The Microsoft Store **app execution alias** `python.exe` under
  `%LocalAppData%\Microsoft\WindowsApps` is a stub that opens the Store and prints nothing useful;
  treat it as **MISSING**.
- Advice: install 3.11 from python.org (tick "Add to PATH") or `winget install Python.Python.3.11`;
  disable the Store alias in *Settings > Apps > Advanced app settings > App execution aliases*.

### 2.6 OpenSSH client and key
- Check: `ssh -V`, `Test-Path $HOME\.ssh\id_ed25519`.
- Advice (engineer runs):
  ```powershell
  ssh-keygen -t ed25519 -C "<you>@<machine>" -f $HOME\.ssh\id_ed25519
  # copy the public key to the board (Windows has no ssh-copy-id):
  type $HOME\.ssh\id_ed25519.pub | ssh <user>@<board-ip> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
  ```
  From WSL/Linux: `ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<board-ip>`.
  The one-time password prompt during key copy is typed by the engineer, never by the agent.

### 2.7 SSH alias `umpi`
- Check: `Select-String -Path $HOME\.ssh\config -Pattern '^\s*Host\s+.*\bumpi\b'`, then
  `ssh -o BatchMode=yes -o ConnectTimeout=5 umpi true` (exit 0 = key auth works).
- Example `%UserProfile%\.ssh\config` (and the same in WSL `~/.ssh/config`; WSL does not read
  the Windows file):
  ```
  Host umpi
      HostName <board-ip-or-hostname>
      User <board-user>
      IdentityFile ~/.ssh/id_ed25519
      IdentitiesOnly yes
      ServerAliveInterval 30
      ServerAliveCountMax 3
      ConnectTimeout 10
  ```
- In WSL copy the key with correct permissions (`chmod 600 ~/.ssh/id_ed25519`); keys on
  `/mnt/c` have wrong permissions and ssh refuses them.
- Failure triage: `ssh -v umpi true`. `Permission denied (publickey)` → key not in
  `authorized_keys`; `Connection timed out` → network/IP; `Host key verification failed` →
  board re-flashed, engineer removes the old entry with `ssh-keygen -R <host>` after confirming.

### 2.8 `mx_nc` in WSL
- Check: `wsl -e bash -lc 'mx_nc --version'` (a venv must be activated in `~/.bashrc` or use the
  full path, e.g. `~/mx/bin/mx_nc`).
- Advice (engineer runs inside WSL):
  ```bash
  python3 -m venv ~/mx && source ~/mx/bin/activate
  pip install --upgrade pip
  pip install --extra-index-url https://developer.memryx.com/pip memryx
  ```
  Match the SDK version to the board runtime (`ssh umpi 'dpkg -l | grep memx'`). Details in
  skill `mx3-model-compile`.

### 2.9 Optional cross compiler in WSL
- Check: `wsl -e bash -lc 'aarch64-linux-gnu-g++-11 --version'`.
- Advice: `sudo apt install g++-11-aarch64-linux-gnu` in Ubuntu 22.04 (GCC 11 matches the board).
  A sysroot copied from the board is still required for MemryX/TurboJPEG libraries; see
  `build-and-deploy.md` §4. Do not use Arm GNU Toolchain 13–15 for the target.

### 2.10 Optional tools
- `rsync` (WSL/Linux) speeds up deploys; `deploy.sh` falls back to `scp`/`tar`.
- Arm Performance Studio (Streamline): free download from developer.arm.com; `gatord` must be
  built/copied to the board; ask before running it as root.
- clang-format / clang-tidy for formatting and linting (any recent version on the host).

## 3. What the agent reports

A table like:

```
Item                  Status   Detail / advice
WSL2                  OK       Ubuntu-22.04 (v2)
git                   OK       2.46.0.windows.1
cmake                 MISSING  install CMake >= 3.16 (winget install Kitware.CMake)
python 3.11           MISSING  Store stub only; install from python.org
ssh alias umpi        OK
umpi reachable        FAIL     Permission denied (publickey) -> copy key (see 2.6)
mx_nc (WSL)           MISSING  pip install memryx in a WSL venv
aarch64 g++ (WSL)     SKIP     optional
```

followed by the next action the engineer should take. Never chain an install after the check.

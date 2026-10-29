# Latency accounting and metrics

How to timestamp each stage, keep allocation-free histograms, compute p50/p99, run the
10-minute soak test and report results. Without these numbers no optimization claim is valid
(measure -> optimize -> re-measure).

Definitions (DESIGN §3.1):
- **TX8-internal latency** = `t_send_done - ts_cap(CH2)`: from the CH2 V4L2 buffer timestamp
  to the DETECTIONS message handed to the socket. Target p99 <= 80 ms.
- **Start latency** = first DETECTIONS sent - start command received. Target <= 3 s.
- **Sustained rate** = 30 fps for 10 minutes (CH1 sent and inference results sent).
- **End-to-end latency** (capture -> displayed at base station) is only an estimate (clock
  offset), measured by skill `um-pi-basestation-viewer`. Monitor, no hard limit.

## 1. Per-stage timestamps

All times `CLOCK_MONOTONIC` in microseconds (`clock_gettime`, vDSO, cheap). One metadata
struct travels with each CH2 frame through the queues (no allocation — part of the pooled
buffer descriptor):

```cpp
struct FrameTimes {
  uint64_t cap;        // V4L2 buffer timestamp
  uint64_t dqbuf;      // after VIDIOC_DQBUF returned
  uint64_t dec_begin;  // T3 popped from Q2
  uint64_t dec_end;
  uint64_t pre_end;    // float buffer ready
  uint64_t mx3_in;     // set_data / send_input done
  uint64_t mx3_out;    // output available
  uint64_t post_end;   // threshold + top-K + mapping done
  uint64_t send_done;  // socket write completed (handler called)
};
```

Stage durations recorded into histograms:
| Histogram | Value |
|---|---|
| capture | `dqbuf - cap` |
| q2_wait | `dec_begin - dqbuf` |
| decode | `dec_end - dec_begin` |
| preprocess | `pre_end - dec_end` |
| q3_wait + mx3 | `mx3_out - pre_end` (split if the runtime allows) |
| postprocess | `post_end - mx3_out` |
| send | `send_done - post_end` |
| **total** | `send_done - cap` |

Also for CH1: `send_done - cap` (video latency on TX8) and frame interval (`cap[n] - cap[n-1]`)
for both channels — the interval histogram shows camera jitter and real fps.

## 2. Fixed-bucket histogram (no allocation, no locks)

- 0.25 ms buckets from 0 to 200 ms (800 buckets) + one overflow bucket; 3.2 KB per histogram.
- Single writer (the stage's thread) increments with relaxed atomics — on A53 without LSE a
  relaxed load + store by the only writer avoids an LL/SC loop.
- The metrics thread reads all buckets once per second and subtracts the previous snapshot to
  get the per-window distribution; cumulative counts give whole-run percentiles.

```cpp
template <unsigned NB = 800, unsigned BUCKET_US = 250>
class LatencyHist {
 public:
  void record(uint64_t us) {                       // writer thread only
    const uint64_t b = us / BUCKET_US;
    const unsigned i = b < NB ? static_cast<unsigned>(b) : NB;   // NB = overflow bucket
    c_[i].store(c_[i].load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    if (us > max_.load(std::memory_order_relaxed)) max_.store(us, std::memory_order_relaxed);
  }
  void snapshot(uint32_t (&out)[NB + 1]) const {    // reader thread
    for (unsigned i = 0; i <= NB; ++i) out[i] = c_[i].load(std::memory_order_relaxed);
  }
  // Percentile over a snapshot or a window difference; returns the bucket upper edge in us.
  static uint64_t percentile(const uint32_t (&h)[NB + 1], double p) {
    uint64_t total = 0;
    for (unsigned i = 0; i <= NB; ++i) total += h[i];
    if (total == 0) return 0;
    const uint64_t rank = static_cast<uint64_t>(p * static_cast<double>(total) + 0.5);
    uint64_t acc = 0;
    for (unsigned i = 0; i <= NB; ++i) {
      acc += h[i];
      if (acc >= rank) return (i < NB) ? uint64_t(i + 1) * BUCKET_US : UINT64_MAX;  // overflow
    }
    return UINT64_MAX;
  }
 private:
  std::atomic<uint32_t> c_[NB + 1] = {};
  std::atomic<uint64_t> max_{0};
};
```

Notes:
- Report the overflow count explicitly; a percentile that lands in overflow means "> 200 ms".
- Keep the max separately (bucketing hides it). `uint32_t` counters last > 4 years at 30 fps.
- Histograms are `alignas(64)` and owned per stage, so no two writer threads share a line.
- Percentile resolution is 0.25 ms — state it in reports.

## 3. System sampling (1 Hz, low priority thread or external script)

| Metric | Source | Note |
|---|---|---|
| CPU % per core | `/proc/stat` lines `cpuN`: busy = total - idle - iowait, delta per interval | 0..100 per core |
| Process CPU | `/proc/self/stat` utime+stime delta | |
| CPU frequency | `/sys/devices/system/cpu/cpuN/cpufreq/scaling_cur_freq` (kHz) | shows thermal/power capping |
| SoC temperature | `/sys/class/thermal/thermal_zone*/temp` (milli-degC), name in `type` | which zone is the SoC: verify on TX8 |
| MX3 temperature | runtime API (`get_chip_temperatures` / `get_max_temperature`, see `um-pi-mx3-runtime-integration`) or `/sys/memx0/temperature` | file format: verify on TX8; 255 = chip locked |
| MX3 power | runtime `get_power()` if `can_get_power_consumption()` | mW |
| Memory | `/proc/self/status` `VmRSS` | must be flat after warm-up |

Discover the zones once: `ssh umpi 'for z in /sys/class/thermal/thermal_zone*; do echo $z $(cat $z/type) $(cat $z/temp); done'`.
Reading sysfs from the app is fine at 1 Hz; never in a per-frame path.

## 4. 10-minute soak test procedure

Preconditions: release build (`-O2 -mcpu=cortex-a53 ...`, no sanitizers), final MX3 clock
setting, the real camera, the base station (or `um-pi-basestation-viewer` on a Windows PC)
connected over the real link type, board in its flight enclosure/cooling if possible
(temperature results depend on it — record the setup and ambient temperature).

1. Start the app with inference on (`inference_on_boot` or send START).
2. On the dev machine:
   `ssh umpi 'bash /tmp/soak_test.sh -m 10 -i 1 -o /tmp/soak.csv -- /path/app --config /path/app.json'`
   (or `-p <pid>` to attach to an already running app).
3. Run the viewer for the same period with recording of its stats (skill `um-pi-basestation-viewer`).
4. In parallel the app logs one metrics line per second (below).
5. After the run: copy CSV and logs back (`scp umpi:/tmp/soak.csv .`), compute the summary.
6. Repeat a start/stop cycle test: 10 x (start, run 30 s, stop, wait 5 s) for start latency.

Suggested pass criteria (confirm with the product owner):
- inference fps >= 29.5 averaged over every 10 s window, CH1 fps likewise; no FAULT;
- TX8-internal p99 <= 80 ms over the whole run (and per minute);
- CH2 drops < 0.5 % of frames, no growing drop rate;
- RSS growth < 1 MB after the first minute; no CPU frequency capping events;
- start latency max <= 3 s over the cycle test.

## 5. Per-second log line (app)

Machine-parsable, one line per second, no allocation (format into a fixed buffer):
```
M t=123.0 st=RUN fps1=30.0 fpsi=29.9 tot_p50=41.2 tot_p99=63.5 dec_p99=9.8 mx3_p99=27.0
  drop1=0 drop2=3 cpu=38,22,61,47 soc=58.1 mx3=61.0 rss=48212
```
(Written as one line; wrapped here for readability.)

## 6. Report format

Report to the programmer as a table plus the commands used:

```
Build: <git sha>, flags, MX3 clock 300 MHz, chips 4, model yolov10n-pva-640
Setup: board EVT/MP, RAM, cooling, ambient, link (Ethernet/Wi-Fi), duration 10:00
| metric                  | value         | target   | pass |
| inference fps (min 10s) | 29.8          | >= 29.5  | yes  |
| total latency p50/p99   | 41 / 64 ms    | p99 <= 80| yes  |
| decode p50/p99          | 7.9 / 9.8 ms  | budget 12| yes  |
| MX3 p50/p99             | 22 / 27 ms    | budget 28| yes  |
| start latency med/max   | 1.5 / 1.9 s   | <= 3 s   | yes  |
| CPU per core avg/max    | 31/38/55/44 % | monitor  |      |
| SoC / MX3 temp max      | 64 / 71 degC  | monitor  |      |
| RSS start/end           | 48.1 / 48.2 MB| flat     | yes  |
| drops CH1 / CH2         | 0 / 3         |          |      |
```
The numbers above are an example of the format only, not TX8 measurements. Always include
what was not measured and why.

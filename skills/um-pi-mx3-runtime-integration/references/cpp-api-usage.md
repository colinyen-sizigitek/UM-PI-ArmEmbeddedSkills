# MemryX C++ runtime: verified API summary and `Mx3Engine` wrapper

Sources (checked 2026-10-08): https://developer.memryx.com/api/accelerator/cpp.html and the
open-source runtime https://github.com/memryx/MxAccl (headers `mx_accl/include/memx/accl/*.h`,
`tools/acclBench/acclBench.cpp`, MPL-2.0). The board has a packaged version (`memx-accl`) that may
differ from GitHub HEAD: **before compiling, diff every call below against
`/usr/include/memx/accl/MxAccl.h`, `MxAcclBase.h`, `MxAcclMT.h` and `utils/mxTypes.h`.**
Items marked **[VERIFY]** are inferred or inconsistent in the sources.

## 1. Classes and namespaces
| Item | Namespace / header |
|---|---|
| `MxAccl` (auto-threaded, callbacks) | `MX::Runtime`, `memx/accl/MxAccl.h` |
| `MxAcclMT` (manual threading: send/receive) | `MX::Runtime`, `memx/accl/MxAcclMT.h` |
| `MxAcclBase` (common base) | `MX::Runtime`, `memx/accl/MxAcclBase.h` |
| `SchedulerOptions`, `ClientOptions` | `MX::RPC` (docs) — check the header for the exact qualifier [VERIFY] |
| `FeatureMap`, `MxModelInfo`, `MxFrequencyOption`, `ShapeVector` | `MX::Types` |
| `MX_status` | `MX::Utils` |

## 2. Construction (both classes, same parameters)
```cpp
MxAccl(const std::filesystem::path& dfp_path,
       std::vector<int> device_ids_to_use = {0},          // {-1} = all devices (MT header comment)
       std::array<bool, 2> use_model_shape = {true, true}, // {input, output} keep model shape
       bool local_mode = false,                             // true = exclusive, no mxa-manager
       SchedulerOptions sched_options = {20, 250, 16, 21, false, 11500, false, 50, 6},
       ClientOptions client_options = {false, 0},
       std::string server_addr = "/run/mxa_manager/",
       unsigned int server_port_base = 10000,
       bool ignore_server_ = false);
// plus an overload taking (uint8_t* dfp_bytes, size_t dfp_byte_size, ...same...)
```
- The constructor **connects the DFP immediately** (calls the protected `connect_dfp`) and throws
  `std::runtime_error` if that fails. There is no public DFP-less constructor in `MxAccl`/`MxAcclMT`.
- `SchedulerOptions` fields in order: `frame_limit` (20), `time_limit` ms (250), `ifmap_queue_size`
  (16), `ofmap_queue_size` (21), `autoclock_enabled` (false), `autoclock_power_limit_mw` (11500),
  `autoclock_check_fps_saturation` (false), `autoclock_sample_interval_ms` (50),
  `autoclock_num_samples` (6). Keep `autoclock_enabled=false`: we set the clock explicitly.
- `ClientOptions`: `smoothing` (false), `fps_target` (0 = off).
- `ignore_server_=true` disables coordination with other processes: do not use.
- DFP byte overload: the buffer must stay valid during construction (MT header comment).

## 3. Clock, readiness, info, monitoring (from `MxAcclBase`)
```cpp
bool set_operating_frequency(int device_id,
        MX::Types::MxFrequencyOption freq_option = MX::Types::MxFrequencyOption::FREQ_USE_CONF);
bool is_ready();
int  get_num_models();
int  get_dfp_num_chips();
MX::Types::MxModelInfo get_model_info(int model_id = 0) const;
void set_parallel_fmap_convert(int num_threads, int model_id = 0);
bool can_get_power_consumption(int device_id = 0);
float get_power(int device_id = 0);                  // mW
float get_max_temperature(int device_id = 0);        // deg C
std::vector<float> get_chip_temperatures(int device_id = 0);  // per chip, deg C [VERIFY layout]
```
- `MxFrequencyOption` (uint16 enum in `utils/mxTypes.h`, GitHub HEAD): `FREQ_USE_CONF = 0`
  (use `/etc/memryx/power.conf`), `MX_FREQUENCY_OPTION_INVALID = 1`, and `FREQ_200MHz` ...
  `FREQ_1000MHz` in 25 MHz steps whose **numeric values equal the MHz** (e.g. `FREQ_300MHz = 300`).
  An inline `is_valid_frequency_option(uint16_t)` exists. [VERIFY in the installed header]
- **Ordering**: the docs say "call before `connect_dfp()`; calling it after throws". In the public
  API `connect_dfp` runs inside the constructor, and MemryX's own `acclBench` calls
  `set_operating_frequency()` **right after constructing** `MxAcclMT` and before `is_ready()` and
  any streaming. Follow acclBench: construct -> set frequency -> `is_ready()` -> streams. Check the
  return value (false = not applied) and confirm on the board that fps/power change with the clock.
  If the installed header differs (e.g. a DFP-less constructor + public `connect_dfp`), use
  set-frequency-then-connect. [VERIFY]
- Docs say the default option means 600 MHz; the header says "use power.conf"; ARM default power
  mode is 500 MHz. Always pass an explicit `FREQ_300MHz` / `FREQ_400MHz`.
- `MxModelInfo`: `model_index`, `num_in_featuremaps`, `num_out_featuremaps`, `input_layer_names`,
  `output_layer_names`, `in_featuremap_shapes`, `out_featuremap_shapes`, `in_featuremap_sizes`,
  `out_featuremap_sizes`. acclBench allocates `new float[in_featuremap_sizes[i]]` -> sizes are
  **element counts** (float32), not bytes.
- `get_power()`: in local mode reads from the device manager; in shared mode the manager's average.
  Check `can_get_power_consumption()` first; acclBench treats negative or > 30000 values as invalid.
- Data is float32 **NHWC** (with `use_model_shape` affecting reshape/transposition) — confirm the
  output layout of your model once by comparing to ONNX Runtime on x86.

## 4. Auto-threaded `MxAccl`
```cpp
using callback_t = /* bool(std::vector<const MX::Types::FeatureMap*>, int stream_id) */;
void connect_stream(callback_t in_cb, callback_t out_cb, int stream_id, int model_id = 0);
void start(int model_id = -1);
void wait(int model_id = -1);
void stop(int model_id = -1);       // DEPRECATED: does nothing
void set_num_workers(int input_num_workers, int output_num_workers, int model_id = 0);
// FeatureMap: MX::Utils::MX_status set_data(float* in) const; get_data(float* out) const;
```
- Input callback returning `false` ends that stream; when all streams end, `wait()` returns.
- Runtime threads call `in_cb` when they want a frame: the callback must **pull** a frame, so it
  either blocks waiting for the camera or returns `false` (which ends the stream). That conflicts
  with "callbacks must not block" and makes restart = recreate the object.

## 5. Manual-threaded `MxAcclMT`
```cpp
bool send_input(std::vector<float*> in_data, int model_id, int stream_id, int32_t timeout = 0);
bool receive_output(std::vector<float*>& out_data, int model_id, int stream_id, int32_t timeout = 0);
bool run(std::vector<float*> in_data, std::vector<float*>& out_data, int model_id, int stream_id,
         int32_t timeout = 0);
```
- Timeout in **ms**; **0 = block forever**. Return `false` = timed out (input not accepted / no
  output ready). acclBench uses one sender and one receiver thread per stream, no
  `connect_stream`/`start`.
- Whether `send_input` copies the input before returning is not documented [VERIFY in
  `MxAcclMT.cpp`]; the wrapper below keeps a ring of input buffers and reuses a slot only after its
  output arrived, which is safe either way.
- Outputs are assumed to arrive in submission order per stream [VERIFY]; the wrapper checks
  in-flight counts and can attach a frame id via its own FIFO.

## 6. Recommendation: `MxAcclMT` with our own threads
| Criterion | `MxAccl` (callbacks) | `MxAcclMT` (send/receive) |
|---|---|---|
| Back-pressure | implicit (runtime pulls) | explicit: we bound in-flight frames and drop at the source |
| Timeouts | none on callbacks | per call (ms) -> hang detection |
| Blocking in callbacks | in_cb must wait for frames | no callbacks; our threads block with timeouts |
| Start/stop | stop = in_cb returns false, then `wait()` | stop = stop sending, drain, destroy |
| Latency control | runtime worker threads | we decide; 1 sender + 1 receiver thread |
| Code size | smaller | slightly larger (wrapper below) |

**Use `MxAcclMT`** for production on TX8: the 80 ms p99 budget and fault handling need explicit
timeouts and bounded queues. Keep `MxAccl` for quick prototypes. Re-measure if you switch.

## 7. `Mx3Engine` sketch (C++17)
Owns one `MxAcclMT`. One producer thread calls `submit()`, one consumer thread calls `poll()`,
the control thread calls `start()`/`stop()` (never concurrently with submit/poll — the pipeline
stops its threads first). Monitoring is called from the consumer thread at <= 1 Hz because the
thread safety of monitor calls vs `receive_output` is not documented [VERIFY].

```cpp
// mx3_engine.h - SKETCH. Verify every MemryX call against /usr/include/memx/accl/*.h.
#pragma once
#include <memx/accl/MxAcclMT.h>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

struct Mx3Config {
  std::filesystem::path dfp;      // <name>_c<N>.dfp chosen by chip count
  int chips = 4;                  // must equal the DFP's compiled chip count
  int freq_mhz = 300;             // from the frequency rule, <= 400
  int device_id = 0;
  bool local_mode = true;         // single process, single DFP
  int max_in_flight = 3;          // back-pressure bound
  int send_timeout_ms = 50;
  int recv_timeout_ms = 200;      // > worst expected MX3 latency
  int convert_threads = 2;        // set_parallel_fmap_convert
};

enum class Mx3Status { Ok, Busy, Timeout, Fault, NotRunning };

struct Mx3Result {                // views into engine-owned buffers, valid until next poll()
  uint64_t frame_id = 0;
  int64_t capture_ts_us = 0;
  std::vector<const float*> outputs;
};

class Mx3Engine {
 public:
  Mx3Engine() = default;
  ~Mx3Engine() { stop(std::chrono::milliseconds(500)); }
  Mx3Engine(const Mx3Engine&) = delete;
  Mx3Engine& operator=(const Mx3Engine&) = delete;

  // Creates the accelerator, sets the clock, allocates buffers. Returns false + message on error.
  bool start(const Mx3Config& cfg, std::string* err) {
    if (accl_) { *err = "already running"; return false; }
    if (cfg.freq_mhz < 200 || cfg.freq_mhz > 400 || cfg.freq_mhz % 25 != 0) {
      *err = "freq must be 200..400 MHz in 25 MHz steps (product rule <= 400)"; return false;
    }
    if (cfg.max_in_flight < 1 || cfg.max_in_flight > 16) {
      *err = "max_in_flight must be 1..16"; return false;
    }
    cfg_ = cfg;
    const auto t0 = std::chrono::steady_clock::now();
    try {
      // Default SchedulerOptions/ClientOptions are kept by passing only 4 arguments. For shared
      // mode with frame_limit=0/time_limit=5000 pass a SchedulerOptions as 5th argument; its
      // namespace qualifier (MX::RPC per docs) must be taken from the installed header [VERIFY].
      accl_ = std::make_unique<MX::Runtime::MxAcclMT>(cfg.dfp, std::vector<int>{cfg.device_id},
                                                      std::array<bool, 2>{true, true},
                                                      cfg.local_mode);
      // Enum values equal MHz in the GitHub header [VERIFY installed header].
      const auto opt = static_cast<MX::Types::MxFrequencyOption>(cfg.freq_mhz);
      if (!accl_->set_operating_frequency(cfg.device_id, opt)) {
        *err = "set_operating_frequency failed"; accl_.reset(); return false;
      }
      if (!accl_->is_ready()) { *err = "accelerator not ready"; accl_.reset(); return false; }
      if (accl_->get_dfp_num_chips() != cfg.chips) {
        *err = "DFP chip count mismatch"; accl_.reset(); return false;
      }
      accl_->set_parallel_fmap_convert(cfg.convert_threads, 0);
      const MX::Types::MxModelInfo info = accl_->get_model_info(0);
      if (!alloc_ring(info)) {
        *err = "out of memory allocating 64B-aligned featuremap ring"; accl_.reset(); return false;
      }
    } catch (const std::exception& e) {
      *err = std::string("MxAcclMT start exception: ") + e.what(); accl_.reset(); return false;
    }
    in_flight_.store(0, std::memory_order_relaxed);
    running_.store(true, std::memory_order_release);
    start_ms_ = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    return true;
  }

  // Producer thread. Lock-free, zero-allocation. Copies one float32 NHWC frame per model input.
  Mx3Status submit(const std::vector<const float*>& inputs, uint64_t frame_id, int64_t ts_us) noexcept {
    if (!running_.load(std::memory_order_acquire)) return Mx3Status::NotRunning;
    if (in_flight_.load(std::memory_order_acquire) >= cfg_.max_in_flight) return Mx3Status::Busy;
    Slot& s = ring_[head_ % ring_.size()];
    for (size_t i = 0; i < inputs.size() && i < s.in.size(); ++i)
      std::memcpy(s.in[i], inputs[i], in_sizes_[i] * sizeof(float));
    s.frame_id = frame_id;
    s.ts_us = ts_us;
    try {
      if (!accl_->send_input(s.in_ptrs, 0, 0, cfg_.send_timeout_ms)) {
        return Mx3Status::Timeout;               // caller counts consecutive timeouts -> fault path
      }
    } catch (...) {
      return Mx3Status::Fault;
    }
    ++head_;
    in_flight_.fetch_add(1, std::memory_order_acq_rel);  // release publishes s.frame_id / s.ts_us
    return Mx3Status::Ok;
  }

  // Consumer thread. Lock-free, zero-allocation. Returns Ok, Busy (0 in flight), Timeout, or Fault.
  Mx3Status poll(Mx3Result* out) noexcept {
    if (!accl_ || !running_.load(std::memory_order_acquire)) return Mx3Status::NotRunning;
    if (in_flight_.load(std::memory_order_acquire) == 0) return Mx3Status::Busy;  // nothing pending
    Slot& s = ring_[tail_ % ring_.size()];
    try {
      if (!accl_->receive_output(s.out_ptrs, 0, 0, cfg_.recv_timeout_ms)) return Mx3Status::Timeout;
    } catch (...) {
      return Mx3Status::Fault;
    }
    out->frame_id = s.frame_id;
    out->capture_ts_us = s.ts_us;
    out->outputs.assign(s.out_ptrs.begin(), s.out_ptrs.end());   // capacity reserved by caller
    ++tail_;
    in_flight_.fetch_sub(1, std::memory_order_acq_rel);
    return Mx3Status::Ok;
  }

  // Low-rate monitoring (<= 1 Hz), consumer thread. Returns false on a hard fault (255 C lock).
  bool monitor(float* max_temp_c, float* power_mw) noexcept {
    if (!accl_) return false;
    try {
      const std::vector<float> t = accl_->get_chip_temperatures(cfg_.device_id);
      float mx = -1000.f;
      for (float v : t) mx = v > mx ? v : mx;
      *max_temp_c = mx;
      *power_mw = accl_->can_get_power_consumption(cfg_.device_id) ? accl_->get_power(cfg_.device_id) : -1.f;
      return mx > -40.f && mx < 254.5f;          // 255 deg C = locked chip -> FAULT, reboot required
    } catch (...) {
      return false;
    }
  }

  // Control thread, after producer/consumer threads have stopped calling submit/poll.
  // Drains in-flight frames with a deadline, then destroys the accelerator (releases the device).
  // Returns elapsed ms; *clean=false if frames were abandoned.
  double stop(std::chrono::milliseconds drain_deadline, bool* clean = nullptr) noexcept {
    if (!accl_) { if (clean) *clean = true; return 0.0; }
    const auto t0 = std::chrono::steady_clock::now();
    running_.store(false, std::memory_order_release);
    bool ok = true;
    try {
      while (in_flight_.load(std::memory_order_acquire) > 0) {
        if (std::chrono::steady_clock::now() - t0 > drain_deadline) { ok = false; break; }
        Slot& s = ring_[tail_ % ring_.size()];
        if (accl_->receive_output(s.out_ptrs, 0, 0, 50)) {
          ++tail_;
          in_flight_.fetch_sub(1, std::memory_order_acq_rel);
        }
      }
    } catch (...) {
      ok = false;
    }
    accl_.reset();                              // destructor closes local/shared session
    if (clean) *clean = ok;
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  }

  double start_ms() const noexcept { return start_ms_; }
  bool running() const noexcept { return running_.load(std::memory_order_acquire); }

 private:
  struct AlignedFree { void operator()(float* p) const noexcept { std::free(p); } };
  using Buf = std::unique_ptr<float, AlignedFree>;
  struct Slot {
    std::vector<Buf> in_store, out_store;
    std::vector<float*> in, in_ptrs, out_ptrs;
    uint64_t frame_id = 0;
    int64_t ts_us = 0;
  };

  static Buf alloc64(size_t n) noexcept {
    const size_t bytes = ((n * sizeof(float) + 63) / 64) * 64;
    void* p = std::aligned_alloc(64, bytes);
    if (!p) return Buf(nullptr);
    std::memset(p, 0, bytes);                   // pre-fault all pages at start, zero-init
    return Buf(static_cast<float*>(p));
  }
  bool alloc_ring(const MX::Types::MxModelInfo& info) {
    in_sizes_.assign(info.in_featuremap_sizes.begin(), info.in_featuremap_sizes.end());
    ring_.clear();
    ring_.resize(static_cast<size_t>(cfg_.max_in_flight) + 1);
    for (Slot& s : ring_) {
      for (size_t n : info.in_featuremap_sizes) {
        Buf b = alloc64(n);
        if (!b) return false;
        s.in.push_back(b.get());
        s.in_store.push_back(std::move(b));
      }
      for (size_t n : info.out_featuremap_sizes) {
        Buf b = alloc64(n);
        if (!b) return false;
        s.out_ptrs.push_back(b.get());
        s.out_store.push_back(std::move(b));
      }
      s.in_ptrs = s.in;
    }
    head_ = tail_ = 0;
    return true;
  }

  Mx3Config cfg_{};
  std::unique_ptr<MX::Runtime::MxAcclMT> accl_;
  std::vector<Slot> ring_;
  std::vector<size_t> in_sizes_;
  alignas(64) size_t head_ = 0;                 // producer only (own cache line)
  alignas(64) size_t tail_ = 0;                 // consumer only (own cache line)
  alignas(64) std::atomic<int> in_flight_{0};
  alignas(64) std::atomic<bool> running_{false};
  double start_ms_ = 0.0;
};
```
Notes on the sketch:
- `alloc64` checks for `nullptr` and pre-faults every page (`std::memset`), failing `start()` cleanly on OOM instead of crashing on the first frame.
- `poll()` returns `Busy` immediately when nothing is in flight: the consumer must then wait on a semaphore/eventfd signalled by the producer after a successful `submit()` — never spin (acclBench's receiver busy-waits; do not copy that).
- The ring has `max_in_flight + 1` slots; `frame_id` and `ts_us` live directly inside `Slot` and are published via `in_flight_.fetch_add(..., memory_order_acq_rel)` without any `std::mutex` or `std::deque` heap block allocations.
- **Zero-copy optimization**: to save 19.6 MB/s of DRAM traffic (at 640x640x3 float32 @ 30 fps), expose `float* acquire_input_slot(int idx)` so the TurboJPEG/NEON normalize stage writes directly into `ring_[head_ % ring_.size()].in[idx]` before calling a copy-free `submit_acquired(frame_id, ts_us)`.
- `Mx3Result::outputs.assign` does not allocate after the first call if the caller reuses the same `Mx3Result` (`res.outputs.reserve(4)` once at startup).
- `send_input` and `receive_output` are wrapped in `try/catch (...)` inside `noexcept` methods so an unexpected MemryX runtime exception transitions to `Mx3Status::Fault` instead of `std::terminate()`.
- `start()` must finish well within the 3 s start budget: log `start_ms()` every start.

## 8. Usage pattern (pipeline side)
```cpp
Mx3Engine eng;
std::string err;
if (!eng.start({"/home/umpi/models/m/current/m_c4.dfp", 4, 300}, &err)) report_fault(err);
// producer thread: decoded 640x640 RGB float NHWC frame -> eng.submit({buf}, id, ts)
//   Busy    -> drop this frame (keep latest), count drops
//   Timeout -> count; N consecutive -> request fault handling (fault-handling.md)
// consumer thread: eng.poll(&res) -> threshold + top-K -> metadata out; monitor() once per second
// on STOP: stop producer + consumer threads, then eng.stop(500ms) -> report "stopped"
```

## 9. Build notes
- Include path `/usr/include` (headers under `memx/accl/`); library from `dpkg -L memx-accl`
  (e.g. a `libmx_accl.so` — confirm the exact name before writing link lines) [VERIFY].
- The headers use `std::filesystem`: C++17, GCC 11 needs no extra library.
- Global flags per project rules: `-O2 -mcpu=cortex-a53 -mno-outline-atomics -Wall -Wextra -Werror`;
  MemryX headers may trigger warnings — include them as system headers (`-isystem`) rather than
  dropping `-Werror`.

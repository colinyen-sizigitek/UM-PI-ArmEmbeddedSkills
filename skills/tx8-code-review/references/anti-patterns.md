# Common anti-patterns on TX8 and their fixes

Each item: smell → why it hurts on TX8 → fix. Rule ids refer to `checklist.md`.

## 1. Allocation per frame (RT-1)
```cpp
// BAD: allocates ~4.9 MB every frame (640*640*3 floats)
std::vector<float> input(640 * 640 * 3);
```
Why: the allocator takes locks and touches new pages; it causes latency spikes that hurt p99.
Fix: pre-allocate a pool at start-up, sized to the queue depth, and reuse the buffers.
```cpp
struct FramePool { std::array<std::unique_ptr<float[]>, kDepth> bufs; /* acquire/release by index */ };
```

## 2. Unbounded queue between stages (RT-2)
```cpp
std::queue<Frame> q;  // grows without limit when MX3 or the network stalls
```
Fix: use a fixed-capacity SPSC ring. For video, drop the oldest entry when full; for control
messages, never drop. Count drops and report the counter.

## 3. Wait without timeout (RT-3)
```cpp
accl.wait();          // hangs forever if the device locks up
cv.wait(lock);        // no predicate, no deadline
```
Fix: use `wait_for` or `wait_until` with a deadline. Use the timeout variants of MX3 send/receive.
On timeout, go to the fault path (step the clock down, reconnect, report).

## 4. Blocking inside MX3 callbacks (MX-3)
```cpp
bool out_cb(std::vector<const MX::Types::FeatureMap*> ofmaps, int sid) {
    ws.send(serialize(ofmaps));   // network I/O inside the runtime thread
    return true;
}
```
Fix: copy the outputs into a pooled buffer with `get_data`, push the index to an SPSC ring and
return. A sender thread does the I/O.

## 5. MX3 clock from defaults or above 400 MHz (MX-1)
Smell: no `set_operating_frequency` call (so MemryX's ARM default of 500 MHz applies), or a literal 500.
Fix: compute the clock with the frequency rule from `mx3-model-selection` and set it right after
the accelerator object is constructed, before any input is sent. Follow the order used in the
installed header and MemryX's acclBench. If the rule says "not recommended", choose a different model.

## 6. Accelerator kept alive while idle (MX-2)
Smell: a global MxAccl object created at start-up that lives for the whole process.
Fix: create it on `InferenceControl::start` and destroy it on `stop`. Measure the start latency (≤ 3 s).

## 7. Decode + re-encode for the base station (VIS-1)
Smell: CH1 is decoded and then re-encoded to draw boxes on it.
Fix: forward the CH1 MJPEG bytes unchanged. Send detections as metadata; the base station draws them.

## 8. OpenCV in the hot path (VIS-2)
```cpp
cv::cvtColor(bgr, rgb, cv::COLOR_BGR2RGB); cv::resize(...);
```
Fix: decode with TurboJPEG straight into RGB (TJPF_RGB) and at the target size. Convert u8 → float
with a NEON loop that writes into the MX3 input buffer (see `tx8-cpp-performance`).

## 9. Branchy threshold loop (PERF-3)
```cpp
for (int i = 0; i < n; ++i) if (score[i] > th) out[k++] = i;
```
Why: A53 has no BTB and pays ~7 cycles per mispredict, and scores are unpredictable.
Fix: compare with NEON (`vcgtq_f32`), then do a branch-free compaction. Keep a scalar reference
and test the NEON version against it.

## 10. Double conversion / copies (PERF-5, PERF-6)
Smell: decode → RGB buffer → float buffer → copy into a FeatureMap.
Fix: decode → RGB buffer → one NEON convert directly into the MX3 input buffer. Measure the gain.

## 11. Wall clock for latency (RT-6)
Smell: `std::chrono::system_clock` or `gettimeofday` used for stage timing.
Fix: use `CLOCK_MONOTONIC`, and the V4L2 buffer timestamp for capture time.

## 12. Silent MAVLink destination (OUT-3)
Smell: a hard-coded `udp:192.168.x.x:14550` or `/dev/ttyS1` with no config option.
Fix: make it configurable, and record which destination the programmer chose.

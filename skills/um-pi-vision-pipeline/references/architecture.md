# Pipeline architecture

Stages, threads, buffer ownership, queues and the latency budget of the TX8 vision pipeline.
Everything here is a **starting point to measure**, not a tuned result. Numbers marked
"verify on TX8" must be replaced by measurements before they are quoted.

## 1. Stage diagram

```
                USB UVC camera (MJPEG)
                 |                    |
          CH1 1080p30            CH2 640x640@30   (only while inference RUNNING/STARTING)
                 |                    |
   [T1 cap_ch1] VIDIOC_DQBUF    [T2 cap_ch2] VIDIOC_DQBUF
     SOI/EOI check, ts             SOI/EOI check, ts
                 |                    |
                 |              Q2 SPSC (depth 2, drop-oldest) -> V4L2 buf idx back to T2
                 |                    |
                 |             [T3 decode+pre] tjDecompress2 -> RGB pool
                 |                    |   u8 RGB -> float32 NHWC -> float pool
                 |                    |
                 |              Q3 SPSC (depth 2, drop-oldest)
                 |                    |
                 |             [MX3 runtime] input cb: set_data(float*)
                 |                    |       output cb: get_data -> threshold + top-K
                 |                    |       (skill um-pi-mx3-runtime-integration)
                 |                    |
        Q1 SPSC (depth 4,       Q4 SPSC (depth 8, drop-oldest) detections
        drop-oldest, holds            |
        V4L2 buf refs)                |
                 \                   /
                  [T4 sender] WebSocket (or MAVLink + WebSocket video)
                  header + gather-write JPEG bytes; DETECTIONS; STATUS
                         |
                   network -> base station (skill um-pi-basestation-viewer)

   [T5 control] InferenceControl events -> state machine -> starts/stops T2, T3, MX3
   [T6 metrics] 1 Hz: histograms -> STATUS, CPU/temp sampling (cheap, low priority)
```

CH1 never touches the decode path. The only CPU work on CH1 is DQBUF, an SOI/EOI check, a
header encode and the socket write.

## 2. Threads and initial core plan

Cortex-A53 x4, shared 1 MB L2. The MemryX runtime (`MxAccl`) creates its own worker threads;
how many and whether they can be pinned is runtime-version specific — see skill
`um-pi-mx3-runtime-integration` and check `top -H -p <pid>` on the board.

| Thread | Work | Initial core | Priority hint |
|---|---|---|---|
| T1 cap_ch1 | poll + DQBUF CH1, validate, push Q1, re-QBUF returned buffers | 1 | normal (SCHED_OTHER), nice -5 |
| T2 cap_ch2 | same for CH2, push Q2 | 1 | nice -5 |
| T3 decode+pre | TurboJPEG decode, u8 -> f32 NHWC | 2 | normal |
| MX3 runtime | input/output callbacks, post-process (threshold + top-K) | 3 | normal |
| T4 sender | socket I/O (Asio/Beast io_context or lws loop) | 0 | normal |
| T5 control | state machine, command sources | 0 | normal |
| T6 metrics | 1 Hz sampling, STATUS build | 0 | nice +5 |

Rules:
- Core 0 also takes most IRQs (xHCI, Ethernet) by default; check `cat /proc/interrupts` on
  the board before deciding. Do not change IRQ affinity without approval.
- Pin with `pthread_setaffinity_np` only after a baseline without pinning; keep pinning if
  it improves p99, remove it if it does not.
- Real-time scheduling (SCHED_FIFO) is not the default: it can starve the USB/network
  stack. Try only if p99 is jitter-dominated, and only with approval.
- Thread count is part of the power budget: once targets are met, try fewer MX3 workers
  (`set_num_workers`, see `um-pi-mx3-runtime-integration`).

## 3. Buffer ownership

Every buffer has exactly one owner at any time. Ownership moves through queues; the
consumer gives it back through a return queue (or a pool free list) — never by touching
the producer's data structures.

| Buffer | Count (start) | Size | Owner flow |
|---|---|---|---|
| CH1 V4L2 mmap | 8 (`VIDIOC_REQBUFS`) | driver-chosen (`length`) | driver -> T1 -> Q1 -> T4 -> return queue -> T1 QBUF |
| CH2 V4L2 mmap | 4 | driver-chosen | driver -> T2 -> Q2 -> T3 -> return queue -> T2 QBUF |
| RGB u8 pool | 2 | 640x640x3 = 1.2 MB | T3 only (decode target, reused) |
| Float pool | 3 | 640x640x3x4 = 4.9 MB | T3 -> Q3 -> MX3 input cb (after `set_data` copies) -> free list |
| Detection pool | 16 | `2 + 22 x K` bytes + meta | MX3 output cb -> Q4 -> T4 -> free list |
| Send header pool | 32 | 20 B | T4 only |

Memory total stays well below 50 MB; EVT boards have 2 GB, MP boards 4 GB — read
`/proc/meminfo` at startup and log it, never hard-code.

## 4. Bounded SPSC queues with drop-oldest

- Single producer, single consumer, power-of-two ring, `std::atomic<uint32_t>` head/tail with
  acquire/release; head and tail on separate 64 B cache lines (`alignas(64)`).
- Drop-oldest is done by the **producer**: if full, it pops the oldest element itself and
  returns that element's buffer to the pool (for V4L2 buffers: to the capture thread's own
  re-queue list), increments a drop counter, then pushes. With SPSC this requires the
  consumer never to hold a pointer into the ring slot — copy the small handle out on pop.
  A simpler correct alternative: depth-1 "latest slot" (atomic exchange of a handle),
  which is exactly drop-oldest with depth 1. Prefer it for Q2/Q3.
- Pop always has a timeout (e.g. `poll` on an eventfd, or a condition variable with
  `wait_for`); no spin loops at 100% CPU.
- Drop counters: per queue, `alignas(64) std::atomic<uint32_t>`, exported in STATUS.

Why drop-oldest: for live video the newest frame is the most valuable; queuing old frames
only adds latency. A depth > 2 on the inference path converts overload into latency, which
breaks the p99 target. Depth 4 on Q1 absorbs short network jitter for video.

## 5. Zero-copy rules

1. **V4L2 mmap** for both channels (`V4L2_MEMORY_MMAP`). Never `read()`.
2. **CH1**: hand the dequeued V4L2 buffer itself (index + pointer + `bytesused` + timestamp)
   to the sender as a reference. The sender gather-writes `[20 B header][mmap bytes]`. When
   the write completes, the index goes back to T1 via a return SPSC queue and T1 re-QBUFs.
   - Cap: the sender may hold at most `nbuf - 3` CH1 buffers; if it would exceed that, the
     oldest unsent frame is dropped (returned) — the camera must never starve.
   - If the WebSocket library copies internally anyway (check: Beast writes server frames
     unmasked straight from the buffer sequence; libwebsockets needs `LWS_PRE` headroom so it
     forces one copy), one memcpy of ~100-400 KB is acceptable — measure; do not contort the
     design for it.
3. **CH2**: decode straight from the mmap buffer into a pooled RGB buffer (no intermediate
   copy), re-QBUF immediately after decode. Convert into a pooled float buffer.
4. **MX3 input**: `FeatureMap::set_data(float*)` copies/converts from our float buffer; the
   float buffer is free again when `set_data` returns (verify in the installed header /
   docs of `um-pi-mx3-runtime-integration`). If the DFP was compiled with an input layout that
   lets the runtime accept a different format, that is a later optimization — measure first.
5. Detections are tiny; copying them is fine.

## 6. Latency budget (p99 <= 80 ms at 30 fps)

TX8-internal latency = time from the CH2 V4L2 buffer timestamp to the moment the
DETECTIONS message was handed to the socket (write completed into the kernel).
**All values are initial targets to verify on TX8**, not measurements.

| Stage | From -> to | Budget p99 | Note |
|---|---|---|---|
| Capture / USB transfer | V4L2 ts -> DQBUF return | 20 ms | uvcvideo ts is start-of-frame; includes the USB transfer of the frame |
| Queue wait Q2 | push -> pop | 2 ms | depth 1-2 |
| JPEG decode 640x640 | T3 | 12 ms | libjpeg-turbo NEON, verify on TX8 |
| Preprocess u8 -> f32 NHWC | T3 | 4 ms | NEON kernel, see `um-pi-cpp-performance` |
| MX3 (set_data -> output cb) | runtime | 28 ms | depends on model/clock; measure with `mx_bench` and in-app |
| Post-process | threshold + top-K + map | 1 ms | branchless NEON |
| Serialize + send | Q4 + socket write | 3 ms | |
| **Sum** | | **70 ms** | 10 ms margin for jitter |

Notes:
- The sum of per-stage p99 is pessimistic (they rarely align), but use it for planning.
- 30 fps means a new frame every 33.3 ms; any stage with p50 > 33 ms needs pipelining
  (the MX3 runtime pipelines internally; CPU stages must each stay < 33 ms per frame).
- If capture-to-DQBUF alone is > 33 ms, the camera or USB link is the bottleneck: check
  USB speed (`lsusb -t`) and camera settings before touching code.

## 7. Start latency budget (<= 3 s)

From receipt of `InferenceControl{start}` to the first DETECTIONS message sent.

| Step | Budget | Parallel? |
|---|---|---|
| State -> STARTING, STATUS sent | < 10 ms | — |
| CH2 open + S_FMT + REQBUFS + mmap + STREAMON | 300 ms | parallel with MX3 load |
| First valid CH2 frame (camera warm-up, AE) | 700 ms | parallel with MX3 load |
| MX3 open + clock set + DFP load (`MxAccl` ctor / connect) | 1500 ms | verify on TX8 |
| First inference + post + send | 100 ms | — |
| **Total (critical path)** | **~1.6-2.2 s** | target <= 3 s |

Measure with timestamps at each step (see `latency-and-metrics.md`). Speed-ups if needed:
keep the DFP bytes in RAM (in-memory DFP constructor, see `um-pi-mx3-runtime-integration`), keep
the CH2 device open (but STREAMOFF) while idle, discard the first N CH2 frames only if they
are corrupt.

## 8. Error handling map

| Failure | Detection | Action |
|---|---|---|
| CH1 corrupt frame | SOI/EOI missing, `V4L2_BUF_FLAG_ERROR` | drop, count, re-QBUF |
| CH1 device lost | `ENODEV` from DQBUF/poll `POLLERR` | close, retry open with backoff; STATUS fault CameraCh1 while down |
| CH2 lost while RUNNING | same | state -> FAULT (CameraCh2), release MX3, retry per control policy |
| Decode error | `tjDecompress2` < 0 and error is fatal | drop frame, count; > N in a row -> FAULT Decode |
| MX3 output timeout | no output within e.g. 500 ms while inputs sent | FAULT Mx3Timeout; frequency step-down policy in `um-pi-mx3-runtime-integration` |
| MX3 temperature high | runtime temperature API | step down one clock level, report |
| Send queue full | Q1/Q4 full | drop oldest video first, then oldest detections; never block |
| Client disconnect | socket error | drop all queued sends, return buffers, keep capturing CH1 |

## 9. Sources
- Linux V4L2 streaming I/O: https://www.kernel.org/doc/html/v5.15/userspace-api/media/v4l/mmap.html
- libjpeg-turbo TurboJPEG API: https://libjpeg-turbo.org/Documentation/Documentation
- Arm memory ordering doc 102336 (acquire/release on A53 without LSE).

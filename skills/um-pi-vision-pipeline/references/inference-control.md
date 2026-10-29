# Inference on/off control

All ways of turning inference on or off map to **one** internal event,
`InferenceControl{start|stop}`, consumed by **one** state machine. MX3 is active only while
inference is on; CH1 streams in every state; CH2 capture runs only in STARTING/RUNNING.

## 1. Command sources

| Source | Wire form | Ack |
|---|---|---|
| Base station (WebSocket) | CONTROL message type 0x10, `cmd = Start/Stop` (`assets/protocol.h`) | CONTROL_ACK 0x11 immediately (`Ok` = accepted), then STATUS on state change |
| Flight controller / GCS (MAVLink) | `COMMAND_LONG` with a custom command id (see `output-mavlink.md`), `param1 = 1` start / `0` stop | `COMMAND_ACK` (`MAV_RESULT_ACCEPTED`), state via the status message |
| Local | Unix domain socket (e.g. under `/run/<app>/`, created by systemd `RuntimeDirectory=`), CLI wrapper `<app>ctl start|stop|status` | text reply |
| Config | `inference_on_boot: true|false` at startup | log line |

Rules:
- Every source handler only validates, logs `{source, cmd, t_rx}` and posts the event. It never
  starts cameras or MX3 itself and never blocks.
- The ack means "accepted", not "running". The real state is reported by STATUS
  (`starting`, `running`, `stopped`, `fault`) to every connected output.
- Authentication/authorization of sources is a product decision — ask the programmer whether
  the base-station link needs it (e.g. MAVLink signing, a shared token on the WebSocket).

## 2. State machine

```
               start                     first DETECTIONS sent
   +------+ ----------> +----------+ -------------------------> +---------+
   | IDLE |             | STARTING |                            | RUNNING |
   +------+ <---------- +----------+                            +---------+
      ^       done          | error/timeout                        |  |
      |                     v                                stop  |  | error
      |                 +-------+  <-------------------------------+--+
      |   stop          | FAULT |                                  |
      +---------------- +-------+ <--- error/timeout --+           v
      |   (release done)   ^  | retry (desired=start)  |     +----------+
      |                    |  +--------> STARTING      +---- | STOPPING |
      +--------------------+-------------------------------- +----------+
                                   done (resources released)
```

| State | CH1 | CH2 | MX3 | Leaves on |
|---|---|---|---|---|
| IDLE | streaming | stopped, buffers freed | released (no `MxAccl` object) | `start` -> STARTING |
| STARTING | streaming | open + STREAMON (parallel with MX3 load) | create (loads DFP), set clock (≤400 MHz, before any input; see `um-pi-mx3-runtime-integration`), start feeding | first DETECTIONS sent -> RUNNING; error or start timeout -> FAULT |
| RUNNING | streaming | streaming -> decode -> MX3 | running | `stop` -> STOPPING; camera/MX3 error, output timeout, thermal -> FAULT |
| STOPPING | streaming | stop thread, drain, STREAMOFF, munmap, REQBUFS(0) | end stream, `wait()` with timeout, destroy object | done -> IDLE (or STARTING if desired became `start`); stop timeout -> FAULT |
| FAULT | streaming (if healthy) | released | released | `stop` -> IDLE; `start` -> STARTING; auto-retry while desired = `start` |

Timeouts (starting values; tune from measurements):
- Start: soft target 3 s (report a warning and count it), hard limit 8 s -> FAULT `StartTimeout`.
- Stop: 2 s -> FAULT `Internal` (resources may be leaked: log loudly; a supervisor such as
  systemd `Restart=on-failure` is the last resort — ask before adding a unit file).
- RUNNING output watchdog: no MX3 output for 500 ms while inputs are being sent -> FAULT
  `Mx3Timeout` (frequency step-down policy: skill `um-pi-mx3-runtime-integration`).
- Auto-retry from FAULT while desired = `start`: backoff 1 s, 2 s, 5 s, then stay in FAULT and
  wait for a new command. Each retry is reported.

## 3. Last command wins and idempotence

- Every command overwrites one atomic `desired` (start/stop) plus a sequence number.
- The machine never queues a list of commands. After finishing the current transitional step
  it compares `state` with `desired` and moves toward `desired`.
- `start` while RUNNING or STARTING, `stop` while IDLE or STOPPING: no-op, ack `Ok`, log it.
- `stop` arriving in STARTING: the MX3 constructor/DFP load may be a blocking call that cannot be
  cancelled — let it finish, then go straight to STOPPING without sending detections.
- Rapid start/stop/start sequences end in the state of the last command; test this.

## 4. Status reporting

- STATUS (`protocol.h` `StatusPayload`) is sent on every state change and at 1 Hz, with the
  fault code when in FAULT. MAVLink output sends the equivalent custom status message (and
  optionally `STATUSTEXT` on transitions).
- Log every transition: `{t, from, to, reason, desired, seq}`.

## 5. Start latency measurement

Record CLOCK_MONOTONIC at each milestone of a start and log one line per start:

```
start seq=17 src=ws t_cmd=0 ch2_streamon=+180ms first_ch2=+640ms mx3_ready=+1420ms
      first_output=+1490ms first_sent=+1495ms total=1495ms
```

- `total = first_sent - t_cmd` is the metric with the 3 s target.
- Collect >= 10 start/stop cycles (cold after boot and warm) and report median and max.
- If over budget, the milestones show where: MX3 load (try in-memory DFP), camera warm-up
  (keep fd open while idle), or serialization (start CH2 and MX3 in parallel, as below).

## 6. Compact C++17 sketch

```cpp
enum class Cmd : uint8_t { Start, Stop };
enum class State : uint8_t { Idle, Starting, Running, Stopping, Fault };

class InferenceController {
 public:
  // Called from any source thread. Never blocks for long.
  void post(Cmd c, const char* source) {
    {
      std::lock_guard<std::mutex> lk(m_);
      desired_ = c;
      ++seq_;
    }
    cv_.notify_one();
    log_command(source, c, now_us());
  }

  void run(const std::atomic<bool>& quit) {         // controller thread
    std::unique_lock<std::mutex> lk(m_);
    while (!quit.load(std::memory_order_relaxed)) {
      if (state_ != State::Starting && state_ != State::Stopping)   // no wait mid-transition
        cv_.wait_for(lk, std::chrono::milliseconds(100));             // periodic watchdog tick
      const Cmd want = desired_;
      lk.unlock();
      step(want);                                    // may block (bounded) on start/stop work
      lk.lock();
    }
  }

 private:
  void step(Cmd want) {
    switch (state_) {
      case State::Idle:
        if (want == Cmd::Start) enter(State::Starting);
        break;
      case State::Starting: {
        StartResult r = do_start(/*hard_timeout_ms=*/8000);   // CH2 + MX3 in parallel
        if (r.ok) enter(State::Running);
        else enter_fault(r.fault);
        break;
      }
      case State::Running:
        if (want == Cmd::Stop) enter(State::Stopping);
        else if (FaultCode f = check_health(); f != FaultCode::None) enter_fault(f);
        break;
      case State::Stopping:
        if (do_stop(/*timeout_ms=*/2000)) enter(want == Cmd::Start ? State::Starting : State::Idle);
        else enter_fault(FaultCode::Internal);
        break;
      case State::Fault:
        if (want == Cmd::Stop) enter(State::Idle);
        else if (retry_due()) enter(State::Starting);       // backoff 1 s, 2 s, 5 s, then wait
        break;
    }
  }

  void enter(State s) { log_transition(state_, s); state_ = s; publish_status(); }
  void enter_fault(FaultCode f) { release_all(); fault_ = f; enter(State::Fault); }

  StartResult do_start(int hard_timeout_ms);   // first DETECTIONS sent == success
  bool do_stop(int timeout_ms);                 // CH2 off, MX3 released; false on timeout
  FaultCode check_health();                     // output watchdog, camera, temperature
  bool retry_due();
  void release_all();                           // idempotent: safe in any state
  void publish_status();
  void log_command(const char*, Cmd, uint64_t);
  void log_transition(State, State);
  static uint64_t now_us();

  std::mutex m_;
  std::condition_variable cv_;
  Cmd desired_ = Cmd::Stop;
  uint32_t seq_ = 0;
  State state_ = State::Idle;                   // touched only by the controller thread
  FaultCode fault_ = FaultCode::None;
};
```

Notes on the sketch:
- `step()` re-reads `desired_` only between steps: this gives last-command-wins without queues.
- `do_start` itself must poll `desired_` at its checkpoints (after CH2 STREAMON, after MX3 load)
  and abort to STOPPING if it changed to `Stop`.
- `release_all()` must be idempotent so FAULT can be entered from any partial start.
- Unit-test the machine with fake `do_start/do_stop` (success, failure, timeout, stop-during-start,
  rapid toggles) on the dev machine; run the real start/stop cycle test on TX8.

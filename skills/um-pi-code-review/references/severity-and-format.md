# Severity rules and report format

## Severity
| Level | Meaning | Examples |
|---|---|---|
| BLOCKER | Can crash, hang, overheat, damage data, break a hard target, or violate a product rule. Must be fixed before merge/flight. | Any ⚠ checklist item; unbounded queue; MX3 at 500 MHz; wait without timeout |
| MAJOR | Likely to miss a target (30 fps, p99 ≤ 80 ms, start ≤ 3 s) or waste power/CPU, or hides errors. | Per-frame copy of a 1080p frame; float conversion done twice; swallowed error |
| MINOR | Correct but fragile or harder to maintain; small measurable inefficiency. | Magic numbers; missing scalar reference test; unaligned buffers |
| NIT | Style/naming with no behavioural impact. | Formatting, comment wording |

Rules:
- When unsure between two levels, pick the higher one and say why.
- A performance claim without TX8 numbers is at least MINOR ("unverified optimization"), and MAJOR
  if the change adds complexity or risk.
- Do not report more than 5 NITs; summarize the rest.

## Report format

```
## Review: <scope>
Verdict: APPROVE | APPROVE WITH FIXES | BLOCK
Areas: capture, decode, MX3 runtime, transport, build ...

| # | Sev | Location | Rule | Issue | Impact | Fix |
|---|-----|----------|------|-------|--------|-----|
| 1 | BLOCKER | src/mx3_engine.cpp:88 | MX-1 | Clock set to 500 MHz | Instability per reference table; exceeds ≤400 MHz rule | Read clock from freq rule; default 300 MHz |

### Verify on board
- `ssh umpi 'sudo lspci -vv | grep -A2 -i memryx'` — confirm link width (finding #4)

### Evidence required before merge
- Before/after median & p99 for decode stage (finding #2)

### Good patterns kept
- SPSC ring with acquire/release in capture → decode handoff
```

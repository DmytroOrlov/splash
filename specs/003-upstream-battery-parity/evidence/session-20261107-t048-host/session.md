# Splash T048 physical Apple Silicon session — verified evidence summary

Date: 2026-11-07, macOS 26.7 (build 25G229). Original raw session: `splash-T048-physical-20261107-130821.tgz` and the corresponding `session-20261107-t048-host` directory. This document summarizes **observed evidence only**, not additional measurements.

## Reproducibility and provenance

- Model: `ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF:IQ1_M`, installed resolved selection from the archived server process command.
- Native binary: `build/t015-corrected/splash`, SHA256 `32b3a834c04d30827426b2e9cd6a5fd64d4254bda419a428d6cd511b84d292c7`.
- Metallib SHA256 `9ea41cdf5f0f767831d311a1d6ef7bac932d7a6f53f59a441dc733c74b44eacd`.
- Server launch: `.venv/bin/python -m server.server <resolved-model-path> --model ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF:IQ1_M --binary build/t015-corrected/splash --port 18973 --pause-on-battery --max-memory 24G --max-context 32K`. Environment: `SPLASH_RESIDENCY_EVIDENCE=1`, `SPLASH_START_EVIDENCE=<session>/start-events.jsonl`.
- Python server PID 957; **native child PID 962** in archived `ps.battery.txt` and `ps.final.txt`; `transport.restarts=0` on all saved status phases.
- Physical Battery → AC → Battery → AC: `power.initial-battery.txt`, `power.battery.txt`, `power.recovered.txt`, status JSONs, and monitor corroborate these transitions. Actual long-prefix AC warmup happened between the two Battery phases.

## Observed outcomes

- Lifecycle statuses: initial Battery suspended revision 1; AC Ready revision 2; Battery suspended revision 3; AC Ready revision 4. Control plane remained responsive in sampled observations.
- Warm request: HTTP 200, 27865 prompt tokens, 0 cached, **66.703512 seconds**.
- Recovered request: HTTP 200, 27865 prompt tokens, **27840 cached**, **25 uncached**, **3.027476 seconds**. Speedup 22.03× on these two measured requests; not a generalized benchmark claim.
- Published effective context after recovery 32768. Decoded in-band `StartEvent` events: request IDs 1 and 2, `capacity_tokens=32768`, `generation=0`; recovered event `matched_prompt_tokens=27840`.
- Native before-detach backend allocation 23547833112 bytes. The actual disposal receipt reports **22355618584 bytes released** and 1192214528 bytes remaining. This is Metal/backend allocation accounting, NOT an RSS reduction.
- Stable in-process `RuntimeResources` identity `0x9fd9f0000`, Cache `0x9fd926300`, WriteBehind `0x9fd9280a0` across `before_detach`, `after_disposal` and final `after_recovery`. Owner authority is recorded at all three read points.
- Worker interval from native monotonic timestamps: `1794052936047288` to `1794052936099636` μs; 52.348 ms.
- Native RSS from archived `ps`: 1,054,832 KiB on Battery vs 2,573,104 KiB after AC recovery. These are not peak/full-residency measurements; native RSS was not sampled throughout warmup.
- Exactly one server-facing `Ready ·` announcement in `server.log`, a single native process generation and no restart. The archive does not contain an independent raw binary ReadyEvent count; that invariant is separately covered by the accepted native Bootstrap tests.

## Explicit gaps, without false PASS assertions

- Operator declined privileged `powermetrics`; only unprivileged `pmset` was captured. No `powermetrics` sensor reading exists.
- The 52.348 ms worker-disposal interval was shorter than the HTTP monitor period; no individual `/status` response is independently timestamped inside this interval. The existing deterministic native worker-blocking test covers control responsiveness during blocked worker activity but is **not** a physical observation in this session.
- Monitor's process-name filter also selected the Python parent PID 957. Therefore `transition-monitor.log` is useful for power/lifecycle timing but **must not be interpreted as a native RSS time series**. Native RSS values above come specifically from the separate `ps.battery.txt` and `ps.final.txt` process rows for PID 962.
- The detached `/status` retained byte fields are intentionally unavailable; retained identity is established by ownership-safe witness records, not zero-valued detached status counters.
- `/v1/models`, `/health` and `/metrics` responses were not independently archived during this run. Do not claim their per-phase HTTP codes from the status document.

## Raw evidence available

`status.initial-battery.json`, `status.ac.json`, `status.before-unplug.json`, `status.battery.json`, `status.recovered.final.json`, `request.warm32k.json`, `response.warm32k.json`, `response.recovered.json`, `warm32k-time.txt`, `recovered-time.txt`, `start-events.jsonl`, `residency-evidence.log`, `transition-monitor.log`, `power.*.txt`, `ps.battery.txt`, `ps.final.txt`, `server.log`, `macos.txt`, `build-hashes.txt`.

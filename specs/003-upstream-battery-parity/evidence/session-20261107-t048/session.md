# T048 physical session attempt — 2026-11-07

Status: INCOMPLETE. The 32K server launch inside the sandbox exited 1 because access to the installed model's `.install.lock` was denied. A request for host access to launch the same server was rejected. No native process was launched, no warm request or physical power transition was performed, and no 32K memory-plan admission was observed. The operator was instructed to keep AC connected. `server.log` contains the sandbox failure. Earlier evidence in `session-20261106` is unchanged.

The operator explicitly declined sudo and privileged commands; privileged powermetrics is unavailable by operator choice. No powermetrics sample is claimed. `pmset -g batt` observed AC power, 100% charged, before the attempted launch. macOS 26.7 (25G229).

Attempted command (with `SPLASH_RESIDENCY_EVIDENCE=1` and `SPLASH_START_EVIDENCE` pointing to this directory): `.venv/bin/python -m server.server "$HOME/Library/Application Support/Splash/models/.resolved/bddecda3abbdbfe69e0840a0452a50d5bbe750ca7f479a08b54bd7c38eeade73" --model ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF:IQ1_M --binary build/t015-corrected/splash --port 18974 --pause-on-battery --max-memory 24G --max-context 32K`.

Executable SHA256: `32b3a834c04d30827426b2e9cd6a5fd64d4254bda419a428d6cd511b84d292c7`. Metallib SHA256: `9ea41cdf5f0f767831d311a1d6ef7bac932d7a6f53f59a441dc733c74b44eacd`.

The affected native build exited 0. The updated runtime-bootstrap test exited 0 on the host Metal device; the separate sandbox-only attempt in `runtime-bootstrap.log` failed with `Metal device unavailable` and is not an acceptance result. There are no live residency, PID, HTTP, request or StartEvent measurements for this attempt. The physical criteria and T048 remain open.

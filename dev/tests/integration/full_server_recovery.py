"""Opt-in, sequential real-model recovery through the HTTP server.

Run only when no other model server is resident. The binary must be built with
SPLASH_INTEGRATION_TEST_POWER and live beside its production Metal libraries.
"""

import ctypes
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def child_exited(process):
    """Observe a child without releasing its PID (and hence its group ID)."""
    if process.returncode is not None:
        raise ChildProcessError("server leader was already reaped")
    if hasattr(os, "waitid"):
        info = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        return info is not None and info.si_code in (
            os.CLD_EXITED,
            os.CLD_KILLED,
            os.CLD_DUMPED,
        )

    # Python 3.12 on macOS does not expose waitid. Darwin's libc does; its
    # siginfo_t begins with signo, errno, code, pid (all int). The aligned
    # buffer is larger than Darwin's siginfo_t, including its reserved fields.
    if sys.platform != "darwin":
        raise RuntimeError("non-reaping waitid is unavailable")
    libc = ctypes.CDLL(None, use_errno=True)
    waitid = libc.waitid
    waitid.argtypes = (ctypes.c_int, ctypes.c_uint, ctypes.c_void_p, ctypes.c_int)
    waitid.restype = ctypes.c_int
    info = (ctypes.c_long * 32)()
    if waitid(1, process.pid, ctypes.byref(info), 0x04 | 0x01 | 0x20) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    fields = ctypes.cast(info, ctypes.POINTER(ctypes.c_int))
    return fields[3] == process.pid and fields[2] in (1, 2, 3)


def cleanup_server_group(process, grace_seconds=0.5, reap_seconds=5):
    """Signal the isolated group while its unreaped leader reserves its ID."""
    if process.pid == os.getpgrp():
        raise ValueError("refusing to signal the caller's process group")
    # ECHILD or an already-reaped Popen means the ID is no longer reserved.
    child_exited(process)
    group_absent = False
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        group_absent = True
    except PermissionError:
        if sys.platform != "darwin" or not child_exited(process):
            raise
        # Darwin returns EPERM for a zombie-only group. It can also mean
        # inaccessible members, so report the ambiguity instead of hiding it.
        print("server group SIGTERM returned EPERM", file=sys.stderr, flush=True)
    if not group_absent:
        # This is a test harness: half a second gives cooperative processes a
        # chance to stop without adding 30 seconds to every successful run.
        # The unreaped leader may keep the group visible even after all live
        # members exit, so only ESRCH proves early completion. In particular,
        # Darwin's zombie-only EPERM is ambiguous and must not stop escalation.
        deadline = time.monotonic() + grace_seconds
        group_absent = False
        while True:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                group_absent = True
                break
            except PermissionError:
                pass
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(0.05, remaining))
        if not group_absent:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError:
                if sys.platform != "darwin" or not child_exited(process):
                    raise
                print(
                    "server group SIGKILL returned EPERM", file=sys.stderr, flush=True
                )
    process.wait(timeout=reap_seconds)


def request(port, path, body=None, timeout=10):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def wait_for(label, predicate, process, seconds=900):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if child_exited(process):
            raise RuntimeError(f"server exited while waiting for {label}")
        try:
            result = predicate()
            if result:
                print(label, json.dumps(result), flush=True)
                return result
        except (OSError, ValueError):
            pass
        time.sleep(0.5)
    raise TimeoutError(label)


def main():
    # Explicit values: this test never selects or downloads a model.
    model = Path(os.environ["SPLASH_INTEGRATION_MODEL"])
    binary = Path(os.environ["SPLASH_INTEGRATION_BINARY"])
    model_id = os.environ["SPLASH_INTEGRATION_MODEL_ID"]
    log = Path(
        os.environ.get(
            "SPLASH_INTEGRATION_LOG", "/private/tmp/splash-full-recovery.log"
        )
    )
    with tempfile.TemporaryDirectory(prefix="splash-recovery-") as directory:
        power = Path(directory) / "power"
        power.write_text("ac")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env = dict(
            os.environ,
            SPLASH_TEST_POWER_FILE=str(power),
            SPLASH_RESIDENCY_EVIDENCE="1",
            PYTHONDONTWRITEBYTECODE="1",
        )
        command = [
            str(ROOT / ".venv/bin/python"),
            "-m",
            "server.server",
            str(model),
            "--model",
            model_id,
            "--binary",
            str(binary),
            "--port",
            str(port),
            "--max-memory",
            os.environ.get("SPLASH_INTEGRATION_MAX_MEMORY", "37795712204"),
            "--pause-on-battery",
            "--no-webui",
        ]
        start = time.monotonic()
        with log.open("w") as output:
            process = subprocess.Popen(
                command,
                cwd=ROOT,
                env=env,
                stdout=output,
                stderr=output,
                start_new_session=True,
            )
            print("command", json.dumps(command), "server_pid", process.pid, flush=True)
            try:
                wait_for(
                    "initial_ready", lambda: request(port, "/ready")[0] == 200, process
                )
                # A repeated ordinary phrase yields a large reusable prefix without storing user data.
                prompt = "The quick brown fox jumps over the lazy dog. " * 950
                body = {
                    "model": model_id,
                    "messages": [{"role": "user", "content": prompt}],
                    "max_tokens": 1,
                    "temperature": 0,
                }
                code, result = request(port, "/v1/chat/completions", body, timeout=900)
                print(
                    "initial_generation",
                    code,
                    json.dumps(
                        {
                            "usage": result.get("usage"),
                            "choices": len(result.get("choices", [])),
                        }
                    ),
                    flush=True,
                )
                if (
                    code != 200
                    or not result.get("choices")
                    or result.get("usage", {}).get("completion_tokens", 0) < 1
                ):
                    raise RuntimeError(f"initial generation failed: {code} {result}")
                power.write_text("battery")

                def suspended():
                    status, value = request(port, "/status")
                    lifecycle = value.get("lifecycle", {})
                    return (
                        lifecycle
                        if status == 200
                        and lifecycle.get("state") == "suspended"
                        and lifecycle.get("model_resident") is False
                        else None
                    )

                wait_for("suspended", suspended, process)
                power.write_text("ac")
                wait_for(
                    "recovered_ready",
                    lambda: request(port, "/ready")[0] == 200,
                    process,
                )
                evidence = log.read_text()
                before = re.search(
                    r"pid=(\d+) phase=before_detach .*?resource_graph_identity=(\S+)",
                    evidence,
                )
                after = re.search(
                    r"pid=(\d+) phase=after_recovery .*?resource_graph_identity=(\S+).*?admission_open=1",
                    evidence,
                )
                if not before or not after or before.groups() != after.groups():
                    raise RuntimeError(
                        "recovery did not retain native process and graph with admission open"
                    )
                print("native_pid_and_graph", before.groups(), flush=True)
                code, result = request(port, "/v1/chat/completions", body, timeout=900)
                print(
                    "recovered_generation",
                    code,
                    json.dumps(
                        {
                            "usage": result.get("usage"),
                            "choices": len(result.get("choices", [])),
                        }
                    ),
                    flush=True,
                )
                if (
                    code != 200
                    or not result.get("choices")
                    or result.get("usage", {}).get("completion_tokens", 0) < 1
                ):
                    raise RuntimeError(f"recovered generation failed: {code} {result}")
                cached = (
                    result.get("usage", {})
                    .get("prompt_tokens_details", {})
                    .get("cached_tokens", 0)
                )
                if cached <= 0:
                    raise RuntimeError(
                        "recovered generation did not reuse a cached prefix"
                    )
                evidence = log.read_text()
                if evidence.count("Ready ·") != 1:
                    raise RuntimeError(
                        "expected exactly one server readiness announcement"
                    )
                # The protocol treats a second ReadyEvent as fatal; successful
                # inference in the same native PID also verifies that invariant.

            finally:
                original_error = sys.exc_info()[0] is not None
                try:
                    cleanup_server_group(process)
                except Exception as error:
                    if not original_error:
                        raise
                    print(
                        f"server cleanup failed: {error}", file=sys.stderr, flush=True
                    )
                print(
                    "duration_seconds",
                    round(time.monotonic() - start, 3),
                    "server_exit",
                    process.returncode,
                    "log",
                    log,
                    flush=True,
                )


if __name__ == "__main__":
    main()

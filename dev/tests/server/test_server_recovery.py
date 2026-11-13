import base64
import concurrent.futures
import dataclasses
import http.client
import io
import json
import queue
import threading
import time
import unittest
from types import SimpleNamespace
from unittest import mock

from dev.tests import native_peer
from dev.tests.server_fixtures import (
    READY,
    FakeFactory,
    FakeRuntime,
    FakeTokenizer,
    HarnessTestCase,
    ImagePadTokenizer,
    Plan,
    chat_body,
    main_args,
    make_job,
    pdf_bytes,
    png_data_url,
    unprepared_hold,
)
from server import backend as backend_api
from server import protocol as wire
from server import runtime as engine_runtime
from server import server as api


def ready_status(correlation_id=1):
    return native_peer.status_event(
        correlation_id,
        configured_context_ceiling=READY.max_context_tokens,
        effective_context_tokens=READY.max_context_tokens,
        maximum_context_tokens=READY.max_context_tokens,
    )


def answer_status(process, message):
    if isinstance(message, wire.StatusRequestFrame):
        process.send(ready_status(message.correlation_id))


class RecoveringRuntime(FakeRuntime):
    """A serving engine the test fails. Each relaunch waits for the test to
    put its outcome: None for Ready, or the error the relaunch raises."""

    def __init__(self):
        super().__init__()
        self.status_event = ready_status()
        self.outcomes = queue.Queue()
        self.startup_calls = 0

    def fail(self, backend, error=None, served=1.0):
        self.ready = False
        backend._engine_failed(
            error or engine_runtime.EngineUnhealthy("native protocol reached EOF"),
            served,
        )

    def wait_ready(self, timeout=None):
        self.startup_calls += 1
        outcome = self.outcomes.get(timeout=3)
        if outcome is not None:
            raise outcome
        self.restart_count += 1
        self.ready = True
        return True

    def close(self):
        self.outcomes.put(engine_runtime.RuntimeClosed("runtime is closed"))
        super().close()


class ServerRecoveryTests(HarnessTestCase):
    @staticmethod
    def wait_until(predicate, timeout=1):
        deadline = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() >= deadline:
                raise AssertionError("test condition did not become true")
            time.sleep(0.005)

    def backend(self, runtime):
        backend = backend_api.NativeBackend(
            runtime, FakeTokenizer(), lambda _record: None
        )
        backend.configure_context_ceiling(
            READY.max_context_tokens, self._context_limit_updated
        )
        self.addCleanup(backend.close)
        return backend

    def _context_limit_updated(self, context):
        self.context_limit = context

    def relaunched(self, runtime, backend):
        runtime.outcomes.put(None)
        self.wait_until(lambda: backend.recovery is None and runtime.ready)

    @staticmethod
    def body():
        return {
            "model": "test-model",
            "messages": [{"role": "user", "content": "Say hi"}],
            "max_tokens": 4,
            "reasoning_effort": "none",
        }

    def test_battery_control_ready_http_recovers_on_ac_without_new_generation(self):
        def observation(revision, effective=None):
            snapshot = json.loads(native_peer.status_event().json)
            ready = effective is not None
            snapshot.update(
                ready=ready,
                control_ready=True,
                inference_ready=ready,
                model_resident=ready,
                configured_context_ceiling=READY.max_context_tokens,
                effective_context_tokens=effective,
                maximum_context_tokens=effective,
                lifecycle={
                    "power": "ac" if ready else "battery",
                    "state": "ready" if ready else "suspended",
                    "revision": revision,
                    "observation_sequence": revision,
                    "control_ready": True,
                    "inference_ready": ready,
                    "model_resident": ready,
                },
            )
            return wire.StatusJsonEvent(
                1, json.dumps(snapshot, separators=(",", ":")).encode()
            )

        class ObservedRuntime(FakeRuntime):
            def __init__(self):
                super().__init__()
                self.status_calls = 0
                self.wait_calls = 0
                self.identity = object()
                self.status_event = observation(1)

            def status(self, *args, **kwargs):
                self.status_calls += 1
                return super().status(*args, **kwargs)

            def wait_ready(self, timeout=None):
                self.wait_calls += 1
                return super().wait_ready(timeout)

        runtime = ObservedRuntime()
        admitted = Plan([[4]], block=True)
        runtime.plans.append(admitted)
        identity, witness = runtime.identity, runtime.readiness
        harness = self.harness(runtime, max_context=READY.max_context_tokens)
        frontend = harness.app

        def controls():
            for path in ("/health", "/status", "/metrics", "/v1/models"):
                self.assertEqual(harness.request("GET", path)[0], 200, path)

        def refresh(revision, effective):
            runtime.status_event = observation(revision, effective)
            with harness.backend.lock:
                harness.backend.status_refresh_after = 0
                harness.backend._queue_status_refresh_locked()
            self.wait_until(
                lambda: harness.backend.status_order == (revision, 1, revision), 2
            )

        controls()
        self.assertEqual(harness.request("GET", "/ready")[0], 503)
        self.assertEqual(
            harness.request("POST", "/v1/chat/completions", chat_body(max_tokens=4))[0],
            503,
        )
        self.assertEqual(runtime.requests, [])
        refresh(2, 72)
        self.assertEqual(harness.app.max_context, 72)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(
                harness.request, "POST", "/v1/chat/completions", chat_body(max_tokens=4)
            )
            try:
                self.assertTrue(admitted.started.wait(2))
                refresh(3, None)
                controls()
                self.assertEqual(harness.request("GET", "/ready")[0], 503)
                self.assertEqual(
                    harness.request(
                        "POST", "/v1/chat/completions", chat_body(max_tokens=4)
                    )[0],
                    503,
                )
                self.assertEqual(len(runtime.requests), 1)
            finally:
                admitted.release.set()
            self.assertEqual(pending.result(timeout=2)[0], 200)
        refresh(4, 64)
        self.assertIs(harness.app, frontend)
        self.assertEqual(harness.app.max_context, 64)
        self.assertEqual(harness.app._output_budget(None, [1] * 40, "max_tokens"), 24)
        model = json.loads(harness.request("GET", "/v1/models")[2])["data"][0]
        self.assertEqual(
            (model["max_model_len"], model["context_length"]),
            (READY.max_context_tokens,) * 2,
        )
        self.assertEqual(harness.request("GET", "/ready")[0], 200)
        self.assertTrue(runtime.ready)
        self.assertIs(runtime.identity, identity)
        self.assertIs(runtime.readiness, witness)
        self.assertEqual(runtime.restart_count, 0)
        self.assertEqual(runtime.wait_calls, 0)
        self.assertGreaterEqual(runtime.status_calls, 4)

    def test_cold_ready_vision_survives_ac_without_another_ready(self):
        for vision in (True, False):
            with self.subTest(vision=vision):
                runtime = FakeRuntime()
                runtime.readiness = wire.ReadyEvent(4, READY.max_context_tokens, vision)
                original = runtime.readiness
                snapshot = json.loads(native_peer.status_event().json)

                def observe(revision, ready):
                    snapshot.update(
                        ready=ready,
                        control_ready=True,
                        inference_ready=ready,
                        model_resident=ready,
                        configured_context_ceiling=READY.max_context_tokens,
                        effective_context_tokens=READY.max_context_tokens
                        if ready
                        else None,
                        maximum_context_tokens=READY.max_context_tokens
                        if ready
                        else None,
                        lifecycle={
                            "power": "ac" if ready else "battery",
                            "state": "ready" if ready else "suspended",
                            "revision": revision,
                            "observation_sequence": revision,
                            "control_ready": True,
                            "inference_ready": ready,
                            "model_resident": ready,
                        },
                    )
                    runtime.status_event = wire.StatusJsonEvent(
                        1, json.dumps(snapshot).encode()
                    )

                observe(1, False)
                harness = self.harness(
                    runtime,
                    tokenizer=ImagePadTokenizer(),
                    vision=original.vision,
                    max_context=READY.max_context_tokens,
                )
                self.assertEqual(harness.request("GET", "/ready")[0], 503)
                self.assertEqual(
                    harness.request("POST", "/v1/chat/completions", chat_body())[0], 503
                )
                self.assertEqual(runtime.requests, [])
                observe(2, True)
                with harness.backend.lock:
                    harness.backend.status_refresh_after = 0
                    harness.backend._queue_status_refresh_locked()
                self.wait_until(lambda: harness.backend.status_order == (2, 1, 2), 2)
                self.assertIs(runtime.readiness, original)
                model = json.loads(harness.request("GET", "/v1/models")[2])["data"][0]
                self.assertEqual(
                    model["input_modalities"],
                    ["text", "image", "pdf"] if vision else ["text"],
                )
                image = {"type": "image_url", "image_url": {"url": png_data_url()}}
                pdf = {
                    "type": "file",
                    "file": {
                        "filename": "a.pdf",
                        "file_data": "data:application/pdf;base64,"
                        + base64.b64encode(pdf_bytes()).decode(),
                    },
                }
                for part in (image, pdf):
                    status, _, payload = harness.request(
                        "POST",
                        "/v1/chat/completions",
                        chat_body(messages=[{"role": "user", "content": [part]}]),
                    )
                    if vision:
                        self.assertEqual(status, 200, payload)
                    else:
                        self.assertEqual(status, 400, payload)
                        self.assertIn(b"without vision", payload)

    def test_duplicate_ac_pending_snapshot_recovers_at_new_sequence(self):
        # [T034] The frontend half: the native pump re-consumes a duplicate AC
        # sample at the SAME lifecycle revision but a strictly newer observation
        # sequence, and only that newer order may replace the negative snapshot
        # the pending sample produced. Same-order authority stays strict.
        revision, sequence = 2, 5
        ceiling = READY.max_context_tokens

        def observation(sample, inference_ready):
            document = json.loads(native_peer.status_event().json)
            document.update(
                ready=inference_ready,
                control_ready=True,
                inference_ready=inference_ready,
                model_resident=True,
                configured_context_ceiling=ceiling,
                effective_context_tokens=ceiling if inference_ready else None,
                maximum_context_tokens=ceiling,
                lifecycle={
                    "power": "ac",
                    "state": "ready",
                    "revision": revision,
                    "observation_sequence": sample,
                    "model_resident": True,
                    "control_ready": True,
                    "inference_ready": inference_ready,
                    "last_error": "",
                },
            )
            return wire.StatusJsonEvent(
                1, json.dumps(document, separators=(",", ":")).encode()
            )

        class ObservedRuntime(FakeRuntime):
            def __init__(self):
                super().__init__()
                self.status_calls = 0
                self.identity = object()

            def status(self, *args, **kwargs):
                self.status_calls += 1
                return super().status(*args, **kwargs)

        runtime = ObservedRuntime()
        # The pump's Ready lifecycle with the duplicate AC still in the mailbox:
        # inference fails closed, the Engine and its context stay published.
        runtime.status_event = observation(sequence, False)
        harness = self.harness(runtime, max_context=ceiling)
        frontend, witness, identity = harness.app, runtime.readiness, runtime.identity

        def refresh(sample, inference_ready):
            runtime.status_event = observation(sample, inference_ready)
            with harness.backend.lock:
                harness.backend.status_refresh_after = 0
                harness.backend._queue_status_refresh_locked()

        self.assertEqual(harness.request("GET", "/ready")[0], 503)
        self.assertEqual(
            harness.request("POST", "/v1/chat/completions", chat_body(max_tokens=4))[0],
            503,
        )
        self.assertEqual(runtime.requests, [])
        refresh(sequence, False)
        self.wait_until(
            lambda: harness.backend.status_order == (revision, 1, sequence), 2
        )
        self.assertEqual(harness.request("GET", "/ready")[0], 503)
        self.assertEqual(runtime.restart_count, 0)
        self.assertIs(harness.app, frontend)
        self.assertIs(runtime.readiness, witness)

        # A contradictory Ready=true authority at the SAME order cannot replace
        # the cached negative one.
        runtime.status_event = observation(sequence, True)
        with harness.backend.lock:
            cached_ordinal = harness.backend.status_cached_ordinal
            self.assertFalse(
                harness.backend._cache_status(
                    json.loads(runtime.status_event.json),
                    runtime.restart_count,
                    cached_ordinal + 1,
                )
            )
            self.assertEqual(harness.backend.status_order, (revision, 1, sequence))
            self.assertIs(harness.backend.status_snapshot["inference_ready"], False)
            self.assertIsNone(harness.backend.status_confirmed_at)
        refresh(sequence, True)
        self.wait_until(lambda: harness.backend.status_confirmed_at is None, 2)
        self.assertEqual(harness.backend.status_order, (revision, 1, sequence))
        self.assertEqual(harness.request("GET", "/ready")[0], 503)
        self.assertEqual(runtime.requests, [])

        # The owner consumed the duplicate: same revision, one newer order.
        refresh(sequence + 1, True)
        self.wait_until(
            lambda: harness.backend.status_order == (revision, 1, sequence + 1), 2
        )
        self.assertEqual(harness.request("GET", "/ready")[0], 200)
        self.assertEqual(
            harness.request("POST", "/v1/chat/completions", chat_body(max_tokens=4))[0],
            200,
        )
        self.assertEqual(len(runtime.requests), 1)
        self.assertEqual(harness.app, frontend)
        self.assertEqual(harness.app.max_context, ceiling)
        self.assertIs(runtime.readiness, witness)
        self.assertIs(runtime.identity, identity)
        self.assertEqual(runtime.restart_count, 0)
        self.assertGreaterEqual(runtime.status_calls, 2)

    def test_invalid_resolved_context_fails_closed_without_fencing_generation(self):
        cases = (
            "missing",
            "null",
            "zero",
            "negative",
            "float",
            "string",
            "bool",
            "over ceiling",
            "ceiling mismatch",
            "missing ceiling",
            "missing maximum",
            "maximum mismatch",
            "readiness mismatch",
        )
        for case in cases:
            with self.subTest(case=case):
                runtime = FakeRuntime()
                with mock.patch.object(
                    runtime, "wait_ready", wraps=runtime.wait_ready
                ) as handshake:
                    harness = self.harness(runtime, max_context=128)
                    frontend = harness.app
                    witness = runtime.readiness
                    self.assertEqual(harness.request("GET", "/ready")[0], 200)
                    snapshot = json.loads(native_peer.status_event().json)
                    snapshot["lifecycle"].update(revision=2, observation_sequence=2)
                    field = "effective_context_tokens"
                    if case == "missing":
                        snapshot.pop(field)
                    elif case in (
                        "null",
                        "zero",
                        "negative",
                        "float",
                        "string",
                        "bool",
                        "over ceiling",
                    ):
                        snapshot[field] = {
                            "null": None,
                            "zero": 0,
                            "negative": -1,
                            "float": 1.5,
                            "string": "64",
                            "bool": True,
                            "over ceiling": 129,
                        }[case]
                    elif case == "ceiling mismatch":
                        snapshot["configured_context_ceiling"] = 127
                    elif case == "missing ceiling":
                        snapshot.pop("configured_context_ceiling")
                    elif case == "missing maximum":
                        snapshot.pop("maximum_context_tokens")
                    elif case == "maximum mismatch":
                        snapshot["maximum_context_tokens"] = 64
                    else:
                        snapshot["lifecycle"]["inference_ready"] = False

                    def publish(document, revision):
                        runtime.status_event = wire.StatusJsonEvent(
                            1, json.dumps(document, separators=(",", ":")).encode()
                        )
                        with harness.backend.lock:
                            harness.backend.status_refresh_after = 0
                            harness.backend._queue_status_refresh_locked()
                        self.wait_until(
                            lambda: (
                                harness.backend.status_order == (revision, 1, revision)
                            ),
                            2,
                        )

                    publish(snapshot, 2)
                    self.assertEqual(harness.request("GET", "/ready")[0], 503)
                    self.assertEqual(
                        harness.request(
                            "POST", "/v1/chat/completions", chat_body(max_tokens=4)
                        )[0],
                        503,
                    )
                    self.assertIsNone(frontend.max_context)
                    for path in ("/status", "/health", "/v1/models"):
                        self.assertEqual(harness.request("GET", path)[0], 200)
                    self.assertTrue(runtime.ready)
                    self.assertEqual(runtime.restart_count, 0)
                    valid = json.loads(native_peer.status_event().json)
                    valid.update(effective_context_tokens=64, maximum_context_tokens=64)
                    valid["lifecycle"].update(revision=3, observation_sequence=3)
                    publish(valid, 3)
                    self.assertIs(harness.app, frontend)
                    self.assertEqual(frontend.max_context, 64)
                    self.assertEqual(harness.request("GET", "/ready")[0], 200)
                    self.assertEqual(
                        harness.request(
                            "POST", "/v1/chat/completions", chat_body(max_tokens=4)
                        )[0],
                        200,
                    )
                    self.assertIs(runtime.readiness, witness)
                    self.assertEqual(runtime.restart_count, 0)
                    handshake.assert_not_called()

    def test_stale_positive_refuses_before_native_submit_and_refreshes(self):
        runtime = FakeRuntime()
        harness = self.harness(runtime, max_context=128)
        self.assertEqual(harness.request("GET", "/ready")[0], 200)
        with harness.backend.lock:
            harness.backend.status_confirmed_at -= (
                backend_api.STATUS_LIFECYCLE_FRESHNESS_SECONDS + 1
            )
        with (
            mock.patch.object(
                harness.backend, "_queue_status_refresh_locked"
            ) as scheduled,
            mock.patch.object(runtime, "submit", wraps=runtime.submit) as submit,
            mock.patch.object(harness.backend, "status", side_effect=TimeoutError),
        ):
            self.assertEqual(
                harness.request(
                    "POST", "/v1/chat/completions", chat_body(max_tokens=4)
                )[0],
                503,
            )
            submit.assert_not_called()
            scheduled.assert_called()
        self.assertTrue(runtime.ready)
        self.assertEqual(runtime.restart_count, 0)
        snapshot = json.loads(native_peer.status_event().json)
        snapshot["lifecycle"].update(revision=2, observation_sequence=2)
        runtime.status_event = wire.StatusJsonEvent(1, json.dumps(snapshot).encode())
        with harness.backend.lock:
            harness.backend.status_refresh_after = 0
            harness.backend._queue_status_refresh_locked()
        self.wait_until(lambda: harness.backend.status_order == (2, 1, 2), 2)
        self.assertEqual(
            harness.request("POST", "/v1/chat/completions", chat_body(max_tokens=4))[0],
            200,
        )
        self.assertEqual(runtime.restart_count, 0)

    def test_probes_share_one_relaunch_without_waiting_for_it(self):
        for first_path in ("/ready", "/status"):
            with self.subTest(first_path=first_path):
                runtime = RecoveringRuntime()
                harness = self.harness(runtime, max_context=READY.max_context_tokens)
                runtime.fail(harness.backend)
                started = time.monotonic()
                response = harness.request("GET", first_path)
                self.assertLess(time.monotonic() - started, 0.5)
                self.assertEqual(response[0], 503 if first_path == "/ready" else 200)
                with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                    probes = [
                        pool.submit(harness.request, "GET", "/status")
                        for _ in range(16)
                    ]
                    for probe in probes:
                        status, _, payload = probe.result(1)
                        self.assertEqual(status, 200)
                        snapshot = json.loads(payload)
                        self.assertFalse(snapshot["ready"])
                        self.assertTrue(snapshot["transport"]["recovering"])
                self.assertEqual(runtime.startup_calls, 1)
                self.relaunched(runtime, harness.backend)
                self.wait_until(lambda: harness.backend.refusal() is None)
                self.assertEqual(harness.request("GET", "/ready")[0], 200)
                snapshot = json.loads(harness.request("GET", "/status")[2])
                self.assertFalse(snapshot["transport"]["recovering"])
                self.assertEqual(runtime.startup_calls, 1)
                self.assertEqual(runtime.requests, [])

    def test_fast_failures_back_off_then_stop_restarting(self):
        runtime = RecoveringRuntime()
        harness = self.harness(runtime, max_context=READY.max_context_tokens)
        backend = harness.backend
        clock = [100.0]
        with (
            mock.patch.object(backend_api, "RESTART_BACKOFF_SECONDS", 0.01),
            mock.patch.object(
                backend_api, "time", SimpleNamespace(monotonic=lambda: clock[0])
            ),
            mock.patch.object(backend_api, "print_status") as console,
        ):
            for delay in (0.0, 0.01):
                runtime.fail(backend, served=1.0)
                self.assertAlmostEqual(backend.restart_due - clock[0], delay)
                self.relaunched(runtime, backend)
            runtime.fail(backend, served=1.0)
        self.assertEqual(runtime.startup_calls, 2)
        refusal = backend.refusal()
        self.assertEqual((refusal.status, refusal.code), (500, "engine_failed"))
        self.assertIn("failed 3 times in a row", refusal.message)
        self.assertRegex(refusal.message, "Crash trace|SPLASH_CRASH_TRACE")
        self.assertEqual(
            console.call_args_list[-1].args[0], f"Engine stopped · {refusal.message}"
        )
        self.assertEqual(harness.request("GET", "/ready")[0], 503)
        transport = json.loads(harness.request("GET", "/status")[2])["transport"]
        self.assertTrue(transport["stopped"])
        self.assertFalse(transport["recovering"])
        self.assertEqual(transport["error"], refusal.message)
        status, _, payload = harness.request(
            "POST", "/v1/chat/completions", self.body()
        )
        self.assertEqual(status, 500)
        self.assertEqual(json.loads(payload)["error"]["code"], "engine_failed")
        self.assertEqual(runtime.startup_calls, 2)

    def test_full_window_of_service_resets_the_crash_count(self):
        runtime = RecoveringRuntime()
        backend = self.backend(runtime)
        with mock.patch.object(backend_api, "print_status"):
            for _ in range(5):
                runtime.fail(backend, served=61.0)
                self.assertEqual(backend.failures, 1)
                self.assertLessEqual(backend.restart_due, time.monotonic())
                self.relaunched(runtime, backend)
        self.assertIsNone(backend.fatal_error)
        self.assertEqual(runtime.startup_calls, 5)

    def test_failure_during_inflight_refresh_restarts_at_once(self):
        runtime = RecoveringRuntime()
        backend = self.backend(runtime)
        refreshing = threading.Event()
        release = threading.Event()
        self.addCleanup(release.set)
        status = runtime.status

        def unanswered(timeout, fail_unanswered=False):
            if not fail_unanswered:
                raise TimeoutError("native status response timed out")
            refreshing.set()
            release.wait(2)
            return status(timeout)

        with (
            mock.patch.object(runtime, "status", side_effect=unanswered),
            mock.patch.object(backend_api, "print_status"),
        ):
            backend.status()
            self.assertTrue(refreshing.wait(1))
            runtime.fail(backend, served=120.0)
            release.set()
            self.wait_until(lambda: runtime.startup_calls == 1, 0.5)

    def test_failed_relaunch_counts_toward_the_crash_loop(self):
        runtime = RecoveringRuntime()
        for reason in ("a", "b"):
            runtime.outcomes.put(engine_runtime.EngineUnhealthy(reason))
        backend = self.backend(runtime)
        with (
            mock.patch.object(backend_api, "RESTART_BACKOFF_SECONDS", 0.01),
            mock.patch.object(backend_api, "print_status") as console,
        ):
            runtime.fail(backend, served=1.0)
            self.wait_until(lambda: backend.fatal_error is not None)
        self.assertEqual(runtime.startup_calls, 2)
        self.assertIn("failed 3 times in a row", backend.fatal_error)
        self.assertIn("(b)", backend.fatal_error)
        self.assertEqual(
            [call.args[0] for call in console.call_args_list],
            [
                "Engine failed · native protocol reached EOF",
                "Engine restart failed · a",
                "Engine restart failed · b",
                f"Engine stopped · {backend.fatal_error}",
            ],
        )

    def test_changed_ready_limits_stop_restarting_at_once(self):
        factory = FakeFactory(handler=answer_status)
        runtime = engine_runtime.MultiplexedRuntime(
            process_factory=factory, eager_start=True
        )
        backend = self.backend(runtime)
        factory.initial_output = native_peer.serialize_event(
            wire.ReadyEvent(4, 65_536, False)
        )
        with (
            mock.patch.object(runtime._crash_trace, "dump"),
            mock.patch.object(backend_api, "print_status"),
        ):
            factory.processes[0].kill()
            self.wait_until(lambda: backend.fatal_error is not None, 2)
        self.assertEqual(len(factory.processes), 2)
        # The runtime's error already says how to recover.
        self.assertEqual(
            backend.fatal_error,
            "native context window, concurrency or vision changed; "
            "restart the Splash server",
        )
        transport = backend.status()["transport"]
        self.assertTrue(transport["stopped"])
        self.assertFalse(transport["recovering"])
        self.assertEqual(transport["error"], backend.fatal_error)
        refusal = backend.refusal()
        self.assertEqual((refusal.status, refusal.code), (500, "engine_failed"))

    def test_relaunch_keeps_the_first_engines_context(self):
        # Without --max-context a relaunch is asked to keep the context the
        # first engine served, and one that does serves on. One that serves
        # another, as once the Mac's memory budget shrank, still stops the
        # restarts at once.
        args = main_args()
        first = tuple(api._native_command(args, args.model_root))
        relaunch = (*first, "--relaunch-context", str(READY.max_context_tokens))
        for relaunched, serves in (
            (READY, True),
            (dataclasses.replace(READY, max_context_tokens=65_536), False),
        ):
            with self.subTest(relaunched=relaunched):
                factory = FakeFactory(handler=answer_status)
                commands = []

                def spawn(command, factory=factory, commands=commands, **_options):
                    commands.append(command)
                    return factory()

                runtime = engine_runtime.MultiplexedRuntime(
                    first,
                    relaunch_command=lambda ready: api._native_command(
                        args, args.model_root, ready.max_context_tokens
                    ),
                )
                trace = mock.Mock(last_dump=None)
                with (
                    mock.patch.object(
                        engine_runtime.subprocess, "Popen", side_effect=spawn
                    ),
                    mock.patch.object(runtime, "_crash_trace", trace),
                    mock.patch.object(backend_api, "print_status"),
                ):
                    self.assertTrue(runtime.wait_ready(1))
                    backend = self.backend(runtime)
                    factory.initial_output = native_peer.serialize_event(relaunched)
                    factory.processes[0].kill()
                    self.wait_until(
                        lambda: (
                            backend.fatal_error is not None
                            or (
                                len(factory.processes) == 2
                                and runtime.ready
                                and backend.recovery is None
                            )
                        ),
                        2,
                    )
                self.assertEqual(commands, [first, relaunch])
                # A crash trace of the relaunch replays its own command.
                self.assertEqual(
                    [call.args[2] for call in trace.start_generation.call_args_list],
                    [first, relaunch],
                )
                if serves:
                    self.assertIsNone(backend.fatal_error)
                    self.assertIsNone(backend.refusal())
                    self.assertEqual(runtime.readiness, READY)
                else:
                    self.assertEqual(
                        backend.fatal_error,
                        "native context window, concurrency or vision changed; "
                        "restart the Splash server",
                    )
                    refusal = backend.refusal()
                    self.assertEqual(
                        (refusal.status, refusal.code), (500, "engine_failed")
                    )

    def test_stop_after_failed_relaunches_names_the_last_crash_trace(self):
        factory = FakeFactory()

        def launch():
            process = factory()
            if len(factory.processes) > 1:
                # Every relaunch fails before Ready.
                process.close_stdout()
            return process

        runtime = engine_runtime.MultiplexedRuntime(
            process_factory=launch, eager_start=True
        )
        factory.initial_output = b""
        trace = mock.Mock(last_dump=None)

        def dump(generation, _error, **_details):
            # A real trace is fsynced before it is named.
            time.sleep(0.05)
            trace.last_dump = f"/traces/g{generation}.json"

        trace.dump.side_effect = dump
        backend = self.backend(runtime)
        with (
            mock.patch.object(runtime, "_crash_trace", trace),
            mock.patch.object(backend_api, "RESTART_BACKOFF_SECONDS", 0.01),
            mock.patch.object(backend_api, "print_status"),
        ):
            factory.processes[0].kill()
            self.wait_until(lambda: backend.fatal_error is not None, 2)
        self.assertEqual(len(factory.processes), 3)
        self.assertIn("Crash trace: /traces/g3.json.", backend.fatal_error)

    def test_failure_right_after_a_relaunch_ready_is_counted_once(self):
        factory = FakeFactory()

        def launch():
            process = factory()
            if len(factory.processes) == 2:
                # The relaunched engine fails as soon as it is Ready.
                process.close_stdout()
            return process

        runtime = engine_runtime.MultiplexedRuntime(
            process_factory=launch, eager_start=True
        )
        backend = self.backend(runtime)
        relaunch = backend._relaunch
        relaunched = threading.Event()

        def relaunch_then_signal(due):
            relaunch(due)
            relaunched.set()

        dump = runtime._crash_trace.dump

        def dump_after_the_relaunch(generation, *args, **kwargs):
            # The listener hears of the relaunched engine's failure only
            # after the relaunch has seen its outcome.
            if generation == 2:
                relaunched.wait(1)
            return dump(generation, *args, **kwargs)

        with (
            mock.patch.object(backend, "_relaunch", side_effect=relaunch_then_signal),
            mock.patch.object(
                runtime._crash_trace, "dump", side_effect=dump_after_the_relaunch
            ),
            mock.patch.object(backend_api, "print_status") as console,
        ):
            factory.processes[0].kill()
            self.wait_until(lambda: console.call_count >= 2, 2)
        self.assertEqual(
            [call.args[0] for call in console.call_args_list],
            ["Engine failed · native protocol reached EOF"] * 2,
        )
        self.assertEqual(backend.failures, 2)
        self.assertIsNone(backend.fatal_error)

    def test_crash_that_stops_restarts_fails_its_request_without_retry(self):
        factory = FakeFactory(handler=answer_status)
        runtime = engine_runtime.MultiplexedRuntime(
            process_factory=factory, eager_start=True
        )
        backend = self.backend(runtime)
        job = make_job()
        with (
            mock.patch.object(backend_api, "RESTART_BACKOFF_SECONDS", 0.01),
            mock.patch.object(runtime._crash_trace, "dump"),
            mock.patch.object(backend_api, "print_status"),
        ):
            for launched in (2, 3):
                factory.processes[-1].kill()
                self.wait_until(
                    lambda: len(factory.processes) == launched and runtime.ready, 2
                )
            backend.submit(job)
            factory.processes[-1].stdin.wait_for(wire.RequestFrame)
            factory.processes[-1].close_stdout()
            kind, error = job.events.get(timeout=1)
        self.assertEqual(
            (kind, error.status, error.code), ("error", 500, "engine_failed")
        )
        self.assertIn("failed 3 times in a row", error.message)
        self.assertEqual(len(factory.processes), 3)

    def test_generation_recovery_rejects_before_body_or_ingress_and_advertises_retry(
        self,
    ):
        runtime = RecoveringRuntime()
        harness = self.harness(runtime, queue_size=1)
        runtime.fail(harness.backend)
        with mock.patch.object(harness.app, "prepare") as prepare:
            for path, status in (
                ("/v1/messages", 503),
                ("/v1/chat/completions", 503),
                ("/v1/responses", 503),
                # TypeSafe's overload status, which invites a retry as well.
                ("/v1/systemone", 529),
            ):
                with self.subTest(path=path):
                    connection = http.client.HTTPConnection(
                        *harness.server.server_address, timeout=1
                    )
                    try:
                        connection.putrequest("POST", path)
                        connection.putheader("Content-Type", "application/json")
                        connection.putheader("Content-Length", "100")
                        connection.endheaders()
                        response = connection.getresponse()
                        self.assertEqual(response.status, status)
                        self.assertEqual(response.getheader("Retry-After"), "1")
                        self.assertEqual(
                            json.loads(response.read())["error"]["type"],
                            "overloaded_error"
                            if path.startswith("/v1/messages")
                            else "server_error",
                        )
                    finally:
                        connection.close()
                    self.assertEqual(harness.server.requests.stats()["active"], 0)
                    self.assertEqual(runtime.pending_count, 0)
            prepare.assert_not_called()
        self.wait_until(lambda: runtime.startup_calls == 1)
        self.assertEqual(runtime.requests, [])
        for path, body in (
            ("/v1/messages/count_tokens", self.body()),
            ("/v1/chat/completions/count_tokens", chat_body()),
        ):
            with self.subTest(path=path):
                self.assertEqual(harness.request("POST", path, body)[0], 200)
        self.assertEqual(harness.request("GET", "/v1/models")[0], 200)

    def test_successful_probe_clears_unanswered_status_and_engine_error(self):
        runtime = RecoveringRuntime()
        backend = self.backend(runtime)
        with (
            mock.patch.object(runtime, "status", side_effect=TimeoutError),
            mock.patch.object(backend_api, "print_status"),
        ):
            runtime.fail(backend)
            # The relaunch succeeds; its status refresh is not answered.
            self.relaunched(runtime, backend)
            self.assertFalse(backend.status()["ready"])
            self.wait_until(lambda: backend.recovery is None)
        self.assertIsNotNone(backend.status_unanswered_since)
        self.assertEqual(backend.engine_error, "native protocol reached EOF")
        with mock.patch.object(backend_api, "print_status") as console:
            self.assertTrue(backend.status()["ready"])
        console.assert_called_once_with("Engine restarted")
        self.assertIsNone(backend.status_unanswered_since)
        self.assertIsNone(backend.engine_error)

    def test_token_count_remains_available_while_generation_slots_are_full(self):
        plan = Plan([[4]], block=True)
        runtime = FakeRuntime(plan)
        harness = self.harness(runtime, queue_size=1)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            generation = pool.submit(
                harness.request, "POST", "/v1/chat/completions", self.body()
            )
            try:
                self.assertTrue(plan.started.wait(1))
                self.assertEqual(harness.server.requests.stats()["active"], 1)
                for path, body in (
                    ("/v1/messages/count_tokens?beta=true", self.body()),
                    ("/v1/chat/completions/count_tokens", chat_body()),
                ):
                    with self.subTest(path=path):
                        status, _, payload = harness.request("POST", path, body)
                        self.assertEqual(status, 200)
                        self.assertEqual(json.loads(payload), {"input_tokens": 2})
                        self.assertEqual(len(runtime.requests), 1)
                        self.wait_until(
                            lambda: harness.server.token_counts.stats()["active"] == 0
                        )
                        self.assertEqual(harness.server.requests.stats()["active"], 1)
            finally:
                plan.release.set()
            self.assertEqual(generation.result(1)[0], 200)
        self.wait_until(lambda: harness.server.requests.stats()["active"] == 0)

    def test_systemone_overload_is_529_and_invites_a_retry(self):
        plan = Plan([[4]], block=True)
        harness = self.harness(FakeRuntime(plan), queue_size=1)
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            generation = pool.submit(
                harness.request, "POST", "/v1/chat/completions", self.body()
            )
            try:
                self.assertTrue(plan.started.wait(1))
                connection = http.client.HTTPConnection(
                    *harness.server.server_address, timeout=3
                )
                self.addCleanup(connection.close)
                connection.request(
                    "POST",
                    "/v1/systemone",
                    json.dumps(
                        {
                            "model": "test-model",
                            "state": "evidence",
                            "questions": {"supported": {"type": "noul"}},
                        }
                    ),
                    {"Content-Type": "application/json"},
                )
                response = connection.getresponse()
                self.assertEqual(response.status, 529)
                self.assertEqual(response.getheader("Retry-After"), "1")
                self.assertEqual(
                    json.loads(response.read())["error"]["code"],
                    "frontend_overloaded",
                )
            finally:
                plan.release.set()
            self.assertEqual(generation.result(1)[0], 200)

    def test_token_count_has_its_own_bounded_ingress_and_releases_on_disconnect(self):
        harness = self.harness(FakeRuntime(), queue_size=1)
        upload = http.client.HTTPConnection(*harness.server.server_address, timeout=1)
        try:
            upload.putrequest("POST", "/v1/messages/count_tokens")
            upload.putheader("Content-Type", "application/json")
            upload.putheader("Content-Length", "100")
            upload.endheaders()
            self.wait_until(lambda: harness.server.token_counts.stats()["active"] == 1)
            response = harness.request("POST", "/v1/messages/count_tokens", self.body())
            self.assertEqual(response[0], 503)
            self.assertEqual(
                json.loads(response[2])["error"]["type"], "overloaded_error"
            )
            self.assertEqual(
                harness.request("POST", "/v1/chat/completions", self.body())[0], 200
            )
            self.assertEqual(harness.request("GET", "/v1/models")[0], 200)
            snapshot = json.loads(harness.request("GET", "/status")[2])
            self.assertEqual(
                snapshot["http"]["token_counts"], {"active": 1, "capacity": 1}
            )
        finally:
            upload.close()
        self.wait_until(lambda: harness.server.token_counts.stats()["active"] == 0)
        self.assertEqual(
            harness.request("POST", "/v1/messages/count_tokens", self.body())[0], 200
        )

    def test_background_recovery_and_waiters_share_the_native_startup(self):
        factory = FakeFactory(handler=answer_status)
        runtime = engine_runtime.MultiplexedRuntime(
            process_factory=factory, eager_start=True
        )
        backend = self.backend(runtime)
        self.assertTrue(backend.status()["ready"])
        factory.initial_output = b""
        with mock.patch.object(backend_api, "print_status"):
            factory.processes[0].kill()
            self.wait_until(lambda: len(factory.processes) == 2)
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                waiters = [pool.submit(runtime.wait_ready, 1) for _ in range(4)]
                for _ in range(10):
                    self.assertEqual(backend.refusal().code, "engine_recovering")
                self.assertEqual(len(factory.processes), 2)
                factory.processes[1].send(READY)
                for waiter in waiters:
                    self.assertTrue(waiter.result(1))
            self.wait_until(lambda: backend.recovery is None)
        self.assertTrue(backend.status()["ready"])
        self.assertEqual(runtime.pending_count, 0)
        self.assertEqual(factory.processes[1].stdin.messages(wire.RequestFrame), [])

    def test_idle_engine_death_restarts_before_traffic_arrives(self):
        factory = FakeFactory(handler=answer_status)
        runtime = engine_runtime.MultiplexedRuntime(
            process_factory=factory, eager_start=True
        )
        backend = self.backend(runtime)
        factory.processes[0].kill()
        self.wait_until(lambda: len(factory.processes) == 2 and runtime.ready, 2)
        self.assertEqual(runtime.restart_count, 1)
        self.wait_until(lambda: backend.refusal() is None)

    def test_idle_engine_that_stops_answering_status_is_restarted(self):
        def answer_after_the_first(process, message):
            if process is not factory.processes[0]:
                answer_status(process, message)

        factory = FakeFactory(handler=answer_after_the_first)
        runtime = engine_runtime.MultiplexedRuntime(
            process_factory=factory, eager_start=True
        )
        backend = self.backend(runtime)
        with (
            mock.patch.object(engine_runtime, "STATUS_ANSWER_LIMIT_SECONDS", 0.05),
            mock.patch.object(backend_api, "print_status") as console,
        ):
            # The probe's timeout owes a refresh, which goes unanswered too.
            self.assertFalse(backend.status()["ready"])
            self.wait_until(lambda: len(factory.processes) == 2 and runtime.ready, 2)
            self.wait_until(lambda: backend.recovery is None)
        self.assertEqual(
            console.call_args_list[0].args[0],
            "Engine failed · native loop did not answer status within 0.05 s",
        )
        self.assertEqual(runtime.pending_count, 0)
        self.assertTrue(backend.status()["ready"])

    def test_engine_failure_and_failed_restart_are_reported(self):
        factory = FakeFactory()

        def launch():
            if factory.processes:
                raise FileNotFoundError("splash")
            return factory()

        runtime = engine_runtime.MultiplexedRuntime(
            process_factory=launch, eager_start=True
        )
        backend = self.backend(runtime)
        with mock.patch.object(backend_api, "print_status") as console:
            factory.processes[0].kill()
            self.wait_until(lambda: console.call_count >= 2)
            transport = backend.status()["transport"]
        failed, restart = (call.args[0] for call in console.call_args_list[:2])
        self.assertEqual(failed, "Engine failed · native protocol reached EOF")
        self.assertRegex(
            restart, "^Engine restart failed · native engine executable is missing"
        )
        self.assertTrue(transport["recovering"])
        self.assertIn("executable is missing", transport["error"])

    def test_failed_restarts_end_in_one_stop_line(self):
        factory = FakeFactory()

        def launch():
            if factory.processes:
                raise FileNotFoundError("splash")
            return factory()

        runtime = engine_runtime.MultiplexedRuntime(
            process_factory=launch, eager_start=True
        )
        backend = self.backend(runtime)
        with (
            mock.patch.object(backend_api, "RESTART_BACKOFF_SECONDS", 0.01),
            mock.patch.object(backend_api, "print_status") as console,
        ):
            factory.processes[0].kill()
            self.wait_until(lambda: console.call_count >= 4)
        lines = [call.args[0] for call in console.call_args_list]
        self.assertEqual(len(lines), 4)
        self.assertEqual(lines[0], "Engine failed · native protocol reached EOF")
        for line in lines[1:3]:
            self.assertRegex(
                line, "^Engine restart failed · native engine executable is missing"
            )
        self.assertEqual(lines[3], f"Engine stopped · {backend.fatal_error}")
        transport = backend.status()["transport"]
        self.assertTrue(transport["stopped"])
        self.assertFalse(transport["recovering"])

    def test_engine_failure_under_a_request_asks_its_client_to_retry(self):
        # The engine stops, or breaks the protocol; either way it fails, and
        # its requests with it.
        protocol_failure = wire.ErrorEvent(
            wire.FailureClass.PROTOCOL_FATAL,
            0,
            False,
            b"invalid_request_id",
            b"request id is already active",
        )
        for fail, reason in (
            (
                lambda process: process.close_stdout(),
                "native protocol reached EOF",
            ),
            (
                lambda process: process.send(protocol_failure),
                "request id is already active",
            ),
        ):
            with self.subTest(reason=reason):
                factory = FakeFactory()
                runtime = engine_runtime.MultiplexedRuntime(
                    process_factory=factory, eager_start=True
                )
                backend = self.backend(runtime)
                job = make_job()
                with mock.patch.object(backend_api, "print_status") as console:
                    backend.submit(job)
                    factory.processes[0].stdin.wait_for(wire.RequestFrame)
                    fail(factory.processes[0])
                    kind, error = job.events.get(timeout=1)
                    self.wait_until(lambda: console.called)
                self.assertEqual(kind, "error")
                self.assertEqual(
                    (error.status, error.code, error.message),
                    (
                        503,
                        "runtime_unavailable",
                        "the inference engine stopped unexpectedly and is "
                        "restarting; retry the request",
                    ),
                )
                # The engine's own reason stays on the console.
                self.assertEqual(
                    console.call_args_list[0].args[0], f"Engine failed · {reason}"
                )

    def test_recovery_refusals_carry_the_last_engine_failure(self):
        runtime = RecoveringRuntime()
        runtime.outcomes.put(engine_runtime.EngineUnhealthy("GPU is gone"))
        harness = self.harness(runtime, max_context=READY.max_context_tokens)
        with (
            mock.patch.object(backend_api, "RESTART_BACKOFF_SECONDS", 0.01),
            mock.patch.object(backend_api, "print_status") as console,
        ):
            runtime.fail(harness.backend)
            # The second relaunch waits for its outcome.
            self.wait_until(lambda: runtime.startup_calls == 2)
            console.assert_called_with(
                "Engine restart failed · GPU is gone", error=True
            )
            status, _, payload = harness.request(
                "POST", "/v1/chat/completions", self.body()
            )
            self.assertEqual(status, 503)
            self.assertEqual(
                json.loads(payload)["error"]["message"],
                "engine is recovering; retry shortly (last failure: GPU is gone)",
            )
            transport = json.loads(harness.request("GET", "/status")[2])["transport"]
            self.assertEqual(transport["error"], "GPU is gone")
            self.relaunched(runtime, harness.backend)
            self.wait_until(lambda: harness.backend.refusal() is None)
            self.assertIsNone(harness.backend.refusal())
            console.assert_called_with("Engine restarted")
            transport = json.loads(harness.request("GET", "/status")[2])["transport"]
            self.assertNotIn("error", transport)

    def test_startup_failure_ends_with_one_error_line(self):
        # A broken stream, and an engine that says why its start failed.
        refusal = (
            "--max-context 1000000 exceeds the 790521 tokens the model and "
            "this Mac's memory allow; omit it or pass at most 790521"
        )
        runtime_type = engine_runtime.MultiplexedRuntime
        for initial_output, reason in (
            (
                b"not a frame".ljust(wire.FRAME_HEADER_BYTES, b"\0"),
                "protocol_fatal:bad_magic",
            ),
            (
                native_peer.serialize_event(
                    wire.ErrorEvent(
                        wire.FailureClass.ENGINE_UNHEALTHY,
                        0,
                        False,
                        b"bootstrap_failed",
                        refusal.encode(),
                    )
                ),
                refusal,
            ),
        ):
            with self.subTest(reason=reason):
                factory = FakeFactory(initial_output=initial_output)
                with (
                    mock.patch.object(api, "parse_args", return_value=main_args()),
                    unprepared_hold(),
                    mock.patch.object(api, "load_thinking_key", return_value=None),
                    mock.patch.object(
                        api.AutoTokenizer, "from_pretrained", return_value=object()
                    ),
                    mock.patch.object(api, "validate_tokenizer"),
                    mock.patch.object(api, "ChatTemplates"),
                    mock.patch.object(
                        api.engine_runtime,
                        "MultiplexedRuntime",
                        side_effect=lambda _command, **options: runtime_type(
                            process_factory=factory, **options
                        ),
                    ),
                    mock.patch.object(api, "FrontendServer"),
                    mock.patch.object(api.signal, "signal"),
                    mock.patch("sys.stdout", new_callable=io.StringIO),
                    mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
                    self.assertRaisesRegex(SystemExit, "1"),
                ):
                    api.main()
                (line,) = stderr.getvalue().splitlines()
                self.assertIn(f"Error · {reason}", line)
                self.assertNotIn("reached EOF", line)
                self.assertIsNotNone(factory.processes[0].poll())

    def test_restarted_native_must_match_the_original_ready_event(self):
        for restarted in (
            READY,
            dataclasses.replace(READY, max_context_tokens=65536),
            dataclasses.replace(READY, max_concurrent_requests=1),
            dataclasses.replace(READY, vision=True),
        ):
            with self.subTest(restarted=restarted):
                factory = FakeFactory()
                runtime = engine_runtime.MultiplexedRuntime(
                    process_factory=factory, eager_start=True
                )
                try:
                    self.assertEqual(runtime.readiness.max_context_tokens, 131072)
                    with mock.patch.object(runtime._crash_trace, "dump"):
                        factory.processes[0].kill()
                        self.wait_until(lambda: not runtime.ready)
                        factory.initial_output = native_peer.serialize_event(restarted)
                        if restarted is READY:
                            self.assertTrue(runtime.wait_ready(1))
                        else:
                            # The difference would recur on every relaunch.
                            for _ in range(2):
                                with self.assertRaisesRegex(
                                    engine_runtime.EngineUnhealthy,
                                    "restart the Splash server",
                                ):
                                    runtime.wait_ready(1)
                            self.assertFalse(runtime.ready)
                    self.assertEqual(runtime.pending_count, 0)
                    self.assertEqual(len(factory.processes), 2)
                    self.assertEqual(
                        factory.processes[1].stdin.messages(wire.RequestFrame), []
                    )
                finally:
                    runtime.close()


if __name__ == "__main__":
    unittest.main()

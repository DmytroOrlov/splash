import concurrent.futures
import dataclasses
import http.client
import io
import json
import threading
import time
import unittest
from types import SimpleNamespace
from unittest import mock

from dev.tests.engine.test_native_backend import FakeTokenizer as NativeTokenizer
from dev.tests.engine.test_native_backend import make_job
from dev.tests.engine.test_runtime import READY_FEATURES, FakeFactory
from dev.tests.test_server import FakeRuntime, Harness, Plan, main_args
from install import launcher
from server import backend as backend_api
from server import protocol as wire
from server import runtime as engine_runtime
from server import server as api


_MISSING = object()


class RecoveringRuntime(FakeRuntime):
    def __init__(self, failures=()):
        super().__init__()
        self.ready = False
        self.failures = list(failures)
        self.startup_calls = 0
        self.startup_entered = threading.Event()
        self.startup_release = threading.Event()

    def wait_ready(self):
        self.startup_calls += 1
        self.startup_entered.set()
        if not self.startup_release.wait(3):
            raise TimeoutError("test did not release startup")
        if self.failures:
            raise self.failures.pop(0)
        self.ready = True
        return True

    def status(self, timeout=5):
        if not self.ready:
            raise engine_runtime.EngineUnhealthy("native process is not ready")
        return super().status(timeout)

    def close(self):
        self.startup_release.set()
        super().close()


class LifecycleRuntime(FakeRuntime):
    """Control-ready process with replaceable detached lifecycle snapshots."""

    def __init__(self, *, inference_ready=False, effective_context_tokens=None):
        super().__init__()
        self.generation = object()
        self.process = object()
        self.readiness = SimpleNamespace(max_context_tokens=128)
        self.ready_event_count = 1
        self.wait_ready_calls = 0
        self.status_calls = 0
        self.publish_status(
            inference_ready=inference_ready,
            effective_context_tokens=effective_context_tokens,
        )

    def publish_status(
        self,
        *,
        inference_ready,
        effective_context_tokens=_MISSING,
        lifecycle_inference_ready=_MISSING,
        configured_context_ceiling=128,
        maximum_context_tokens=_MISSING,
        lifecycle_revision=0,
    ):
        snapshot = {
            "schema_version": wire.STATUS_SCHEMA_VERSION,
            "ready": inference_ready,
            "control_ready": True,
            "inference_ready": inference_ready,
            "memory_pressure": "normal",
            "metal": {"healthy": True},
            "configured_context_ceiling": configured_context_ceiling,
            "lifecycle": {
                "state": "ready" if inference_ready else "suspended",
                "revision": lifecycle_revision,
                "model_resident": inference_ready,
                "control_ready": True,
                "inference_ready": (
                    inference_ready
                    if lifecycle_inference_ready is _MISSING
                    else lifecycle_inference_ready
                ),
            },
        }
        if effective_context_tokens is not _MISSING:
            snapshot["effective_context_tokens"] = effective_context_tokens
        if maximum_context_tokens is _MISSING:
            maximum_context_tokens = (
                effective_context_tokens if inference_ready else 128
            )
        if maximum_context_tokens is not _MISSING:
            snapshot["maximum_context_tokens"] = maximum_context_tokens
        self.status_event = wire.StatusJsonEvent(
            1,
            wire.STATUS_SCHEMA_VERSION,
            json.dumps(snapshot, separators=(",", ":")).encode(),
        )

    def wait_ready(self):
        self.wait_ready_calls += 1
        self.ready = True
        return True

    def status(self, timeout=5.0):
        self.status_calls += 1
        return super().status(timeout)


class ServerRecoveryTests(unittest.TestCase):
    @staticmethod
    def wait_until(predicate, timeout=1):
        deadline = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() >= deadline:
                raise AssertionError("test condition did not become true")
            time.sleep(0.005)

    def harness(self, runtime, **kwargs):
        harness = Harness(runtime, **kwargs)

        def close():
            if isinstance(runtime, RecoveringRuntime):
                runtime.startup_release.set()
            harness.close()

        self.addCleanup(close)
        return harness

    @staticmethod
    def body():
        return {
            "model": "test-model",
            "messages": [{"role": "user", "content": "Say hi"}],
            "max_tokens": 4,
            "reasoning_effort": "none",
        }

    def test_inference_readiness_controls_admission_independent_of_process_ready(self):
        runtime = FakeRuntime()
        backend = backend_api.NativeBackend(runtime, NativeTokenizer())
        self.addCleanup(backend.close)

        for inference_ready in (False, True, False):
            with self.subTest(inference_ready=inference_ready):
                snapshot = json.loads(runtime.status_event.json)
                snapshot["ready"] = inference_ready
                snapshot["inference_ready"] = inference_ready
                snapshot["control_ready"] = True
                runtime.status_event = wire.StatusJsonEvent(
                    runtime.status_event.correlation_id,
                    wire.STATUS_SCHEMA_VERSION,
                    json.dumps(snapshot).encode(),
                )
                backend.status()
                self.assertTrue(runtime.ready)
                self.assertEqual(backend.can_submit(), inference_ready)
                self.assertEqual(backend.is_ready(), inference_ready)
                self.assertTrue(runtime.ready)
                self.assertEqual(runtime.restart_count, 0)
                self.assertEqual(runtime.requests, [])

        snapshot = json.loads(runtime.status_event.json)
        snapshot["inference_ready"] = True
        snapshot["ready"] = True
        snapshot["memory_pressure"] = "critical"
        runtime.status_event = wire.StatusJsonEvent(
            runtime.status_event.correlation_id,
            wire.STATUS_SCHEMA_VERSION,
            json.dumps(snapshot).encode(),
        )
        backend.status()
        self.assertTrue(backend.can_submit())
        self.assertFalse(backend.is_ready())

    def test_suspended_status_is_passively_refreshed_to_ac_without_status_polling(self):
        class CountingRuntime(FakeRuntime):
            def __init__(self):
                super().__init__()
                self.status_calls = 0

            def status(self, timeout=5.0):
                self.status_calls += 1
                return super().status(timeout)

        runtime = CountingRuntime()
        initial = json.loads(runtime.status_event.json)
        initial["ready"] = False
        initial["inference_ready"] = False
        initial["memory_pressure"] = "normal"
        runtime.status_event = wire.StatusJsonEvent(
            1, wire.STATUS_SCHEMA_VERSION, json.dumps(initial).encode()
        )
        backend = backend_api.NativeBackend(runtime, NativeTokenizer())
        self.addCleanup(backend.close)
        clock = [100.0]
        with mock.patch.object(
            backend_api, "time", SimpleNamespace(monotonic=lambda: clock[0])
        ):
            backend.status()  # one initial sample; later checks use the cache
            self.assertFalse(backend.can_submit())
            for _ in range(10):
                self.assertFalse(backend.can_submit())
            self.assertEqual(runtime.status_calls, 1)

            recovered = json.loads(runtime.status_event.json)
            recovered["ready"] = True
            recovered["inference_ready"] = True
            runtime.status_event = wire.StatusJsonEvent(
                2, wire.STATUS_SCHEMA_VERSION, json.dumps(recovered).encode()
            )
            clock[0] += backend_api.STATUS_LIFECYCLE_FRESHNESS_SECONDS
            self.assertFalse(backend.is_ready())
            self.wait_until(lambda: not backend.status_refresh_inflight)
            self.assertTrue(backend.is_ready())
            self.assertEqual(runtime.status_calls, 2)
            self.assertTrue(runtime.ready)
            self.assertEqual(runtime.restart_count, 0)
            self.assertEqual(runtime.requests, [])

    def test_first_effective_context_is_adopted_by_bounded_passive_refresh(self):
        runtime = LifecycleRuntime()
        harness = self.harness(runtime, max_context=128)
        app = harness.app
        backend = harness.backend

        # The first ordinary inference attempt obtains the model-less status
        # snapshot and is refused. No /status call is needed to start refresh.
        status, _, _ = harness.request(
            "POST", "/v1/chat/completions", self.body()
        )
        self.assertEqual(status, 503)
        self.assertEqual(runtime.status_calls, 1)
        self.assertEqual(app.max_context, 128)
        self.assertEqual(runtime.requests, [])

        runtime.publish_status(
            inference_ready=True,
            effective_context_tokens=72,
        )
        with backend.lock:
            backend.status_snapshot_at -= (
                backend_api.STATUS_LIFECYCLE_FRESHNESS_SECONDS + 0.01
            )
            backend.status_refresh_after = 0.0

        # This second request triggers the existing background status refresh,
        # but is still refused using the old false snapshot it already read.
        status, _, _ = harness.request(
            "POST", "/v1/chat/completions", self.body()
        )
        self.assertEqual(status, 503)
        refresh = backend.status_refresh_thread
        if refresh is not None:
            refresh.join(1)
            self.assertFalse(refresh.is_alive())
        self.assertEqual(runtime.status_calls, 2)
        self.assertEqual(app.max_context, 72)
        self.assertEqual(runtime.requests, [])
        self.assertTrue(runtime.ready)
        self.assertEqual(runtime.restart_count, 0)
        self.assertEqual(runtime.wait_ready_calls, 0)

        # The validated value is the request-preparation limit, not the
        # static ReadyEvent ceiling.
        with mock.patch.object(
            type(harness.tokenizer),
            "__call__",
            return_value={"input_ids": [101] * 72},
        ):
            status, _, payload = harness.request(
                "POST", "/v1/chat/completions", self.body()
            )
        self.assertEqual(status, 400)
        self.assertEqual(
            json.loads(payload)["error"]["code"], "context_length_exceeded"
        )
        self.assertEqual(runtime.requests, [])
        self.assertEqual(
            harness.request("POST", "/v1/chat/completions", self.body())[0], 200
        )
        self.assertEqual(len(runtime.requests), 1)
        self.assertIs(harness.app, app)
        self.assertIs(harness.backend.runtime, runtime)

    def test_battery_control_ready_http_recovers_on_ac_without_new_generation(self):
        runtime = LifecycleRuntime()
        harness = self.harness(runtime, max_context=128)
        app = harness.app
        backend = harness.backend
        process = runtime.process
        generation = runtime.generation
        readiness = runtime.readiness

        # A Battery-started child is control-ready and has one static
        # capability handshake, while all inference surfaces remain closed.
        self.assertTrue(runtime.ready)
        self.assertFalse(backend.can_submit())
        self.assertEqual(app.max_context, 128)
        self.assertEqual(runtime.ready_event_count, 1)
        for method, path in (
            ("GET", "/health"),
            ("GET", "/ready"),
            ("GET", "/status"),
            ("GET", "/metrics"),
            ("GET", "/v1/models"),
        ):
            with self.subTest(path=path):
                status, _, payload = harness.request(method, path)
                self.assertEqual(status, 503 if path == "/ready" else 200)
                if path == "/status":
                    snapshot = json.loads(payload)
                    self.assertTrue(snapshot["control_ready"])
                    self.assertFalse(snapshot["inference_ready"])
                if path == "/v1/models":
                    self.assertEqual(
                        json.loads(payload)["data"][0]["context_length"], 128
                    )
                self.assertTrue(runtime.ready)
                self.assertEqual(runtime.restart_count, 0)
                self.assertEqual(runtime.wait_ready_calls, 0)
                self.assertEqual(runtime.ready_event_count, 1)
                self.assertEqual(runtime.requests, [])
                self.assertIs(harness.backend.runtime, runtime)

        status, _, _ = harness.request(
            "POST", "/v1/chat/completions", self.body()
        )
        self.assertEqual(status, 503)
        self.assertEqual(runtime.requests, [])

        refresh = backend.status_refresh_thread
        if refresh is not None:
            refresh.join(1)
            self.assertFalse(refresh.is_alive())

        # AC completion changes only detached status in this generation. The
        # normal bounded refresh discovers the actual context before inference
        # is admitted by Python.
        runtime.publish_status(
            inference_ready=True,
            effective_context_tokens=72,
            lifecycle_revision=1,
        )
        with backend.lock:
            backend.status_snapshot_at -= (
                backend_api.STATUS_LIFECYCLE_FRESHNESS_SECONDS + 0.01
            )
            backend.status_refresh_after = 0.0
        self.assertEqual(harness.request("GET", "/ready")[0], 503)
        refresh = backend.status_refresh_thread
        if refresh is not None:
            refresh.join(1)
            self.assertFalse(refresh.is_alive())
        self.assertEqual(app.max_context, 72)
        self.assertEqual(harness.request("GET", "/ready")[0], 200)
        self.assertEqual(
            harness.request("POST", "/v1/chat/completions", self.body())[0], 200
        )
        self.assertEqual(app.max_context, 72)
        self.assertIs(harness.app, app)
        self.assertIs(harness.backend.runtime, runtime)
        self.assertIs(runtime.process, process)
        self.assertIs(runtime.generation, generation)
        self.assertIs(runtime.readiness, readiness)
        self.assertEqual(runtime.ready_event_count, 1)
        self.assertEqual(runtime.wait_ready_calls, 0)
        self.assertEqual(runtime.restart_count, 0)

        # The same control-ready child can close inference again on Battery.
        # Let the existing bounded status refresh consume the new snapshot.
        requests_before_battery = len(runtime.requests)
        runtime.publish_status(
            inference_ready=False,
            effective_context_tokens=None,
            lifecycle_revision=2,
        )
        with backend.lock:
            backend.status_snapshot_at -= (
                backend_api.STATUS_LIFECYCLE_FRESHNESS_SECONDS + 0.01
            )
            backend.status_refresh_after = 0.0
        harness.request("GET", "/ready")
        refresh = backend.status_refresh_thread
        if refresh is not None:
            refresh.join(1)
            self.assertFalse(refresh.is_alive())

        self.assertEqual(harness.request("GET", "/ready")[0], 503)
        self.assertEqual(
            harness.request("POST", "/v1/chat/completions", self.body())[0],
            503,
        )
        self.assertEqual(len(runtime.requests), requests_before_battery)
        self.assertIs(harness.app, app)
        self.assertIs(harness.backend, backend)
        self.assertIs(backend.runtime, runtime)
        self.assertIs(runtime.process, process)
        self.assertIs(runtime.generation, generation)
        self.assertIs(runtime.readiness, readiness)
        self.assertEqual(runtime.ready_event_count, 1)
        self.assertEqual(runtime.restart_count, 0)
        self.assertEqual(runtime.wait_ready_calls, 0)

        # AC is discovered through the same bounded freshness cache. The
        # configured /v1/models ceiling stays static while serving context
        # follows the newly resolved value on this existing Frontend.
        runtime.publish_status(
            inference_ready=True,
            effective_context_tokens=64,
            lifecycle_revision=3,
        )
        with backend.lock:
            backend.status_snapshot_at -= (
                backend_api.STATUS_LIFECYCLE_FRESHNESS_SECONDS + 0.01
            )
            backend.status_refresh_after = 0.0
        harness.request("GET", "/ready")
        refresh = backend.status_refresh_thread
        if refresh is not None:
            refresh.join(1)
            self.assertFalse(refresh.is_alive())

        self.assertEqual(app.max_context, 64)
        self.assertEqual(harness.request("GET", "/ready")[0], 200)
        self.assertEqual(
            harness.request("POST", "/v1/chat/completions", self.body())[0],
            200,
        )
        models_status, _, models_payload = harness.request("GET", "/v1/models")
        self.assertEqual(models_status, 200)
        self.assertEqual(
            json.loads(models_payload)["data"][0]["context_length"], 128
        )
        self.assertEqual(app.max_context, 64)
        self.assertIs(harness.app, app)
        self.assertIs(harness.backend, backend)
        self.assertIs(backend.runtime, runtime)
        self.assertIs(runtime.process, process)
        self.assertIs(runtime.generation, generation)
        self.assertIs(runtime.readiness, readiness)
        self.assertEqual(runtime.ready_event_count, 1)
        self.assertEqual(runtime.restart_count, 0)
        self.assertEqual(runtime.wait_ready_calls, 0)

    def test_same_generation_recovery_updates_context_without_new_handshake(self):
        runtime = LifecycleRuntime(
            inference_ready=True,
            effective_context_tokens=72,
        )
        harness = self.harness(runtime, max_context=128)
        app = harness.app
        backend = harness.backend
        process = runtime.process
        generation = runtime.generation
        readiness = runtime.readiness

        status, _, _ = harness.request(
            "POST", "/v1/chat/completions", self.body()
        )
        self.assertEqual(status, 200)
        self.assertEqual(app.max_context, 72)
        self.assertEqual(len(runtime.requests), 1)

        # A later recovery in the same child reports a new memory-planned
        # context. A bounded refresh updates the existing Frontend in place.
        runtime.publish_status(
            inference_ready=True,
            effective_context_tokens=48,
        )
        with backend.lock:
            backend.status_snapshot_at -= (
                backend_api.STATUS_LIFECYCLE_FRESHNESS_SECONDS + 0.01
            )
            backend.status_refresh_after = 0.0
        status, _, _ = harness.request("GET", "/ready")
        self.assertEqual(status, 503)
        refresh = backend.status_refresh_thread
        if refresh is not None:
            refresh.join(1)
            self.assertFalse(refresh.is_alive())

        self.assertEqual(app.max_context, 48)
        self.assertIs(harness.app, app)
        self.assertIs(harness.backend.runtime, runtime)
        self.assertIs(runtime.process, process)
        self.assertIs(runtime.generation, generation)
        self.assertIs(runtime.readiness, readiness)
        self.assertEqual(runtime.ready_event_count, 1)
        self.assertEqual(runtime.readiness.max_context_tokens, 128)
        self.assertEqual(runtime.wait_ready_calls, 0)
        self.assertEqual(runtime.restart_count, 0)
        self.assertTrue(runtime.ready)
        self.assertEqual(len(runtime.requests), 1)

    def test_invalid_resolved_context_fails_closed_without_fencing_generation(self):
        cases = (
            ("missing", _MISSING, 64, 128, True),
            ("null", None, 64, 128, True),
            ("zero", 0, 0, 128, True),
            ("negative", -1, -1, 128, True),
            ("float", 64.0, 64, 128, True),
            ("string", "64", 64, 128, True),
            ("bool", True, 1, 128, True),
            ("over ceiling", 129, 129, 128, True),
            ("ceiling mismatch", 64, 64, 127, True),
            ("missing ceiling", 64, 64, 128, True),
            ("missing maximum", 64, 64, 128, True),
            ("maximum mismatch", 64, 63, 128, True),
            ("readiness mismatch", 64, 64, 128, False),
        )
        for name, context, maximum, ceiling, nested_ready in cases:
            with self.subTest(context=name):
                runtime = LifecycleRuntime(
                    inference_ready=True,
                    effective_context_tokens=64,
                )
                runtime.publish_status(
                    inference_ready=True,
                    effective_context_tokens=context,
                    lifecycle_inference_ready=nested_ready,
                    configured_context_ceiling=ceiling,
                    maximum_context_tokens=maximum,
                )
                harness = self.harness(runtime, max_context=128)
                if name == "missing":
                    snapshot = json.loads(runtime.status_event.json)
                    snapshot.pop("effective_context_tokens")
                    runtime.status_event = wire.StatusJsonEvent(
                        1,
                        wire.STATUS_SCHEMA_VERSION,
                        json.dumps(snapshot, separators=(",", ":")).encode(),
                    )
                elif name == "missing maximum":
                    snapshot = json.loads(runtime.status_event.json)
                    snapshot.pop("maximum_context_tokens")
                    runtime.status_event = wire.StatusJsonEvent(
                        1,
                        wire.STATUS_SCHEMA_VERSION,
                        json.dumps(snapshot, separators=(",", ":")).encode(),
                    )
                elif name == "missing ceiling":
                    snapshot = json.loads(runtime.status_event.json)
                    snapshot.pop("configured_context_ceiling")
                    runtime.status_event = wire.StatusJsonEvent(
                        1,
                        wire.STATUS_SCHEMA_VERSION,
                        json.dumps(snapshot, separators=(",", ":")).encode(),
                    )

                self.assertEqual(harness.request("GET", "/ready")[0], 503)
                status, _, payload = harness.request("GET", "/status")
                self.assertEqual(status, 200)
                snapshot = json.loads(payload)
                self.assertTrue(snapshot["control_ready"])
                self.assertFalse(snapshot["ready"])
                self.assertTrue(snapshot["inference_ready"])
                self.assertIsNone(harness.app.max_context)
                self.assertFalse(harness.backend.can_submit())
                self.assertTrue(runtime.ready)
                self.assertEqual(runtime.restart_count, 0)
                self.assertEqual(runtime.wait_ready_calls, 0)
                self.assertEqual(runtime.requests, [])

    def test_out_of_order_lifecycle_snapshots_follow_highest_revision(self):
        runtime = LifecycleRuntime(
            inference_ready=False,
            effective_context_tokens=None,
        )
        harness = self.harness(runtime, max_context=128)
        backend = harness.backend
        app = harness.app
        captured_backend_runtime = backend.runtime
        captured_process = runtime.process
        captured_generation = runtime.generation
        captured_readiness = runtime.readiness
        captured_ready_event_count = runtime.ready_event_count
        captured_restart_count = runtime.restart_count
        captured_wait_ready_calls = runtime.wait_ready_calls

        # A newer Battery snapshot is model-less and closes Python admission.
        runtime.publish_status(
            inference_ready=False,
            effective_context_tokens=None,
            lifecycle_revision=2,
        )
        current_battery = json.loads(runtime.status_event.json)
        accepted = backend._cache_status(current_battery)
        self.assertEqual(accepted["lifecycle"]["revision"], 2)
        self.assertEqual(backend.status_snapshot["lifecycle"]["revision"], 2)
        self.assertFalse(backend.can_submit())

        # An older AC-ready completion cannot reopen that newer Battery state.
        runtime.publish_status(
            inference_ready=True,
            effective_context_tokens=72,
            lifecycle_revision=1,
        )
        old_ac_snapshot = json.loads(runtime.status_event.json)
        accepted = backend._cache_status(old_ac_snapshot)
        self.assertEqual(accepted["lifecycle"]["revision"], 2)
        self.assertEqual(backend.status_snapshot["lifecycle"]["revision"], 2)
        self.assertFalse(backend.can_submit())

        # A newer AC recovery opens admission and installs the effective limit.
        runtime.publish_status(
            inference_ready=True,
            effective_context_tokens=64,
            lifecycle_revision=3,
        )
        current_ac = json.loads(runtime.status_event.json)
        accepted = backend._cache_status(current_ac)
        self.assertEqual(accepted["lifecycle"]["revision"], 3)
        self.assertEqual(backend.status_snapshot["lifecycle"]["revision"], 3)
        self.assertTrue(backend.can_submit())
        self.assertEqual(app.max_context, 64)

        # A delayed completion from Battery cannot regress successful AC state.
        accepted = backend._cache_status(current_battery)
        self.assertEqual(accepted["lifecycle"]["revision"], 3)
        self.assertEqual(backend.status_snapshot["lifecycle"]["revision"], 3)
        self.assertTrue(backend.can_submit())
        self.assertEqual(app.max_context, 64)

        self.assertIs(harness.app, app)
        self.assertIs(harness.backend, backend)
        self.assertIs(backend.runtime, captured_backend_runtime)
        self.assertIs(backend.runtime, runtime)
        self.assertIs(runtime.process, captured_process)
        self.assertIs(runtime.generation, captured_generation)
        self.assertIs(runtime.readiness, captured_readiness)
        self.assertEqual(runtime.ready_event_count, captured_ready_event_count)
        self.assertEqual(runtime.ready_event_count, 1)
        self.assertEqual(runtime.restart_count, captured_restart_count)
        self.assertEqual(runtime.restart_count, 0)
        self.assertEqual(runtime.wait_ready_calls, captured_wait_ready_calls)
        self.assertEqual(runtime.wait_ready_calls, 0)
        self.assertEqual(runtime.requests, [])
        self.assertEqual(backend.active, {})

    def test_child_restart_resets_revision_ordering_for_new_generation(self):
        runtime = LifecycleRuntime(
            inference_ready=True,
            effective_context_tokens=48,
        )
        harness = self.harness(runtime, max_context=128)
        backend = harness.backend
        app = harness.app

        runtime.publish_status(
            inference_ready=True,
            effective_context_tokens=48,
            lifecycle_revision=9,
        )
        previous_generation_snapshot = json.loads(runtime.status_event.json)
        backend._cache_status(previous_generation_snapshot, generation=0)
        self.assertEqual(app.max_context, 48)

        # The replacement child owns a fresh native lifecycle whose revision
        # starts lower than the previous process's final revision.
        runtime.restart_count = 1
        runtime.generation = object()
        runtime.process = object()
        runtime.publish_status(
            inference_ready=True,
            effective_context_tokens=72,
            lifecycle_revision=1,
        )
        snapshot = backend._lifecycle_snapshot()
        self.assertTrue(backend._snapshot_inference_ready(snapshot))
        self.assertEqual(app.max_context, 72)
        self.assertEqual(backend.status_snapshot_generation, 1)
        self.assertEqual(backend.status_snapshot["lifecycle"]["revision"], 1)

        # A delayed completion from the failed process cannot replace the new
        # generation's cache or Frontend limit.
        self.assertIsNone(
            backend._cache_status(previous_generation_snapshot, generation=0)
        )
        self.assertEqual(app.max_context, 72)
        self.assertEqual(backend.status_snapshot_generation, 1)

    def test_stale_true_is_only_a_prefilter_before_native_admission(self):
        runtime = FakeRuntime()
        backend = backend_api.NativeBackend(runtime, NativeTokenizer())
        self.addCleanup(backend.close)
        clock = [100.0]
        with (
            mock.patch.object(
                backend_api, "time", SimpleNamespace(monotonic=lambda: clock[0])
            ),
        ):
            backend._cache_status(json.loads(runtime.status_event.json))
            clock[0] += backend_api.STATUS_LIFECYCLE_FRESHNESS_SECONDS + 0.01
            current = json.loads(runtime.status_event.json)
            current["ready"] = False
            current["inference_ready"] = False
            runtime.status_event = wire.StatusJsonEvent(
                2, wire.STATUS_SCHEMA_VERSION, json.dumps(current).encode()
            )
            self.assertTrue(backend.can_submit())
            with mock.patch.object(
                runtime,
                "submit",
                side_effect=engine_runtime.EngineUnhealthy(
                    "native admission is closed"
                ),
            ) as native_submit:
                with self.assertRaisesRegex(
                    engine_runtime.EngineUnhealthy, "native admission is closed"
                ):
                    runtime.submit(None, on_event=None, on_complete=None)
            native_submit.assert_called_once()

    def test_ready_and_status_start_one_recovery_without_waiting_for_startup(self):
        for first_path in ("/ready", "/status"):
            with self.subTest(first_path=first_path):
                runtime = RecoveringRuntime()
                harness = self.harness(runtime)
                started = time.monotonic()
                response = harness.request("GET", first_path)
                self.assertLess(time.monotonic() - started, 0.5)
                self.assertEqual(response[0], 503 if first_path == "/ready" else 200)
                self.assertTrue(runtime.startup_entered.wait(0.5))
                self.assertFalse(runtime.startup_release.is_set())
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
                runtime.startup_release.set()
                self.wait_until(lambda: not harness.backend.status_refresh_inflight)
                self.assertEqual(harness.request("GET", "/ready")[0], 200)
                snapshot = json.loads(harness.request("GET", "/status")[2])
                self.assertFalse(snapshot["transport"]["recovering"])
                self.assertEqual(runtime.requests, [])

    def test_failed_recovery_is_backed_off_and_success_resets_backoff(self):
        runtime = RecoveringRuntime(
            [
                engine_runtime.EngineUnhealthy("first"),
                engine_runtime.EngineUnhealthy("second"),
            ]
        )
        runtime.startup_release.set()
        backend = backend_api.NativeBackend(runtime, NativeTokenizer())
        self.addCleanup(backend.close)
        clock = [100.0]
        with mock.patch.object(
            backend_api, "time", SimpleNamespace(monotonic=lambda: clock[0])
        ):
            self.assertFalse(backend.can_submit())
            self.wait_until(lambda: not backend.status_refresh_inflight)
            first_retry = backend.status_refresh_after
            self.assertGreater(first_retry, clock[0])
            for _ in range(10):
                backend.status()
                self.assertFalse(backend.can_submit())
            self.assertEqual(runtime.startup_calls, 1)
            clock[0] = first_retry
            self.assertFalse(backend.can_submit())
            self.wait_until(lambda: not backend.status_refresh_inflight)
            second_retry = backend.status_refresh_after
            self.assertGreater(second_retry - clock[0], first_retry - 100)
            self.assertEqual(runtime.startup_calls, 2)
            clock[0] = second_retry
            backend.can_submit()
            self.wait_until(lambda: not backend.status_refresh_inflight)
            self.assertTrue(backend.can_submit())
            self.assertEqual(runtime.startup_calls, 3)
            self.assertEqual(backend.status_refresh_failures, 0)
            self.assertGreater(backend.status_refresh_after, clock[0])
            self.assertLessEqual(
                backend.status_refresh_after - clock[0],
                backend_api.STATUS_LIFECYCLE_FRESHNESS_SECONDS,
            )
        backend.close()
        self.assertFalse(backend.can_submit())
        self.assertFalse(backend.status()["transport"]["recovering"])
        self.assertEqual(runtime.startup_calls, 3)

    def test_generation_recovery_rejects_before_body_or_ingress_and_advertises_retry(
        self,
    ):
        runtime = RecoveringRuntime()
        harness = self.harness(runtime, queue_size=1)
        with mock.patch.object(harness.app, "prepare") as prepare:
            for path in ("/v1/messages", "/v1/chat/completions", "/v1/responses"):
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
                        self.assertEqual(response.status, 503)
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
        self.assertEqual(runtime.startup_calls, 1)
        self.assertEqual(runtime.requests, [])
        self.assertEqual(
            harness.request("POST", "/v1/messages/count_tokens", self.body())[0], 200
        )
        self.assertEqual(harness.request("GET", "/v1/models")[0], 200)

    def test_fresh_control_status_clears_old_refresh_backoff(self):
        runtime = RecoveringRuntime()
        runtime.ready = True
        runtime.startup_release.set()
        backend = backend_api.NativeBackend(runtime, NativeTokenizer())
        self.addCleanup(backend.close)
        with mock.patch.object(
            backend_api, "time", SimpleNamespace(monotonic=lambda: 100.0)
        ):
            with mock.patch.object(runtime, "status", side_effect=TimeoutError):
                backend._ensure_background_status_refresh()
                self.wait_until(lambda: not backend.status_refresh_inflight)
            self.assertGreater(backend.status_refresh_after, 100.0)
            self.assertTrue(backend.status()["ready"])
            self.assertEqual(backend.status_refresh_failures, 0)
            self.assertEqual(
                backend.status_refresh_after,
                100.0 + backend_api.STATUS_LIFECYCLE_FRESHNESS_SECONDS,
            )
            runtime.ready = False
            self.assertFalse(backend.can_submit())
            self.wait_until(lambda: not backend.status_refresh_inflight)
            self.assertEqual(runtime.startup_calls, 1)
            self.assertTrue(backend.can_submit())

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
                status, _, payload = harness.request(
                    "POST", "/v1/messages/count_tokens?beta=true", self.body()
                )
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

    def test_launcher_accepts_a_recovering_instance_without_calling_it_ready(self):
        snapshot = {
            "ready": False,
            "transport": {"ready": False, "recovering": True, "status_stale": False},
        }
        with mock.patch.object(launcher, "_request_json", return_value=snapshot):
            self.assertIs(launcher._running_status(), snapshot)
            self.assertFalse(snapshot["ready"])
            snapshot["transport"]["recovering"] = False
            self.assertEqual(launcher._running_status(), snapshot)

    def test_background_recovery_and_waiters_share_the_native_startup(self):
        payload = json.dumps(
            {
                "schema_version": wire.STATUS_SCHEMA_VERSION,
                "ready": True,
                "control_ready": True,
                "inference_ready": True,
                "memory_pressure": "normal",
                "metal": {"healthy": True},
            }
        ).encode()

        def respond(process, message):
            if isinstance(message, wire.StatusRequestFrame):
                process.send(
                    wire.StatusJsonEvent(
                        message.correlation_id, wire.STATUS_SCHEMA_VERSION, payload
                    )
                )

        factory = FakeFactory(handler=respond, initial_output=b"")
        runtime = engine_runtime.MultiplexedRuntime(
            process_factory=factory, eager_start=False
        )
        backend = backend_api.NativeBackend(runtime, NativeTokenizer())
        self.addCleanup(backend.close)
        self.assertFalse(backend.status()["ready"])
        self.wait_until(lambda: len(factory.processes) == 1)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            waiters = [pool.submit(runtime.wait_ready, 1) for _ in range(4)]
            for _ in range(10):
                self.assertFalse(backend.can_submit())
            self.assertEqual(len(factory.processes), 1)
            factory.processes[0].send(wire.ReadyEvent(1000, 4, 131072, READY_FEATURES))
            for waiter in waiters:
                self.assertTrue(waiter.result(1))
        self.wait_until(lambda: not backend.status_refresh_inflight)
        self.assertTrue(backend.status()["ready"])
        self.assertEqual(runtime.pending_count, 0)
        self.assertEqual(factory.processes[0].stdin.messages(wire.RequestFrame), [])

    def test_idle_engine_death_restarts_before_traffic_arrives(self):
        def respond(process, message):
            if isinstance(message, wire.StatusRequestFrame):
                process.send(
                    wire.StatusJsonEvent(
                        message.correlation_id,
                        wire.STATUS_SCHEMA_VERSION,
                        b'{"schema_version":5,"ready":true,'
                        b'"control_ready":true,"inference_ready":true,'
                        b'"memory_pressure":"normal"}',
                    )
                )

        factory = FakeFactory(handler=respond)
        runtime = engine_runtime.MultiplexedRuntime(process_factory=factory)
        backend = backend_api.NativeBackend(runtime, NativeTokenizer())
        self.addCleanup(backend.close)
        factory.processes[0].kill()
        self.wait_until(lambda: len(factory.processes) == 2 and runtime.ready, 2)
        self.assertEqual(runtime.restart_count, 1)
        self.assertTrue(backend.can_submit())

    def test_engine_failure_and_failed_restart_are_reported(self):
        factory = FakeFactory()

        def launch():
            if factory.processes:
                raise FileNotFoundError("splash")
            return factory()

        runtime = engine_runtime.MultiplexedRuntime(process_factory=launch)
        backend = backend_api.NativeBackend(runtime, NativeTokenizer())
        self.addCleanup(backend.close)
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

    def test_engine_failure_under_a_request_asks_its_client_to_retry(self):
        factory = FakeFactory()
        runtime = engine_runtime.MultiplexedRuntime(process_factory=factory)
        backend = backend_api.NativeBackend(runtime, NativeTokenizer())
        self.addCleanup(backend.close)
        job = make_job()
        with mock.patch.object(backend_api, "print_status") as console:
            self.assertTrue(backend.submit(job))
            factory.processes[0].stdin.wait_for(wire.RequestFrame)
            factory.processes[0].close_stdout()
            kind, error = job.events.get(timeout=1)
            self.wait_until(lambda: console.called)
        self.assertEqual(kind, "error")
        self.assertEqual(
            (error.status, error.code, error.message),
            (
                503,
                "runtime_unavailable",
                "the inference engine stopped unexpectedly and is restarting; "
                "retry the request",
            ),
        )
        # The engine's own reason stays on the console.
        self.assertEqual(
            console.call_args_list[0].args[0],
            "Engine failed · native protocol reached EOF",
        )

    def test_recovery_refusals_carry_the_last_engine_failure(self):
        runtime = RecoveringRuntime([engine_runtime.EngineUnhealthy("GPU is gone")])
        runtime.startup_release.set()
        harness = self.harness(runtime)
        clock = [100.0]
        with (
            mock.patch.object(
                backend_api, "time", SimpleNamespace(monotonic=lambda: clock[0])
            ),
            mock.patch.object(backend_api, "print_status") as console,
        ):
            self.assertFalse(harness.backend.can_submit())
            self.wait_until(lambda: not harness.backend.status_refresh_inflight)
            console.assert_called_once_with(
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
            clock[0] = harness.backend.status_refresh_after
            self.assertFalse(harness.backend.can_submit())
            self.wait_until(lambda: not harness.backend.status_refresh_inflight)
            self.assertTrue(harness.backend.can_submit())
            console.assert_called_with("Engine restarted")
            transport = json.loads(harness.request("GET", "/status")[2])["transport"]
            self.assertNotIn("error", transport)

    def test_startup_protocol_failure_ends_with_one_error_line(self):
        missing = READY_FEATURES & ~wire.ReadyFeature.MULTIPLEXING
        runtime_type = engine_runtime.MultiplexedRuntime
        for output, reason in (
            (
                wire.serialize_message(wire.ReadyEvent(1000, 4, 131072, missing)),
                "missing required native protocol features",
            ),
            (b"not a frame".ljust(wire.FRAME_HEADER_BYTES, b"\0"), "bad_magic"),
        ):
            with self.subTest(reason=reason):
                factory = FakeFactory(initial_output=output)
                with (
                    mock.patch.object(api, "parse_args", return_value=main_args()),
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
                self.assertIn("Error · ", line)
                self.assertIn(reason, line)
                self.assertIsNotNone(factory.processes[0].poll())

    def test_restarted_native_must_match_the_original_ready_event(self):
        original = wire.ReadyEvent(1001, 4, 131072, READY_FEATURES)
        for restarted in (
            original,
            dataclasses.replace(original, max_context_tokens=65536),
            dataclasses.replace(original, max_concurrent_requests=1),
            dataclasses.replace(
                original, feature_bits=READY_FEATURES | wire.ReadyFeature.VISION
            ),
        ):
            with self.subTest(restarted=restarted):
                factory = FakeFactory()
                runtime = engine_runtime.MultiplexedRuntime(process_factory=factory)
                try:
                    self.assertEqual(runtime.readiness.max_context_tokens, 131072)
                    with mock.patch.object(runtime._crash_trace, "dump"):
                        factory.processes[0].kill()
                        self.wait_until(lambda: not runtime.ready)
                        factory.initial_output = wire.serialize_message(restarted)
                        if restarted is original:
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

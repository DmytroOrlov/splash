"""Fast process-group regressions; no model or server installation required."""

import os
import select
import signal
import subprocess
import sys
import time
import unittest
from unittest import mock

from dev.tests.integration.full_server_recovery import (
    child_exited,
    cleanup_server_group,
)

CHILD = r"""
import os, signal, sys
if sys.argv[1] == "ignore":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
os.write(1, b"ready\n")
while True:
    signal.pause()
"""
LEADER = r"""
import subprocess, sys
child = subprocess.Popen([sys.executable, "-c", sys.argv[1], sys.argv[2]])
print(child.pid, flush=True)
sys.stdin.buffer.read(1)
"""


def line(stream, timeout=2):
    if not select.select([stream], [], [], timeout)[0]:
        raise AssertionError("timed out waiting for pipe witness")
    return stream.readline()


def wait_exit(process, timeout=2):
    deadline = time.monotonic() + timeout
    while not child_exited(process):
        if time.monotonic() >= deadline:
            raise AssertionError("leader did not exit")
        time.sleep(0.005)


class GroupCleanupTests(unittest.TestCase):
    def start_group(self, ignore=False):
        process = subprocess.Popen(
            [sys.executable, "-c", LEADER, CHILD, "ignore" if ignore else "normal"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            start_new_session=True,
            bufsize=0,
        )
        child_pid = None
        try:
            child_pid = int(line(process.stdout))
            self.assertEqual(line(process.stdout), b"ready\n")
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)
            process.stdin.close()
            process.stdout.close()
            raise

        def finish():
            # If the leader is still reserved, group signalling is safe. If it
            # was reaped in the negative witness, the pipe proves the child is
            # still alive before targeting that child directly.
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                process.wait(timeout=2)
            elif select.select([process.stdout], [], [], 0)[0] == []:
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.stdin.close()
            process.stdout.close()

        self.addCleanup(finish)
        return process, child_pid

    def test_leader_exit_and_descendant_cleanup(self):
        process, _ = self.start_group()
        process.stdin.write(b"x")
        wait_exit(process)
        self.assertIsNone(process.returncode)
        self.assertFalse(select.select([process.stdout], [], [], 0)[0])
        cleanup_server_group(process, grace_seconds=0.1)
        self.assertEqual(line(process.stdout), b"")
        self.assertIsNotNone(process.returncode)
        with self.assertRaises(ChildProcessError):
            os.waitpid(process.pid, os.WNOHANG)

    def test_ignoring_descendant_is_killed_after_grace(self):
        process, _ = self.start_group(ignore=True)
        process.stdin.write(b"x")
        wait_exit(process)
        with mock.patch("os.killpg", wraps=os.killpg) as killpg:
            cleanup_server_group(process, grace_seconds=0.1)
        signals = [call.args[1] for call in killpg.call_args_list]
        self.assertEqual(signals[0], signal.SIGTERM)
        self.assertEqual(signals[-1], signal.SIGKILL)
        self.assertTrue(all(sig == 0 for sig in signals[1:-1]))
        self.assertEqual(line(process.stdout), b"")
        self.assertIsNotNone(process.returncode)

    def test_default_grace_is_short_and_still_escalates(self):
        for ignore in (False, True):
            with self.subTest(ignore=ignore):
                process, _ = self.start_group(ignore=ignore)
                process.stdin.write(b"x")
                wait_exit(process)
                started = time.monotonic()
                with mock.patch("os.killpg", wraps=os.killpg) as killpg:
                    cleanup_server_group(process)
                elapsed = time.monotonic() - started
                self.assertLess(elapsed, 2, "default shutdown took too long")
                self.assertEqual(line(process.stdout), b"")
                if ignore:
                    self.assertIn(
                        signal.SIGKILL, [c.args[1] for c in killpg.call_args_list]
                    )

    def test_absent_group_during_grace_finishes_early(self):
        process = mock.Mock(pid=os.getpgrp() + 100000, returncode=None)
        with (
            mock.patch("dev.tests.integration.full_server_recovery.child_exited"),
            mock.patch("os.killpg", side_effect=[None, ProcessLookupError]) as killpg,
            mock.patch("time.sleep") as sleep,
        ):
            cleanup_server_group(process, grace_seconds=30)
        self.assertEqual(
            [c.args[1] for c in killpg.call_args_list], [signal.SIGTERM, 0]
        )
        sleep.assert_not_called()
        process.wait.assert_called_once()

    def test_eperm_probe_does_not_prevent_escalation(self):
        process = mock.Mock(pid=os.getpgrp() + 100000, returncode=None)
        with (
            mock.patch("dev.tests.integration.full_server_recovery.child_exited"),
            mock.patch(
                "os.killpg", side_effect=[None, PermissionError, None]
            ) as killpg,
        ):
            cleanup_server_group(process, grace_seconds=0)
        self.assertEqual(
            [c.args[1] for c in killpg.call_args_list],
            [signal.SIGTERM, 0, signal.SIGKILL],
        )
        process.wait.assert_called_once()

    def test_absent_group_and_caller_guard(self):
        process, _ = self.start_group()
        # A missing group is harmless, including while an exception unwinds.
        real_killpg = os.killpg

        def absent_then_kill(pid, sig):
            real_killpg(pid, signal.SIGKILL)
            raise ProcessLookupError()

        with self.assertRaisesRegex(RuntimeError, "original"):
            try:
                raise RuntimeError("original")
            finally:
                with mock.patch("os.killpg", side_effect=absent_then_kill):
                    cleanup_server_group(process, grace_seconds=0.01)
        self.assertEqual(line(process.stdout), b"")
        fake = mock.Mock(pid=os.getpgrp(), returncode=None)
        with mock.patch("os.killpg") as killpg:
            with self.assertRaises(ValueError):
                cleanup_server_group(fake)
            killpg.assert_not_called()

    @unittest.skipUnless(sys.platform == "darwin", "Darwin libc fallback")
    def test_python_312_libc_fallback(self):
        process, _ = self.start_group(ignore=True)
        with mock.patch.object(os, "waitid", create=True):
            del os.waitid
            self.assertFalse(child_exited(process))
            process.stdin.write(b"x")
            wait_exit(process)
            cleanup_server_group(process, grace_seconds=0.1)
        self.assertEqual(line(process.stdout), b"")

    def test_old_cleanup_negative_witness(self):
        process, child_pid = self.start_group()
        process.stdin.write(b"x")
        wait_exit(process)
        # The old poll() reaps the leader and skips group signalling.
        self.assertIsNotNone(process.poll())
        process.wait(timeout=2)
        self.assertFalse(select.select([process.stdout], [], [], 0)[0])
        os.kill(child_pid, signal.SIGKILL)
        self.assertEqual(line(process.stdout), b"")


if __name__ == "__main__":
    unittest.main()

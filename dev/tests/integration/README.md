# Opt-in full-server recovery

On a supported Apple Silicon host with an installed model and no other model server resident, build the dedicated executable and run one synthetic AC → Battery → AC cycle from the repository root. The production executable does not contain the test power source. This test is not part of default discovery and does not download a model.

```sh
make BUILD=build/t015-corrected build/t015-corrected/splash-integration
SPLASH_INTEGRATION_MODEL=/absolute/path/to/installed/model \
SPLASH_INTEGRATION_MODEL_ID='OWNER/REPO:VARIANT' \
SPLASH_INTEGRATION_BINARY="$PWD/build/t015-corrected/splash-integration" \
.venv/bin/python dev/tests/integration/full_server_recovery.py
```

The binary must be beside its built Metal libraries. Set `SPLASH_INTEGRATION_MAX_MEMORY` to the appropriate byte limit for the host (default 37795712204) and optionally `SPLASH_INTEGRATION_LOG` to choose the server log. The test uses a private temporary power file, verifies suspension, unchanged native PID and retained graph, one readiness announcement, and successful post-recovery HTTP inference with a nonzero cached prefix. The server rejects a second native ReadyEvent as a fatal protocol error.

The native bootstrap executable also has an opt-in installed-model test, invoked with `SPLASH_INSTALLED_RECOVERY_MODEL=/absolute/path/to/installed/model build/t015-corrected/engine-tests/runtime-bootstrap build/t015-corrected/splash.metallib`. It uses a 37795712204-byte limit and is excluded unless that variable is set.

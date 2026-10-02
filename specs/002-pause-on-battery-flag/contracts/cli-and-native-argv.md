# CLI and Native Argument Contract

## Public command

The serving CLI accepts:

```text
splash serve --model <model> --pause-on-battery
```

`--pause-on-battery` is a `store_true` option and defaults to false. Public help describes it as releasing model residency while on battery and recovering on AC power; the wording does not claim that all memory is freed.

## Child argv

- If the parsed value is false, `_native_command(args)` emits no `--pause-on-battery` token.
- If true, `_native_command(args)` emits exactly one standalone `--pause-on-battery` token.
- The choice is passed in argv; it is not inferred from status, environment, current power, or Python readiness.

## Native command

`serve-native` accepts standalone `--pause-on-battery` among its optional arguments. Presence maps to `NativeArguments::pauseOnBattery = true`; omission maps to false. Existing positional values and `--name value` pairs retain their semantics. The option is startup-only and does not create a protocol or runtime toggle.

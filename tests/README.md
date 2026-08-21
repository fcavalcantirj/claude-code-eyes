# Tests

No camera required — a fixture HTTP server stands in for one, including the
IP Webcam control surface (`/settings/zoom`, `/focus`, `/status.json`).

```bash
bash tests/run_tests.sh          # from anywhere in the repo
bash tests/run_tests.sh /path/to/a/copy   # or point it at another checkout
```

Prints one line per check and exits non-zero if any fail. The runner starts and
stops its own fixtures; nothing is left listening.

## What's covered

Backends, watch mode, config precedence, the `CCE_KEYS` allowlist boundary, the
non-image guard, HTTP basic auth, output directory + `CCE_OUT_DIR`, retry, zoom and
focus (including that zoom is **restored** afterwards), `setup.sh` behaviour, CRLF
detection, and failure diagnosis — 401 vs 4xx vs proxy-403 vs no-response, and that
a sandbox is never blamed when the evidence doesn't support it.

## Two things that will bite you

**curl never routes loopback through a proxy.** The proxy-bypass test therefore binds
a second fixture to `0.0.0.0` and uses the machine's real LAN address. A test written
against `127.0.0.1` passes whether the code is right or wrong. It self-skips when no
LAN address is available.

**Plant the failure first.** Before trusting a new assertion, break the code on
purpose and confirm *that* test — and only that test — goes red. Every check here was
introduced that way; several passed for the wrong reason until the mutation exposed
them.

## Adding a case

Use `ok` / `no` / `chk` and `newdir` (which gives each case a clean working
directory, since `snap.sh` writes frames to `$PWD`). Keep it bash 3.2-safe: it must
run under macOS's `/bin/bash` 3.2, so no `declare -A`, no GNU-only flags, and use
`grep -E` rather than escaped BRE alternation.

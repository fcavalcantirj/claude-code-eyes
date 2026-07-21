# claude-code-eyes — notes for Claude Code

This repository **is** a single Claude Code skill (repo root = the skill folder).
If you're editing it with Claude Code, keep the invariants below — each was learned
the hard way, and the tests/validator won't always catch you breaking them.

## What it is

A camera-vision skill. `snap.sh` grabs a frame from a snapshot-capable camera and
prints its path; Claude `Read`s the path to *see* it. `SKILL.md` is the skill
itself; `setup.sh` writes the camera config and verifies it; the rest is
docs/metadata.

## Load-bearing invariants (do not "simplify" these away)

- **The `CCE_KEYS` allowlist in `snap.sh` and `setup.sh` is a security boundary.**
  Config files (`./.cce.env`, `~/.config/claude-code-eyes/config`) are *parsed*,
  never `source`d — a config file must not be able to execute code or set arbitrary
  variables. The allowlist check runs **before** the value ever reaches
  `eval`/`printf -v`. Keep it exactly there.
- **Never ship a backend you haven't actually run.** The local `ffmpeg` webcam path
  is documented in the README but deliberately **not** implemented in `snap.sh`,
  because it can't be tested headlessly (macOS gates camera access behind an
  interactive permission prompt). Mark untested things untested, or leave them out.
- **Keep the soul.** The reason this beats a one-line `curl | Read` is the three
  disciplines in `SKILL.md`: visual-verify (catch what green tests can't), the
  wiring-mentor protocol, and "know what your instrument can and cannot see."
  Don't trim `SKILL.md` back down to a webcam grab.
- **`snap.sh` must stay portable to bash 3.2** (the default `/bin/bash` on macOS)
  and Linux. Preserve the empty-array-under-`set -u` guard
  (`${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}`), avoid GNU-only flags, and write output to
  `${TMPDIR:-/tmp}`.

## Frontmatter rules (enforced by the skill-creator validator)

`SKILL.md` frontmatter allows only these keys: `name, description, license,
allowed-tools, metadata, compatibility`. `name` is kebab-case, ≤ 64 chars.
**`description` is ≤ 1024 chars and must contain NO angle brackets** (`<` `>`) —
write usage hints as words, not with bracketed placeholders. Validate with the
skill-creator plugin's `quick_validate.py <skill-dir>` (prints `Skill is valid!`,
exit 0).

## How to test (everything must pass under bash 3.2)

No real camera is needed — serve a JPEG over HTTP and point the script at it:

```bash
bash -n snap.sh setup.sh                 # syntax first

# a tiny JPEG fixture + a throwaway server
python3 -c 'import base64;open("shot.jpg","wb").write(base64.b64decode(b"/9j/4AAQSkZJRgABAQEAYABgAAD/2Q=="))' 2>/dev/null || : # use any real jpg
python3 -m http.server 8099 --bind 127.0.0.1 &

CCE_CAM_TYPE=url CCE_CAM_URL=http://127.0.0.1:8099/shot.jpg bash snap.sh
# -> prints a path; `file --mime-type <path>` must report image/jpeg
```

Cover, at minimum: the no-config error path (exit 1), all three backends
(`ipwebcam`/`camera-streamer`/`url`), watch mode (`snap.sh 3 1` → 3 frames),
env-beats-`.cce.env` precedence, the non-image magic-byte guard (an HTML `200` body
must be rejected), an unknown `CCE_CAM_TYPE` (exit 2), and HTTP basic auth. For
`setup.sh`: `--url` writes + verifies, a dead camera still saves the config with a
friendly message (exit 0), and `--scan` discovers a fixture on the LAN.

**Plant the failure first:** before trusting a test, make it go red on demand.

## Adding a camera backend

1. Add the type to the `case` in `snap.sh` (endpoint mapping) **and** to
   `setup.sh`'s `endpoint_for` plus the valid-type lists in both.
2. If it isn't an HTTP snapshot (e.g. a local capture), only ship it if you can
   test it non-interactively; otherwise document it in the README as experimental,
   like the `ffmpeg` path.
3. Add a test that proves it, and a row in the README + `SKILL.md` backend tables.

## Conventions

Single-skill repo: root = skill folder, so `git clone` straight into
`~/.claude/skills/…` works. No secrets in git (`.gitignore` covers
`.env`/`.cce.env`/tokens/captured frames). MIT licensed.

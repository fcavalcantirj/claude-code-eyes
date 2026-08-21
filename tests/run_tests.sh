#!/bin/bash
# claude-code-eyes test matrix. Usage: run_tests.sh /path/to/repo
REPO="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SNAP="$REPO/snap.sh"; SETUP="$REPO/setup.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="http://127.0.0.1:8099"

# --- fixtures: started here, stopped on exit ---------------------------------
FIXTURE="$(cd "$(dirname "$0")" && pwd)/fixture.py"
cleanup() { [ -n "${F1:-}" ] && kill "$F1" 2>/dev/null; [ -n "${F2:-}" ] && kill "$F2" 2>/dev/null; return 0; }
trap cleanup EXIT INT TERM
python3 "$FIXTURE" 8099 >/dev/null 2>&1 &            F1=$!
python3 "$FIXTURE" 8097 0.0.0.0 >/dev/null 2>&1 &    F2=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null -m 1 "$BASE/shot.jpg" && break
  sleep 0.5
done
curl -s -o /dev/null -m 2 "$BASE/shot.jpg" || { echo "fixture failed to start on 8099" >&2; exit 1; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n     -> %s\n' "$1" "$2"; }
chk(){ # name expected_exit "expected substring in output" -- cmd...
  local name="$1" xrc="$2" xsub="$3"; shift 3; [ "$1" = "--" ] && shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" != "$xrc" ]; then no "$name" "exit $rc, wanted $xrc :: $(printf '%s' "$out"|head -2|tr '\n' '|')"; return; fi
  if [ -n "$xsub" ] && ! printf '%s' "$out" | grep -qF "$xsub"; then
    no "$name" "missing '$xsub' :: $(printf '%s' "$out"|head -3|tr '\n' '|')"; return; fi
  ok "$name"
}
newdir(){ W="$(mktemp -d)"; cd "$W" || exit 1; }

echo "=== syntax ==="
bash -n "$SNAP" && ok "snap.sh parses" || no "snap.sh parses" "syntax error"
bash -n "$SETUP" && ok "setup.sh parses" || no "setup.sh parses" "syntax error"

echo "=== existing matrix ==="
newdir
chk "no config -> exit 1" 1 "no CCE_CAM_URL" -- \
  env -u CCE_CAM_URL -u CCE_CAM_TYPE -u CCE_OUT_DIR HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP"
chk "unknown type -> exit 2" 2 "unknown CCE_CAM_TYPE" -- \
  env CCE_CAM_TYPE=bogus CCE_CAM_URL="$BASE" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP"
chk "bad count -> exit 2" 2 "count must be" -- \
  env CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/shot.jpg" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" abc

# backend: url
newdir
out="$(env CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/shot.jpg" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"
if [ -f "$out" ] && [ "$(file --mime-type -b "$out")" = "image/jpeg" ]; then ok "backend url -> jpeg"; else no "backend url -> jpeg" "$out"; fi
# backend: ipwebcam (/shot.jpg)
newdir
out="$(env CCE_CAM_TYPE=ipwebcam CCE_CAM_URL="$BASE" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"
if [ -f "$out" ]; then ok "backend ipwebcam"; else no "backend ipwebcam" "$out"; fi
# backend: camera-streamer (/snapshot)
newdir
out="$(env CCE_CAM_TYPE=camera-streamer CCE_CAM_URL="$BASE" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"
if [ -f "$out" ]; then ok "backend camera-streamer"; else no "backend camera-streamer" "$out"; fi
# watch mode
newdir
n="$(env CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/shot.jpg" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 3 1 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" = "3" ] && ok "watch mode 3 frames" || no "watch mode 3 frames" "got $n lines"
# non-image guard
newdir
chk "html 200 rejected (exit 1, msg names non-image)" 1 "non-image content" -- \
  env CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/html" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP"
# basic auth
newdir
out="$(env CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/auth" CCE_CAM_AUTH="user:pass" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"
[ -f "$out" ] && ok "basic auth ok" || no "basic auth ok" "$out"
newdir
chk "basic auth wrong -> exit 1" 1 "" -- \
  env CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/auth" CCE_CAM_AUTH="user:nope" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP"
# env beats .cce.env
newdir
printf 'CCE_CAM_URL=%s/html\nCCE_CAM_TYPE=url\n' "$BASE" > .cce.env
out="$(env CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/shot.jpg" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"
[ -f "$out" ] && ok "env beats .cce.env" || no "env beats .cce.env" "$out"
# .cce.env used when env empty
newdir
printf 'CCE_CAM_URL=%s/shot.jpg\nCCE_CAM_TYPE=url\n' "$BASE" > .cce.env
out="$(env -u CCE_CAM_URL -u CCE_CAM_TYPE HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"
[ -f "$out" ] && ok ".cce.env is read" || no ".cce.env is read" "$out"

echo "=== new: output dir ==="
newdir
out="$(env CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/shot.jpg" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"
case "$out" in "$W/.claude-code-eyes/"*) ok "default out dir = CWD/.claude-code-eyes";; *) no "default out dir = CWD/.claude-code-eyes" "$out";; esac
newdir
out="$(env CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/shot.jpg" CCE_OUT_DIR="$W/custom" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"
case "$out" in "$W/custom/"*) ok "CCE_OUT_DIR env override";; *) no "CCE_OUT_DIR env override" "$out";; esac
newdir
printf 'CCE_OUT_DIR=%s/fromfile\n' "$W" > .cce.env
out="$(env -u CCE_OUT_DIR CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/shot.jpg" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"
case "$out" in "$W/fromfile/"*) ok "CCE_OUT_DIR from .cce.env";; *) no "CCE_OUT_DIR from .cce.env" "$out";; esac

echo "=== new: allowlist boundary still holds ==="
newdir
printf 'EVIL=pwned\nPATH=/nope\nCCE_CAM_URL=%s/shot.jpg\nCCE_CAM_TYPE=url\n' "$BASE" > .cce.env
out="$(env -u CCE_CAM_URL -u CCE_CAM_TYPE HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"
if [ -f "$out" ]; then ok "non-allowlisted keys ignored (EVIL/PATH)"; else no "non-allowlisted keys ignored" "$out"; fi

echo "=== new: failure diagnosis ==="
PX="HTTP_PROXY=http://127.0.0.1:1"   # stand-in for the proxy the sandbox always sets
# 403 behind a proxy == how the sandbox refuses an unlisted address
newdir
o="$(env $PX CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/forbidden" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$o" | grep -qF "answered 403 Forbidden" \
   && printf '%s' "$o" | grep -qF "\"excludedCommands\": [\"bash $SNAP\"]" \
   && ! printf '%s' "$o" | grep -qF '"allowedDomains": ['; then
  ok "403 + proxy on a LAN host -> excludedCommands (never an allowedDomains snippet)"
else no "403 + proxy LAN host" "rc=$rc :: $(printf '%s' "$o"|tr '\n' '|')"; fi
# 403 with NO proxy is the camera's own answer, not a sandbox verdict
newdir
o="$(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
     CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/forbidden" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$o" | grep -qF "this 403 came from the camera" \
   && ! printf '%s' "$o" | grep -qF "sandbox"; then
  ok "403 without proxy -> blamed on the camera, no sandbox claim"
else no "403 without proxy" "rc=$rc :: $(printf '%s' "$o"|tr '\n' '|')"; fi
# THE REGRESSION THAT MATTERED: a sleeping camera behind the sandbox proxy is
# NOT a sandbox denial. Measured: allow-listed-but-down => curl 7 / status 000.
newdir
o="$(env $PX CCE_CAM_TYPE=url CCE_CAM_URL="http://127.0.0.1:9/x.jpg" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$o" | grep -qF "camera not reachable" \
   && ! printf '%s' "$o" | grep -qF "refused with 403"; then
  ok "unreachable + proxy -> unreachable (NOT a sandbox verdict)"
else no "unreachable + proxy misreported as sandbox" "rc=$rc :: $(printf '%s' "$o"|tr '\n' '|')"; fi
if printf '%s' "$o" | grep -qF "This shell is sandboxed" \
   && printf '%s' "$o" | grep -qF "\"excludedCommands\": [\"bash $SNAP\"]"; then
  ok "unreachable + proxy hints at sandbox with the LAN-correct remedy"
else no "unreachable + proxy hint" "$(printf '%s' "$o"|tr '\n' '|')"; fi
# 401 names the auth key rather than blaming the network
newdir
o="$(env CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/auth" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$o" | grep -qF "401 Unauthorized" \
   && printf '%s' "$o" | grep -qF "CCE_CAM_AUTH"; then
  ok "401 -> auth message naming CCE_CAM_AUTH"
else no "401 -> auth message" "rc=$rc :: $(printf '%s' "$o"|tr '\n' '|')"; fi
# an HTTP answer is an answer: do not burn retries on it
newdir
t0=$(date +%s)
env CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/forbidden" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" >/dev/null 2>&1
t1=$(date +%s)
if [ $((t1-t0)) -le 2 ]; then ok "HTTP status is not retried (fast fail)"; else no "HTTP status not retried" "took $((t1-t0))s"; fi

echo "=== new: retry survives a late-starting camera ==="
newdir
( sleep 1.5; exec python3 "$FIXTURE" 8098 >/dev/null 2>&1 ) &
LATE=$!   # exec => $LATE is the server itself, killable even if snap.sh gave up early
o="$(env CCE_CAM_TYPE=url CCE_CAM_URL="http://127.0.0.1:8098/shot.jpg" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$o" ]; then ok "retry recovers a camera that refuses at first"; else no "retry recovers late camera" "rc=$rc :: $o"; fi
kill $LATE 2>/dev/null; pkill -f "fixture.py 8098" 2>/dev/null; wait $LATE 2>/dev/null

echo "=== new: the exclusion entry must match how snap.sh is ACTUALLY invoked ==="
# Claude Code matches excludedCommands with:
#   prefix: t === prefix || t.startsWith(prefix + " ")     exact: t === command
# SKILL.md documents `bash <path-to-skill>/snap.sh`, so a bare "bash snap.sh"
# entry can never match a real invocation. The entry must carry snap.sh's own
# absolute path -- which as a prefix also covers watch mode (`... snap.sh 3 2`).
PX="HTTP_PROXY=http://127.0.0.1:1"
newdir                                   # cwd is a temp dir, NOT the skill dir
o="$(env $PX CCE_CAM_TYPE=url CCE_CAM_URL="http://127.0.0.1:9/x.jpg" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"
if printf '%s' "$o" | grep -qF "\"excludedCommands\": [\"bash $SNAP\"]"; then
  ok "snap.sh advises its own absolute path"
else no "snap.sh advises its own absolute path" "$(printf '%s' "$o"|grep -i excluded|tr '\n' '|')"; fi
if printf '%s' "$o" | grep -qF '["bash snap.sh"]'; then
  no "snap.sh must not advise the unmatchable relative literal" "still prints [\"bash snap.sh\"]"
else ok "snap.sh drops the unmatchable relative literal"; fi
# watch-mode args are covered by prefix matching, so the entry must have no args
if printf '%s' "$o" | grep -qE '"excludedCommands": \["bash [^"]*snap\.sh"\]'; then
  ok "exclusion entry carries no trailing args (prefix covers watch mode)"
else no "exclusion entry shape" "$(printf '%s' "$o"|grep -i excluded|tr '\n' '|')"; fi
# the zero-config escape hatch should be mentioned before the settings edit
if printf '%s' "$o" | grep -qiF "outside the sandbox" ; then
  ok "sandbox message mentions the unsandboxed-retry escape hatch"
else no "escape hatch mentioned" "$(printf '%s' "$o"|tr '\n' '|')"; fi

echo "=== new: CRLF (the bug that actually killed a real install) ==="
# Field report 2026-08-20: a Windows-saved copy had CRLF terminators and bash died at
# `set -euo pipefail` with "set: pipefail: invalid option name" before any camera
# contact. git's core.autocrlf defaults to true on Windows, so a clone can reintroduce
# it -- .gitattributes is what stops that at distribution time.
if [ -f "$REPO/.gitattributes" ]; then ok ".gitattributes exists"; else no ".gitattributes exists" "missing"; fi
eolattr="$(cd "$REPO" && git check-attr eol -- snap.sh 2>/dev/null | sed 's/.*: //')"
if [ "$eolattr" = "lf" ]; then ok "git pins snap.sh to eol=lf"; else no "git pins snap.sh to eol=lf" "got '$eolattr'"; fi
eolattr2="$(cd "$REPO" && git check-attr eol -- setup.sh 2>/dev/null | sed 's/.*: //')"
if [ "$eolattr2" = "lf" ]; then ok "git pins setup.sh to eol=lf"; else no "git pins setup.sh to eol=lf" "got '$eolattr2'"; fi
# shipped files must be CR-free right now
crs="$(tr -cd '\r' < "$REPO/snap.sh" | wc -c | tr -d ' ')"
if [ "$crs" = "0" ]; then ok "shipped snap.sh has no CR bytes"; else no "snap.sh CR-free" "$crs CR bytes"; fi
# reproduce the reported failure, so we know the symptom is real
newdir
sed 's/$/\r/' "$SNAP" > ./crlf_snap.sh
crlf_err="$(bash ./crlf_snap.sh 2>&1 | head -3)"
if printf '%s' "$crlf_err" | grep -qF "pipefail"; then
  ok "CRLF copy reproduces the reported 'set: pipefail' death"
else no "CRLF repro" "$(printf '%s' "$crlf_err"|tr '\n' '|')"; fi
# setup.sh must catch it, because snap.sh cannot self-diagnose (bash dies first)
newdir
mkdir -p kit && sed 's/$/\r/' "$SNAP" > kit/snap.sh && cp "$SETUP" kit/setup.sh
o="$(HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash kit/setup.sh --url "$BASE" --type ipwebcam 2>&1)"
if printf '%s' "$o" | grep -qiF "CRLF"; then
  ok "setup.sh detects CRLF in snap.sh and says so"
else no "setup.sh detects CRLF" "$(printf '%s' "$o"|tr '\n' '|'|head -c 300)"; fi

echo "=== new: a 403 must not be blamed on the Bash sandbox alone ==="
# Field report: the 403 came from a Cowork device-bridge egress proxy answering
# X-Proxy-Error: blocked-by-allowlist -- not from Claude Code's sandbox.
newdir
o="$(env HTTP_PROXY=http://127.0.0.1:1 CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/proxyblock" \
     HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"
if printf '%s' "$o" | grep -qF "blocked-by-allowlist"; then
  ok "403: echoes the proxy's own X-Proxy-Error verdict"
else no "403 echoes X-Proxy-Error" "$(printf '%s' "$o"|tr '\n' '|'|head -c 300)"; fi
if printf '%s' "$o" | grep -qiF "which is how the Claude Code Bash sandbox blocks"; then
  no "403 must not assert the sandbox as the sole cause" "still asserts it"
else ok "403 does not assert the sandbox as the sole cause"; fi

echo "=== new: zoom + focus (issue #1) ==="
# Verified against a real IP Webcam device 2026-08-20:
#   /settings/zoom?set=V  absolute, V from avail.zoom (100=1x .. 1000=max)
#   /ptz?zoom=P           PERCENT 0..100 -- NOT absolute (this is the trap)
#   /focus, /nofocus      momentary trigger
#   curvals.zoom LAGS several seconds behind the set
# pydroid-ipcam's /settings/ptz?zoom=N is a 404 on the device; do not use it.
RESET(){ curl -s -m 5 "$BASE/_reset" >/dev/null 2>&1; }
LOG(){ curl -s -m 5 "$BASE/_log" 2>/dev/null; }

RESET; newdir
out="$(env CCE_CAM_TYPE=ipwebcam CCE_CAM_URL="$BASE" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" --zoom 3 2>/dev/null)"
if [ -f "$out" ]; then ok "--zoom captures a frame"; else no "--zoom captures a frame" "[$out]"; fi
l="$(LOG)"
if printf '%s' "$l" | grep -qE "^zoom=(298|307)$"; then
  ok "--zoom 3 maps to ~300 device units and snaps to an allowed step"
else no "--zoom 3 maps to device units" "log=[$(printf '%s' "$l"|tr '\n' ' ')]"; fi
if [ "$(printf '%s' "$l" | tail -1)" = "zoom=100" ]; then
  ok "zoom is RESTORED after capture (camera not left zoomed)"
else no "zoom restored after capture" "log ends [$(printf '%s' "$l"|tail -1)]"; fi

RESET; newdir
out="$(env CCE_CAM_TYPE=ipwebcam CCE_CAM_URL="$BASE" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" --focus 2>/dev/null)"
if [ -f "$out" ] && printf '%s' "$(LOG)" | grep -q "^focus$"; then
  ok "--focus triggers /focus then captures"
else no "--focus triggers /focus" "out=$out log=[$(LOG|tr '\n' ' ')]"; fi

RESET; newdir
out="$(env CCE_CAM_TYPE=ipwebcam CCE_CAM_URL="$BASE" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" --zoom 5 2 1 2>/dev/null)"
n="$(printf '%s\n' "$out" | grep -c "\.jpg$")"
if [ "$n" = "2" ]; then ok "--zoom composes with watch mode (2 frames)"; else no "--zoom + watch mode" "got $n frames"; fi
if [ "$(LOG | tail -1)" = "zoom=100" ]; then ok "zoom restored after watch mode too"; else no "zoom restored after watch" "$(LOG|tail -1)"; fi

RESET; newdir                      # unsupported backend must NOT fail the capture
out="$(env CCE_CAM_TYPE=url CCE_CAM_URL="$BASE/shot.jpg" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" --zoom 3 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qi "zoom"; then
  ok "url backend: says it cannot zoom, still captures, exit 0"
else no "url backend graceful" "rc=$rc :: $(printf '%s' "$out"|tr '\n' '|')"; fi

RESET; newdir                      # a bad zoom argument is rejected, not sent blind
o="$(env CCE_CAM_TYPE=ipwebcam CCE_CAM_URL="$BASE" HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" --zoom 99 2>&1)"; rc=$?
if [ "$rc" = 2 ]; then ok "--zoom out of range -> exit 2"; else no "--zoom range check" "rc=$rc :: $(printf '%s' "$o"|head -1)"; fi

echo "=== new: a LAN camera must never be sent through a proxy ==="
# Field report 2026-08-20: an egress proxy refused the camera's LAN IP. no_proxy was
# set to 192.168.0.0/16 but their curl could not CIDR-match it (CIDR support landed
# in curl 7.86), so the bypass silently did nothing. Passing --noproxy <host>
# explicitly works on every curl version and regardless of no_proxy spelling.
# NOTE: curl never proxies loopback, so this must be tested on a real LAN address.
LANIP="$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
if [ -z "$LANIP" ] || ! curl -s -o /dev/null -m 3 "http://$LANIP:8097/shot.jpg"; then
  echo "SKIP  LAN-proxy tests (no LAN fixture on $LANIP:8097)"
else
  newdir
  out="$(env http_proxy=http://127.0.0.1:1 ALL_PROXY=http://127.0.0.1:1 \
        CCE_CAM_TYPE=url CCE_CAM_URL="http://$LANIP:8097/shot.jpg" \
        HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>/dev/null)"
  if [ -f "$out" ]; then ok "LAN camera captured despite a dead proxy in the env"
  else no "LAN camera bypasses the proxy" "no frame; proxy was not bypassed"; fi
  # a PUBLIC host must still honour the proxy -- bypassing it there would break
  # anyone whose only route out is the proxy
  newdir
  o="$(env http_proxy=http://127.0.0.1:1 ALL_PROXY=http://127.0.0.1:1 \
      CCE_CAM_TYPE=url CCE_CAM_URL="http://example.com/shot.jpg" \
      HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SNAP" 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then ok "public host still routed via the proxy (not bypassed)"
  else no "public host must not bypass the proxy" "unexpectedly succeeded"; fi
fi

echo "=== setup.sh ==="
newdir
o="$(HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SETUP" --url "$BASE" --type ipwebcam 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$o" | grep -qF "got a live frame" \
   && printf '%s' "$o" | grep -qF "\"excludedCommands\": [\"bash $SNAP\"]" \
   && [ -f "$W/cfg/claude-code-eyes/config" ]; then
  ok "setup --url (LAN) advises the absolute path of its sibling snap.sh"
else no "setup --url writes+verifies" "rc=$rc :: $(printf '%s' "$o"|tr '\n' '|')"; fi
newdir
o="$(HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SETUP" --url "http://192.0.2.7:8080" --type ipwebcam 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$W/cfg/claude-code-eyes/config" ] \
   && printf '%s' "$o" | grep -qF "config is saved and correct" \
   && printf '%s' "$o" | grep -qF '"allowedDomains": ["192.0.2.7:8080"]'; then
  ok "setup dead PUBLIC camera: exit 0, config saved, allowedDomains hint"
else no "setup dead camera exit 0" "rc=$rc :: $(printf '%s' "$o"|tr '\n' '|')"; fi
newdir
o="$(HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SETUP" --url "http://192.168.7.7:8080" --type ipwebcam 2>&1)"
if printf '%s' "$o" | grep -qF "\"excludedCommands\": [\"bash $SNAP\"]" \
   && ! printf '%s' "$o" | grep -qF '"allowedDomains": ['; then
  ok "setup LAN camera advises excludedCommands, never an allowedDomains snippet"
else no "setup LAN advice" "$(printf '%s' "$o"|tr '\n' '|')"; fi
newdir
o="$(HOME="$W" XDG_CONFIG_HOME="$W/cfg" bash "$SETUP" --local --url "$BASE" --type ipwebcam 2>&1)"
if [ -f "$W/.cce.env" ]; then ok "setup --local writes ./.cce.env"; else no "setup --local" "$o"; fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

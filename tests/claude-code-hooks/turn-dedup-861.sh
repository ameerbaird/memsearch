#!/usr/bin/env bash
# #861.04: Discord channel turns count as turn starts, and two parallel Stop
# firings for the same turn write exactly one memory entry. Hermetic: stub
# claude + memsearch, temp HOME. Exit 0 = pass.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="$REPO/plugins/claude-code"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

FAIL=0
ok()   { echo "ok - $1"; }
nok()  { echo "not ok - $1"; FAIL=1; }

# Stubs. /usr/local/bin stays on PATH after the stubs so common.sh does not
# prepend it (and a real claude/memsearch there) ahead of them.
mkdir -p "$T/stub"
cat > "$T/stub/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in --help) exit 0 ;; esac
cat >/dev/null
sleep 2
echo "- stub summary"
EOF
cat > "$T/stub/memsearch" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/stub/claude" "$T/stub/memsearch"
export PATH="$T/stub:/usr/local/bin:/usr/bin:/bin"
export HOME="$T" MEMSEARCH_DIR="$T/.memsearch" CLAUDE_PROJECT_DIR="$T" CLAUDE_PLUGIN_ROOT="$PLUGIN"
unset MEMSEARCH_DISABLE MILVUS_URI

H=11111111-1111-1111-1111-111111111111
X=22222222-2222-2222-2222-222222222222
FX="$T/aaaaaaaa-0000-0000-0000-000000000000.jsonl"
cat > "$FX" <<EOF
{"type":"user","uuid":"$H","message":{"role":"user","content":"hello human"}}
{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}
{"type":"user","uuid":"$X","isMeta":true,"origin":{"kind":"channel","server":"plugin:discord:discord"},"message":{"role":"user","content":"<channel source=\"discord\">ping from discord</channel>"}}
{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"text","text":"pong"}]}}
{"type":"user","uuid":"33333333-3333-3333-3333-333333333333","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"r"}]}}
{"type":"user","uuid":"44444444-4444-4444-4444-444444444444","isMeta":true,"message":{"role":"user","content":"[Image: x]"}}
EOF

# a. Turn starts at the channel entry; tool_result and plain meta are not turn starts.
OUT="$(bash "$PLUGIN/hooks/parse-transcript.sh" "$FX" 2>&1)"
if [[ "$OUT" == *"ping from discord"* && "$OUT" != *"hello human"* ]]; then ok "a. parse starts at channel turn"; else nok "a. parse output: $OUT"; fi

# b. Two parallel Stop runs -> exactly one entry.
IN="$(printf '{"transcript_path":"%s","stop_hook_active":false}' "$FX")"
MF="$MEMSEARCH_DIR/memory/$(date +%F).md"
run_stop() { printf '%s' "$IN" | (cd "$T" && bash "$PLUGIN/hooks/stop.sh") >/dev/null 2>"$T/stop.$1.err"; }
run_stop 1 & run_stop 2 & wait
N="$(grep -c "turn:$X" "$MF" 2>/dev/null || true)"
if [[ "$N" == 1 ]]; then ok "b. parallel stops wrote 1 entry"; else nok "b. parallel stops wrote ${N:-0} entries"; cat "$T"/stop.*.err; fi
grep -q -- "- stub summary" "$MF" 2>/dev/null && ok "b. entry carries summary" || nok "b. no summary in entry"

# c. A third serial run leaves the count at 1.
run_stop 3
N="$(grep -c "turn:$X" "$MF" 2>/dev/null || true)"
if [[ "$N" == 1 ]]; then ok "c. serial rerun still 1"; else nok "c. serial rerun count ${N:-0}"; fi

# d. Only meta (non-channel) user entries -> no user message.
FX2="$T/meta-only.jsonl"
cat > "$FX2" <<'EOF'
{"type":"user","uuid":"55555555-5555-5555-5555-555555555555","isMeta":true,"message":{"role":"user","content":"[Image: y]"}}
{"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}
EOF
OUT="$(bash "$PLUGIN/hooks/parse-transcript.sh" "$FX2" 2>&1)"
if [[ "$OUT" == "(no user message found)" ]]; then ok "d. meta-only -> no user message"; else nok "d. parse output: $OUT"; fi

# e. Lock files: only X.lock in .turn-locks, none under memory/.
LOCKS="$(cd "$MEMSEARCH_DIR/.turn-locks" 2>/dev/null && ls -1 -- *.lock 2>/dev/null | tr '\n' ' ')"
MEMLOCKS="$(find "$MEMSEARCH_DIR/memory" -name '*.lock' | wc -l)"
if [[ "$LOCKS" == "$X.lock " && "$MEMLOCKS" == 0 ]]; then ok "e. lock files clean"; else nok "e. locks='$LOCKS' memory-locks=$MEMLOCKS"; fi

[[ $FAIL == 0 ]] && echo "PASS turn-dedup-861" || echo "FAIL turn-dedup-861"
exit $FAIL

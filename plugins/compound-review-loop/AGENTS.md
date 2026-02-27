# compound-review-loop Plugin — Agent Guidelines

## Goal

Independent Codex code review of every Claude agent's changes, with project-specific context
injection and knowledge compounding. Each agent in a parallel swarm gets a focused review of
only THEIR files — not the whole diff.

## Hard Requirements (NEVER violate)

- **Multi-agent review**: Codex prompt MUST instruct parallel review agents (Diff, Holistic,
  Next.js, UX). Never reduce to single-pass generic review
- **Consolidation instructions**: MUST be in prompt — dedup, severity ordering, per-finding format
  with file:line, category, description, suggested fix
- **Full AGENTS.md injection**: Load ENTIRE root AGENTS.md/CLAUDE.md into review prompt — not
  truncated. Intent layer root node has all repo-wide invariants
- **File-scoped reviews**: Each agent's review covers only files THAT agent modified. Never
  review full uncommitted diff when scoped files are available
- **Codex CLI constraint**: `--uncommitted` and `[PROMPT]` are mutually exclusive. We use
  `[PROMPT]` mode to inject project conventions and file scope. The prompt tells Codex to
  `git diff -- <file>` for specific files
- **Codex output is on stderr**: `codex exec review` writes review to stderr, not stdout.
  Capture with `2>"$REVIEW_FILE"`. Extract clean review after "codex" marker
- **Stop hook JSON-only stdout**: Hook MUST only write valid JSON to stdout. All logging,
  codex output, errors go to files/stderr — never stdout
- **Fail-open**: On any error, approve exit. Never trap user in broken loop
- **Preserve all review criteria**: 4 review agents (Diff + Holistic + Next.js + UX) each have
  detailed checklists. Anti-pattern detection. Convention injection. Never drop these

## Three-Phase Lifecycle

```
Phase 1 (task):       Claude implements → stop hook runs Codex review (+ parallel lint/typecheck)
Phase 2 (addressing): Claude addresses review findings
Phase 3 (compound):   Claude extracts reusable lore → updates AGENTS.md + progress.txt
```

## Codex Invocation (CRITICAL)

```bash
# CORRECT — [PROMPT] mode with custom instructions
codex exec review "$CODEX_PROMPT" $CODEX_FLAGS >/dev/null 2>"$REVIEW_FILE"

# WRONG — --uncommitted gives same generic review to all parallel agents
codex exec review --uncommitted $CODEX_FLAGS >/dev/null 2>"$REVIEW_FILE"

# WRONG — --uncommitted and [PROMPT] are mutually exclusive, this errors
echo "$PROMPT" | codex exec review --uncommitted $CODEX_FLAGS -

# WRONG — piping prompt loses multi-agent context vs positional arg
echo "$PROMPT" | codex exec review $CODEX_FLAGS -
```

Stderr contains: session header → MCP startup → thinking/exec traces → `codex\n<actual review>`.
Extract review content after last `^codex$` line. Strip noise: mcp, Warning, thinking, exec,
session header fields.

## Gotchas

### Stop hook `session_id` not in Stop event
- `PostToolUse` events include `session_id` — `Stop` events may NOT
- Stop hook has fallback chain: match by session_id → single active state file → most recent
- Without fallback, hook silently exits with approve (no logging, no review)

### Absolute paths from Claude Code
- `tool_input.file_path` sends absolute paths (`/Users/.../apps/backend/src/foo.ts`)
- Must relativize with `git rev-parse --show-toplevel` before module detection
- Without this, awk patterns for `apps/X`, `services/X` never match

### State file per session (parallel safety)
- State files: `.claude/review-loop-{REVIEW_ID}.local.md`
- Claimed by `track-modified.sh` on first PostToolUse (writes `session_id:` into file)
- Stop hook finds state by session_id grep, not hardcoded path
- Stale files cleaned up after 24h

### Prompt size
- Full AGENTS.md + 4 agent prompts + conventions + map can be large
- Codex handles it — tested with ~500-line AGENTS.md (~3K tokens)
- Map output capped at 40KB to avoid blowup

## File Scoping

1. `PostToolUse` hook (`track-modified.sh`) fires on Edit/Write
2. Appends `tool_input.file_path` to `.claude/modified-files-{session_id}.txt`
3. First fire claims unclaimed state file for this session
4. Stop hook reads tracking file → scoped file list
5. Fallback: tracking file → transcript parsing → git diff (all changes)

## Knowledge Compounding

1. Review findings classified: reusable pattern vs task-specific
2. Reusable lore routed to nearest AGENTS.md (Least Common Ancestor)
3. Session entry → `{output_dir}/progress.txt`
4. Output dir: `REVIEW_LOOP_OUTPUT_DIR` env → `compound.config.json` → `.claude/learnings/`

## Conventions

- Shell: macOS + Linux compatible (`sed -i ''` vs `sed -i`)
- State: `.claude/review-loop-*.local.md` — always clean up on exit
- Review ID: `YYYYMMDD-HHMMSS-hexhex` — validate `^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$`
- Log: `.claude/review-loop.log` — structured timestamped lines
- Security: validate review IDs, no secrets in state files

## Testing

- `/review-uncommitted`: standalone review on current changes, same prompt quality as full loop
- `scripts/test-codex-review.sh`: minimal CLI test of codex exec review
- After modifying stop-hook.sh: test all paths (no-state, task→addressing, addressing→compound,
  compound→approve)
- Verify JSON output with `jq .` for each path
- Test file scoping: modify 2 files, verify only those in review scope

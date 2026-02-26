# review-loop (fork)

> Fork of [hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop) with
> file-scoped reviews, project convention injection, and AI anti-pattern detection.

A Claude Code plugin that adds an automated code review loop to your workflow.

## What it does

When you use `/review-loop`, the plugin creates a two-phase lifecycle:

1. **Task phase**: You describe a task, Claude implements it
2. **Review phase**: When Claude finishes, the stop hook automatically runs [Codex](https://github.com/openai/codex) for an independent code review, then asks Claude to address the feedback

The result: every task gets an independent second opinion before you accept the changes.

## Fork additions

### File-scoped reviews (parallel agent safe)

A `PostToolUse` hook tracks every file modified by Edit/Write tools during the session. When the
Stop hook fires, Codex only reviews files THIS agent changed — not the entire repo.

This means multiple agents can work in parallel on different modules of the same branch, and each
gets a review scoped to its own changes.

**Fallback chain**: tracking file → transcript parsing → full git diff

### Project convention injection

The stop hook reads `AGENTS.md` or `CLAUDE.md` from the repo root and injects project conventions
into the Codex review prompt. Codex reviews against YOUR standards, not generic ones.

### AI anti-pattern detection

The diff review agent checks for common AI coding mistakes:
- Mocks/stubs created just to pass tests instead of testing real behavior
- Real code replaced with comments (`// implementation here`, `// TODO`)
- Unused parameters prefixed with `_param` to suppress lint warnings
- Code added on top without integrating into existing patterns
- Hardcoded values that should use existing constants/enums
- Over-engineered error handling for impossible scenarios
- New utility functions duplicating existing ones
- Unnecessary type assertions (`as any`, `!`) instead of fixing types
- Feature flags or backward-compat shims when direct replacement was appropriate

## Review coverage

The plugin spawns up to 4 parallel Codex sub-agents, depending on project type:

| Agent | Always runs? | Focus |
|-------|-------------|-------|
| **Diff Review** | Yes | `git diff` — code quality, test coverage, security (OWASP top 10), AI anti-patterns |
| **Holistic Review** | Yes | Project structure, documentation, AGENTS.md, agent harness, architecture |
| **Next.js Review** | If `next.config.*` or `"next"` in `package.json` | App Router, Server Components, caching, Server Actions, React performance |
| **UX Review** | If `app/`, `pages/`, `public/`, or `index.html` exists | Browser E2E via [agent-browser](https://agent-browser.dev/), accessibility, responsive design |

After all agents finish, Codex deduplicates findings and writes a single consolidated review to `reviews/review-<id>.md`.

## Requirements

- [Claude Code](https://claude.ai/code) (CLI)
- `jq` — `brew install jq` (macOS) / `apt install jq` (Linux)
- [Codex CLI](https://github.com/openai/codex) — `npm install -g @openai/codex`

### Codex multi-agent

This plugin uses Codex [multi-agent](https://developers.openai.com/codex/multi-agent/) to run parallel review agents. The `/review-loop` command automatically enables it in `~/.codex/config.toml` on first use.

To set it up manually instead:

```toml
# ~/.codex/config.toml
[features]
multi_agent = true
```

## Installation

From the CLI:

```bash
claude plugin marketplace add dkorobtsov/claude-review-loop
claude plugin install review-loop@dkorobtsov-review
```

Or from within a Claude Code session:

```
/plugin marketplace add dkorobtsov/claude-review-loop
/plugin install review-loop@dkorobtsov-review
```

## Updating

```bash
claude plugin marketplace update dkorobtsov-review
claude plugin update review-loop@dkorobtsov-review
```

## Usage

### Start a review loop

```
/review-loop Add user authentication with JWT tokens and test coverage
```

Claude will implement the task. When it finishes, the stop hook:
1. Collects the list of files this agent modified (from PostToolUse tracking)
2. Runs `codex exec` scoped to those files for an independent review
3. Writes findings to `reviews/review-<id>.md`
4. Blocks Claude's exit and asks it to address the feedback
5. Claude addresses items it agrees with, then stops

### Cancel a review loop

```
/cancel-review
```

## How it works

The plugin uses two hooks:

**PostToolUse hook** (`track-modified.sh`): Fires on every Edit/Write tool call. Appends the
modified file path to `.claude/modified-files-{session_id}.txt`.

**Stop hook** (`stop-hook.sh`): When Claude tries to stop:
1. Reads the state file (`.claude/review-loop.local.md`)
2. If in `task` phase: loads scoped file list, runs Codex with project conventions, transitions to `addressing`, blocks exit
3. If in `addressing` phase: allows exit, cleans up tracking files

## File structure

```
plugins/review-loop/
├── .claude-plugin/
│   └── plugin.json           # Plugin manifest
├── commands/
│   ├── review-loop.md        # /review-loop slash command
│   └── cancel-review.md      # /cancel-review slash command
├── hooks/
│   ├── hooks.json            # Hook registration (PostToolUse + Stop)
│   ├── track-modified.sh     # PostToolUse: tracks modified files per session
│   └── stop-hook.sh          # Stop: file-scoped Codex review with conventions
├── scripts/
│   └── setup-review-loop.sh  # Argument parsing, state file creation
├── AGENTS.md                  # Agent operating guidelines
└── README.md
```

## Configuration

The stop hook timeout is set to 900 seconds (15 minutes) in `hooks/hooks.json`. Adjust if your Codex reviews take longer.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_LOOP_CODEX_FLAGS` | `--dangerously-bypass-approvals-and-sandbox` | Flags passed to `codex`. Set to `--sandbox workspace-write` for safer sandboxed reviews. |

### Telemetry

Execution logs are written to `.claude/review-loop.log` with timestamps, codex exit codes, and elapsed times. This file is gitignored.

## Credits

Original plugin by [Hamel Husain](https://github.com/hamelsmu). Inspired by the [Ralph Wiggum plugin](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) and [Ryan Carson's compound engineering loop](https://x.com/ryancarson/article/2016520542723924279).

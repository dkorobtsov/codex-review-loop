#!/usr/bin/env bash
# Track Modified Files — PostToolUse Hook
#
# Appends file paths touched by Edit/Write tools to a session-scoped tracking file.
# Used by stop-hook.sh to scope Codex review to only files THIS agent changed.
#
# On first fire for a session, claims a pending codex-review state file by writing
# session_id into it. This links the session to the review for parallel agent safety.
#
# Receives JSON on stdin with tool_name and tool_input.file_path.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LOG_FILE="${REPO_ROOT}/.claude/codex-review.log"
log() { mkdir -p "$(dirname "$LOG_FILE")"; echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] [track] $*" >> "$LOG_FILE"; }

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)

# Only track Edit and Write tools
case "$TOOL_NAME" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

# Skip if no file path
[ -z "$FILE_PATH" ] && exit 0

# Append to session-scoped tracking file
TRACK_DIR="${REPO_ROOT}/.claude"
mkdir -p "$TRACK_DIR"
TRACK_FILE="${TRACK_DIR}/modified-files-${SESSION_ID}.txt"

# ── Claim pending state file on first fire ────────────────────────────
# State files without session_id are "pending" — created by /review-loop command.
# First PostToolUse hook for a session claims it by writing session_id into the file.
#
# MULTI-AGENT SAFETY: Uses mkdir-based atomic lock to prevent TOCTOU race
# when multiple agents fire their first Edit simultaneously. Without this,
# two agents could both see the same state file as unclaimed and both claim it,
# causing one agent's review to use the wrong review_id/state file.
CLAIM_LOCK="${REPO_ROOT}/.claude/.claiming"

# Claim check runs on every Edit/Write until successful — NOT gated on track file existence.
# Previous bug: gating on `! -f "$TRACK_FILE"` meant a failed lock acquisition on the first
# Edit would create the track file, permanently suppressing retry on subsequent Edits.
if [ -n "$SESSION_ID" ]; then
  # Check if already claimed (fast path — skip lock acquisition)
  if grep -Fl "session_id: ${SESSION_ID}" "${REPO_ROOT}"/.claude/codex-review-*.local.md 2>/dev/null | head -1 | grep -q .; then
    : # already claimed, no-op
  else
    # Clean stale lock (older than 10s — claiming takes milliseconds)
    if [ -d "$CLAIM_LOCK" ]; then
      LOCK_AGE=0
      if [ "$(uname)" = "Darwin" ]; then
        LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$CLAIM_LOCK" 2>/dev/null || echo 0) ))
      else
        LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$CLAIM_LOCK" 2>/dev/null || echo 0) ))
      fi
      if [ "$LOCK_AGE" -gt 10 ]; then
        rmdir "$CLAIM_LOCK" 2>/dev/null || true
        log "Cleaned stale claim lock (age=${LOCK_AGE}s)"
      fi
    fi

    # Atomic claim with mkdir lock (atomic on all filesystems)
    CLAIMED=""
    CLAIM_ATTEMPTS=0
    MAX_CLAIM_ATTEMPTS=5
    while [ "$CLAIM_ATTEMPTS" -lt "$MAX_CLAIM_ATTEMPTS" ]; do
      if mkdir "$CLAIM_LOCK" 2>/dev/null; then
        # Got lock — find and claim first unclaimed state file
        for sf in "${REPO_ROOT}"/.claude/codex-review-*.local.md; do
          [ -f "$sf" ] || continue
          if ! grep -q "^[[:space:]]*session_id:" "$sf" 2>/dev/null; then
            # Write session_id on its own line after started_at.
            # IMPORTANT: macOS sed `a\` can insert a leading tab — use printf+sed
            # to avoid tab-indented lines that break `grep "^session_id:"` detection.
            if [ "$(uname)" = "Darwin" ]; then
              sed -i '' "s/^started_at:.*/&\\
session_id: ${SESSION_ID}/" "$sf"
            else
              sed -i "/^started_at:/a session_id: ${SESSION_ID}" "$sf"
            fi
            CLAIMED="$sf"
            log "Claimed state file $sf for session $SESSION_ID"
            break
          fi
        done
        rmdir "$CLAIM_LOCK" 2>/dev/null || true
        break
      else
        # Lock held by another agent — wait briefly and retry
        CLAIM_ATTEMPTS=$((CLAIM_ATTEMPTS + 1))
        sleep 0.1
      fi
    done

    if [ "$CLAIM_ATTEMPTS" -ge "$MAX_CLAIM_ATTEMPTS" ]; then
      log "WARN: could not acquire claim lock after $MAX_CLAIM_ATTEMPTS attempts for session $SESSION_ID"
    elif [ -z "$CLAIMED" ]; then
      log "WARN: no unclaimed state file found for session $SESSION_ID"
    fi
  fi
fi

# Append only if not already tracked (dedup)
if ! grep -qxF "$FILE_PATH" "$TRACK_FILE" 2>/dev/null; then
  echo "$FILE_PATH" >> "$TRACK_FILE"
fi

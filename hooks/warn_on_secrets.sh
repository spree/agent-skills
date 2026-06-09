#!/usr/bin/env bash
# PostToolUse hook for Edit/Write/MultiEdit. Scans the edited file for
# hardcoded secrets that look like real credentials. Warns (doesn't block) —
# false positives in secret detection are common, and false-blocking a
# legitimate edit is more painful than a soft warning.
#
# Reads the tool result JSON from stdin. The file path is in tool_input.file_path
# (Edit / Write) or tool_input.path (MultiEdit). We just re-scan the file.
#
# Returns 0 always; emits stderr message that Claude treats as advisory.

set -euo pipefail

# Escape hatch.
if [[ "${SPREE_HOOKS_DISABLE:-}" == "1" ]]; then
  exit 0
fi

input="$(cat)"
file="$(echo "$input" | sed -n 's/.*"file_path":[[:space:]]*"\([^"]*\)".*/\1/p')"
[[ -z "$file" ]] && file="$(echo "$input" | sed -n 's/.*"path":[[:space:]]*"\([^"]*\)".*/\1/p')"

# Can't read the file? Bail silently.
# Use a single bracketed test — `[[ A ]] || [[ B ]] && C` parses as
# `A || (B && C)` due to bash operator precedence, so when $file is empty
# the exit would be skipped and we'd error on the empty path further down.
[[ -z "$file" || ! -r "$file" ]] && exit 0

# Skip files known to legitimately reference key shapes without leaking
# them — .env examples, READMEs/CHANGELOGs, lockfiles. We deliberately do
# NOT exclude all *.md (e.g. deployment/secrets.md could ship a real key
# someone pasted in).
case "$file" in
  *.env.example|*.env.sample|*/README*|*/CHANGELOG*|*.lock|*lockfile) exit 0 ;;
esac

# Patterns for known secret formats. Conservative — only well-known prefixes
# with high specificity. Generic things like "password = ..." would noise too much.
declare -a patterns=(
  # Stripe live keys (loud — block-worthy in practice, but we warn)
  'sk_live_[A-Za-z0-9]{24,}'
  'rk_live_[A-Za-z0-9]{24,}'

  # AWS access key ID (well-known shape)
  'AKIA[0-9A-Z]{16}'

  # GitHub personal access tokens
  'ghp_[A-Za-z0-9]{36}'
  'gho_[A-Za-z0-9]{36}'
  'github_pat_[A-Za-z0-9_]{82}'

  # OpenAI / Anthropic API key shapes
  'sk-[A-Za-z0-9]{20,}'
  'sk-ant-[A-Za-z0-9-]{20,}'

  # Generic high-entropy assignment for known sensitive variable names
  '(SECRET_KEY_BASE|DATABASE_PASSWORD|STRIPE_SECRET_KEY|SMTP_PASSWORD)[[:space:]]*=[[:space:]]*['"'"'"][^$'"'"'"]{20,}['"'"'"]'
)

matches=()
for pattern in "${patterns[@]}"; do
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    # Capture the matching line (sans the actual secret to avoid echoing it back)
    line_num=$(grep -nE "$pattern" "$file" 2>/dev/null | head -1 | cut -d: -f1)
    matches+=("$file:$line_num matches pattern '$pattern'")
  fi
done

if [[ ${#matches[@]} -gt 0 ]]; then
  cat <<EOF >&2
⚠️  Spree safety hook: potential hardcoded secret in $file

$(printf '  - %s\n' "${matches[@]}")

If these are real credentials, move them to an environment variable. The
Spree backend reads secrets from .env (gitignored by default); reference
them in code via ENV['MY_KEY']. If the matches are false positives (test
fixtures, example strings), ignore this warning.

Set SPREE_HOOKS_DISABLE=1 to silence these warnings entirely.
EOF
fi

exit 0

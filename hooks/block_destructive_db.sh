#!/usr/bin/env bash
# PreToolUse hook for the Bash tool. Blocks destructive database commands
# that have a real chance of wiping production data if mistargeted.
#
# Reads the tool invocation JSON from stdin, returns:
#   exit 0   — allow (stderr is not shown to Claude on success)
#   exit 2   — block (Claude shows the stderr message and refuses)
#
# We're deliberately strict on commands that match well-known destructive
# patterns, and we honor an environment-based escape hatch (SPREE_HOOKS_DISABLE=1)
# so power users can opt out. False positives are a real risk — keep the
# match list small and pinned to commands that are genuinely scary.

set -euo pipefail

# Escape hatch — set in CI or for advanced users.
if [[ "${SPREE_HOOKS_DISABLE:-}" == "1" ]]; then
  exit 0
fi

# Read the tool input. Format: { "tool_name": "Bash", "tool_input": { "command": "..." } }
input="$(cat)"
command="$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[[ -z "$command" ]] && command="$(echo "$input" | sed -n 's/.*"command":[[:space:]]*"\([^"]*\)".*/\1/p')"

# No command extracted? Don't block; fall through.
[[ -z "$command" ]] && exit 0

# Patterns we consider unambiguously destructive in a Spree project context.
# Each entry is an extended regex, matched case-insensitively (SQL is often lowercase). Order doesn't matter; first match blocks.
patterns=(
  # Database-level drops and resets
  # Anchored to a command position (line start, separator, subshell open, or
  # JSON-escaped newline) so quoted mentions — rg 'rake db:reset',
  # git commit -m '... rails db:drop' — don't trip the hook.
  '(^|[;&|`][[:space:]]*|\\n[[:space:]]*|\$\([[:space:]]*)([[:alnum:]_/.=-]+[[:space:]]+)*(bin/)?(rake|rails)[[:space:]]+db:(drop|reset)'
  'spree[[:space:]]+db:reset[[:space:]]+.*--yes'

  # Raw SQL drops against Spree tables
  'DROP[[:space:]]+TABLE.*spree_'
  'DROP[[:space:]]+DATABASE'
  # Critical tables: placed orders, in-flight checkouts (spree_carts, 6.0+),
  # money records, customers/staff (spree_customers + spree_admin_users in
  # 6.0; spree_users is the 5.x table and the 6.0 migration source) and keys.
  'TRUNCATE.*spree_(orders|carts|payments|refunds|fulfillments|store_credits|gift_cards|users|customers|admin_users|api_keys)([^[:alnum:]_]|$)'

  # Mass deletes against critical Spree tables (raw SQL through CLI). No
  # trailing-semicolon anchor — `DELETE FROM spree_orders` is destructive
  # whether or not it's terminated; semicolon-anchoring would let unwrapped
  # SQL through.
  'DELETE[[:space:]]+FROM[[:space:]]+spree_(orders|carts|payments|refunds|fulfillments|store_credits|gift_cards|users|customers|admin_users|api_keys)([^[:alnum:]_]|$)'

  # ActiveRecord mass deletes via runner / console. Unconditional wipes only
  # (including via `.all` / `.unscoped`); a scoped relation such as
  # `.where(...).delete_all` is a deliberate, bounded delete and is allowed.
  'Spree::(Order|Cart|Payment|Refund|Fulfillment|StoreCredit|GiftCard|User|Customer|AdminUser|ApiKey)(\.(all|unscoped))*\.(delete|destroy)_all'
  'Spree\.(user|customer|admin_user)_class(\.(all|unscoped))*\.(delete|destroy)_all'

  # Force-pushes to main/master. Match both flag orderings (`--force …
  # main` and `… main --force`) by checking the components independently
  # rather than anchoring on their order.
  'git[[:space:]]+push[[:space:]]+.*--force.*[[:space:]](main|master)([[:space:]]|$)'
  'git[[:space:]]+push[[:space:]]+.*[[:space:]](main|master)([[:space:]].*)?--force'
  'git[[:space:]]+push[[:space:]]+.*-f[[:space:]].*(main|master)([[:space:]]|$)'
  'git[[:space:]]+push[[:space:]]+.*[[:space:]](main|master)([[:space:]].*)?[[:space:]]-f([[:space:]]|$)'
)

for pattern in "${patterns[@]}"; do
  if echo "$command" | grep -qiE "$pattern"; then
    cat <<EOF >&2
🛑 Spree safety hook blocked this command:

  $command

Pattern matched: $pattern

This looks like a destructive operation against Spree data. If this is
intentional (you really want to drop the database / wipe orders), set
SPREE_HOOKS_DISABLE=1 in your environment and re-run, OR run the command
yourself outside Claude's tool invocation.
EOF
    exit 2
  fi
done

exit 0

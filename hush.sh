#!/bin/bash
# PreToolUse guard, for the main session and every subagent.
#
# 1. Personal details never leave the machine as themselves. Every string in
#    the tool input that contains a term from pii-terms.txt (one per line,
#    matched case-insensitively) is rewritten before the tool runs: an address
#    becomes example@example.com, any other term becomes "user", unless the
#    line gives its own stand-in as `term=replacement`. The call goes ahead
#    with the rewritten input through the normal permission flow, so a commit,
#    a request or a file gets the bogus value instead of being refused. Only a
#    Write/Edit of the terms file itself is exempt.
# 2. Commands that set their own request identifier (a User-Agent or From
#    header) are refused: requests go out with no identifier, which ~/.curlrc
#    and ~/.wgetrc enforce. Only tools that can send a request are checked, and
#    only header syntax (curl/wget flags, -H 'From:', a header line or a
#    headers object), never the word in prose or in code being read or written.
#    The check runs on the rewritten input, after rule 1.
# Any failure inside the hook refuses the call: it never fails open.
set -o pipefail
terms="$HOME/.claude/hooks/pii-terms.txt"
refuse() { echo "hush: $1" >&2; exit 2; }
command -v jq >/dev/null || refuse "jq is missing, refusing every call until it is installed"
input=$(cat) || refuse "could not read the tool call"
tool=$(printf '%s' "$input" | jq -r '.tool_name') || refuse "tool call is not JSON"

# The terms file may be edited: only by a file tool, only at exactly that path.
case "$tool" in
  Write|Edit|MultiEdit)
    path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""') || refuse "bad tool input"
    if [ -n "$path" ]; then
      real=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")
      real_terms=$(cd "$(dirname "$terms")" 2>/dev/null && pwd -P)/$(basename "$terms")
      [ "$real" = "$real_terms" ] && exit 0
    fi ;;
esac

# --- 1. rewrite personal terms -------------------------------------------
tool_input=$(printf '%s' "$input" | jq -c '.tool_input') || refuse "bad tool input"
changed=0
if [ -s "$terms" ]; then
  # JSON array of [term, replacement]: "a@b.c" -> example@example.com, "name" -> user, "x=y" -> y.
  pairs=$(grep -v '^[[:space:]]*$' "$terms" | jq -R -s -c '
    split("\n") | map(select(length > 0)) | map(
      if index("=") then [.[:index("=")], .[index("=")+1:]]
      elif test("@") then [., "example@example.com"]
      else [., "user"] end)') || refuse "could not read the terms file"
  rewritten=$(printf '%s' "$tool_input" | jq -c --argjson pairs "$pairs" '
    def quote: gsub("(?<c>[\\\\^$.|?*+()\\[\\]{}])"; "\\" + .c);
    def clean: reduce $pairs[] as $p (.; gsub($p[0] | quote; $p[1]; "i"));
    walk(if type == "string" then clean else . end)') || refuse "could not rewrite the tool input"
  [ -n "$rewritten" ] || refuse "empty rewrite"
  if [ "$rewritten" != "$tool_input" ]; then tool_input=$rewritten; changed=1; fi
fi

# --- 2. no self-chosen request identifier ----------------------------------
case "$tool" in
  Write|Edit|MultiEdit|NotebookEdit|Read|Glob|Grep|Agent|AskUserQuestion|SendMessage|TaskStop|ToolSearch|Skill) ;;
  *)
    # Checked on the original and the rewritten input. A here-string, not a
    # pipe: with pipefail a `grep -q` that closes early would turn a match
    # into a non-zero status and let the call through.
    hit() { # hit <grep flags> <patterns...> : 0 matched, 1 not, else refuse
      local flags=$1; shift; local pats=()
      for p in "$@"; do pats+=(-e "$p"); done
      grep -q "$flags" "${pats[@]}" <<<"$args"
      case $? in 0) return 0 ;; 1) return 1 ;; *) refuse "header check failed" ;; esac
    }
    for candidate in "$input" "$tool_input"; do
      # Two views of the input: the decoded strings and object keys, one per
      # line, with backslash-newline continuations joined, so the patterns see
      # the command as the shell does; and the JSON text itself, so nothing
      # hides in an encoding.
      args=$(printf '%s' "$candidate" | jq -r '
        (.. | strings | gsub("\\\\\n"; "")), (.. | objects | keys[]), tostring') || refuse "bad tool input"
      # Flag letters are case-sensitive (-A is the agent, -a is not; --data is
      # not -A); the program name is not (a case-insensitive filesystem runs CURL).
      if hit -E \
          "[Cc][Uu][Rr][Ll][^|;&]*[[:space:]\"']-[a-zA-Z]*A" \
          "[Ww][Gg][Ee][Tt][^|;&]*[[:space:]\"']-[a-zA-Z]*U" \
        || hit -iE \
          "curl[^|;&]*[[:space:]\"']--user-agent([[:space:]=\"']|$)" \
          "wget[^|;&]*[[:space:]\"']--user-agent([[:space:]=\"']|$)" \
          "(-H|--header)[[:space:]=\\\\\"']*(User-Agent|From)[[:space:]]*:" \
          "(^[[:space:]]*|\\\\n)(User-Agent|From):[[:space:]]*[^[:space:]]" \
          "[\\\\\"']*(User-Agent|From)[\\\\\"']*[[:space:]]*:[[:space:]]*[\\\\\"']+[^\"']+[\\\\\"']+"; then
        refuse "Blocked: this tool call sets a request identifier (User-Agent or From). Send no identifier at all: ~/.curlrc and ~/.wgetrc already strip the User-Agent header."
      fi
    done ;;
esac

if [ $changed -eq 1 ]; then
  # Only the input changes; the permission decision stays with the normal flow.
  jq -n -c --argjson u "$tool_input" '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: $u, permissionDecisionReason: "hush: personal details replaced with stand-ins (example@example.com, user)"}}' || refuse "could not emit the rewritten input"
fi
exit 0

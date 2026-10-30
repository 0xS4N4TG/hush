#!/bin/bash
# PreToolUse guard, for the main session and every subagent.
#
# 1. Personal details never leave the machine as themselves. Every string in
#    the tool input that contains a term from pii-terms.txt (one per line,
#    matched case-insensitively) is rewritten before the tool runs: an address
#    becomes example@example.com, any other term becomes "user", unless the
#    line gives its own stand-in as `term=replacement`. The call goes ahead
#    with the rewritten input, so a commit, a request or a file gets the bogus
#    value instead of being refused. Editing the terms file itself is allowed.
# 2. Commands that set their own request identifier (a User-Agent or From
#    header) are refused: requests go out with no identifier, which ~/.curlrc
#    and ~/.wgetrc enforce. Only tools that can send a request are checked, and
#    only header syntax (curl/wget flags, -H 'From:', a header line or a
#    headers object), never the word in prose or in code being read or written.
terms="$HOME/.claude/hooks/pii-terms.txt"
command -v jq >/dev/null || { echo "hush: jq is missing, refusing every call until it is installed" >&2; exit 2; }
input=$(cat)
case "$input" in *"/.claude/hooks/pii-terms.txt"*) exit 0 ;; esac
tool=$(printf '%s' "$input" | jq -r '.tool_name')

# --- 1. rewrite personal terms -------------------------------------------
if [ -s "$terms" ]; then
  # JSON array of [term, replacement]: "a@b.c" -> example@example.com, "name" -> user, "x=y" -> y.
  pairs=$(grep -v '^[[:space:]]*$' "$terms" | jq -R -s -c '
    split("\n") | map(select(length > 0)) | map(
      if index("=") then [.[:index("=")], .[index("=")+1:]]
      elif test("@") then [., "example@example.com"]
      else [., "user"] end)')
  rewritten=$(printf '%s' "$input" | jq -c --argjson pairs "$pairs" '
    def pat: [splits("")] | map(select(length > 0))
      | map(if test("[A-Za-z]") then "[" + ascii_upcase + ascii_downcase + "]"
            elif test("[0-9]") then . else "\\" + . end) | join("");
    def clean: reduce $pairs[] as $p (.; gsub($p[0] | pat; $p[1]));
    .tool_input | walk(if type == "string" then clean else . end)')
  original=$(printf '%s' "$input" | jq -c '.tool_input')
  if [ "$rewritten" != "$original" ]; then
    jq -n -c --argjson u "$rewritten" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: "hush: personal details replaced with stand-ins (example@example.com, user)", updatedInput: $u}}'
    exit 0
  fi
fi

# --- 2. no self-chosen request identifier ----------------------------------
case "$tool" in
  Write|Edit|MultiEdit|NotebookEdit|Read|Glob|Grep|Agent|AskUserQuestion|SendMessage|TaskStop|ToolSearch|Skill) exit 0 ;;
esac
args=$(printf '%s' "$input" | jq -r '.tool_input | tostring')
if printf '%s' "$args" | grep -qiE \
  -e 'curl[^|;&]* (-A|--user-agent)[ =]' \
  -e 'wget[^|;&]* (-U|--user-agent)[ =]' \
  -e "(-H|--header)[ =]+['\"]?(User-Agent|From):" \
  -e '(^|\\n)(User-Agent|From): *[^ \\n]' \
  -e "[\\\\\"']*(User-Agent|From)[\\\\\"']* *: *[\\\\\"']+[^\"']+[\\\\\"']+"; then
  echo "Blocked: this tool call sets a request identifier (User-Agent or From). Send no identifier at all: ~/.curlrc and ~/.wgetrc already strip the User-Agent header." >&2
  exit 2
fi
exit 0

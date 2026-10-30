#!/bin/bash
# Self-test for hush.sh. Run after any edit: ./hush.test.sh
# Uses a throwaway HOME with made-up terms, so the real pii-terms.txt is never read or printed.
hook="$(cd "$(dirname "$0")" && pwd)/hush.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.claude/hooks"
printf 'jane.doe@mail.test\nJane Doe\nACME-4711=ORG\n' > "$tmp/.claude/hooks/pii-terms.txt"
fail=0
run() { # run <tool> <json tool_input> ; sets $code and $out
  out=$(printf '{"tool_name":"%s","tool_input":%s}' "$1" "$2" | HOME="$tmp" bash "$hook" 2>&1); code=$?
}
expect_block() { run "$1" "$2"; [ $code -eq 2 ] || { echo "FAIL (should block): $1 $2 -> $code $out"; fail=1; }; }
expect_pass()  { run "$1" "$2"; [ $code -eq 0 ] && [ -z "$out" ] || { echo "FAIL (should pass): $1 $2 -> $code $out"; fail=1; }; }
expect_rewrite() { # <tool> <json> <must appear in updatedInput> <must not appear>
  run "$1" "$2"
  [ $code -eq 0 ] || { echo "FAIL (rewrite exit $code): $2 -> $out"; fail=1; return; }
  u=$(printf '%s' "$out" | jq -c '.hookSpecificOutput.updatedInput' 2>/dev/null)
  case "$u" in *"$3"*) ;; *) echo "FAIL (missing '$3'): $u"; fail=1;; esac
  case "$u" in *"$4"*) echo "FAIL (still has '$4'): $u"; fail=1;; esac
}

# must block: a header set by the command
expect_block Bash '{"command":"curl -A Mozilla https://x.test"}'
expect_block Bash '{"command":"curl https://x.test --user-agent=foo"}'
expect_block Bash '{"command":"wget -U bot https://x.test"}'
expect_block Bash '{"command":"curl -H '"'"'From: a@b.test'"'"' https://x.test"}'
expect_block Bash '{"command":"node -e \"fetch(u,{headers:{\\\"User-Agent\\\": \\\"bot\\\"}})\""}'
expect_block Bash '{"command":"curl -sA Mozilla https://x.test"}'
expect_block Bash '{"command":"curl -HFrom:a@b.test https://x.test"}'
expect_block Bash '{"command":"wget -qU bot https://x.test"}'
expect_pass Bash '{"command":"curl -sS https://x.test -o a.json"}'
expect_pass Bash '{"command":"ls -lA /tmp"}'
expect_block WebFetch '{"url":"https://x.test","prompt":"headers: User-Agent: \"x\""}'

# must pass: the words in prose, code and files
expect_pass Bash '{"command":"echo notes from: the editor"}'
expect_pass Bash '{"command":"grep -rn navigator.userAgent src/"}'
expect_pass Bash '{"command":"cat <<EOF > a.html\n<input type=\"email\"><ContactForm/>\nEOF"}'
expect_pass Agent '{"prompt":"Sources to read, from: the git log. Headers: User-Agent: x"}'
expect_pass Read '{"file_path":"/tmp/user-agent.md"}'
expect_pass Bash '{"command":"git log --format=%an"}'

# must rewrite: personal terms become stand-ins, call goes ahead
expect_rewrite Bash '{"command":"git commit --author=\"Jane Doe <jane.doe@mail.test>\""}' 'user <example@example.com>' 'jane.doe'
expect_rewrite Write '{"file_path":"/tmp/x.md","content":"Contact: JANE DOE at Jane.Doe@Mail.Test"}' 'user at example@example.com' 'Jane'
expect_rewrite Bash '{"command":"echo ACME-4711"}' 'echo ORG' '4711'
expect_rewrite Agent '{"prompt":"Mail jane.doe@mail.test the plan","description":"x"}' 'example@example.com' 'jane.doe'

# the terms file itself stays editable
expect_pass Edit "{\"file_path\":\"$tmp/.claude/hooks/pii-terms.txt\",\"old_string\":\"jane.doe@mail.test\",\"new_string\":\"x\"}"
# ...but naming that path does not exempt anything else
expect_rewrite Bash "{\"command\":\"echo jane.doe@mail.test >> $tmp/.claude/hooks/pii-terms.txt\"}" 'example@example.com' 'jane.doe'
# a header is still refused after the rewrite
expect_block Bash '{"command":"curl -H '"'"'From: jane.doe@mail.test'"'"' https://x.test"}'
# a term with regex characters is matched literally
printf 'a.b+c@mail.test\n' >> "$tmp/.claude/hooks/pii-terms.txt"
expect_rewrite Bash '{"command":"echo a.b+c@mail.test"}' 'example@example.com' 'a.b+c'
expect_pass Bash '{"command":"echo axb+c@mail.test"}'

[ $fail -eq 0 ] && echo "hush: all tests pass" || exit 1

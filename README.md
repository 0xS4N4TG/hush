# hush

A Claude Code hook that keeps your personal details out of what the agent sends, writes and runs.

It is one bash script, run before every tool call (yours and every subagent's). Two rules:

1. **Your details never leave as themselves.** Any string in a tool call that contains a term from your list is
   rewritten before the tool runs. An email address becomes `example@example.com`, a name becomes `user`, or you
   give the stand-in yourself. The call then goes ahead with the bogus value, so a request, a form, a file or an
   agent brief carries the stand-in instead of being refused.
2. **No self-chosen request identifier.** A command that sets its own `User-Agent` or `From` header (`curl -A`,
   `wget -U`, `-H 'From: …'`, a header line, a headers object in code) is refused. Prose, code you read or write, and
   `grep userAgent` are left alone.

Needs `jq`. If `jq` is missing the hook refuses every call rather than passing everything through silently.

## Install

```sh
mkdir -p ~/.claude/hooks
curl -fsSL https://raw.githubusercontent.com/0xS4N4TG/hush/main/hush.sh -o ~/.claude/hooks/hush.sh
chmod +x ~/.claude/hooks/hush.sh
```

Create `~/.claude/hooks/pii-terms.txt`, one term per line:

```
jane.doe@mail.test
Jane Doe
ACME-4711=ORG
```

An address becomes `example@example.com`, any other term becomes `user`, and `term=replacement` uses your own stand-in.
Matching is case-insensitive. Keep path fragments out of the list: a term that appears in your home directory path
would rewrite every file path.

Wire it up in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.claude/hooks/hush.sh", "timeout": 10, "onFailure": "block" }
        ]
      }
    ]
  }
}
```

Optionally strip the User-Agent from curl and wget too, so requests carry no identifier at all:

```sh
echo 'user-agent = ""' >> ~/.curlrc
echo 'user_agent = ' >> ~/.wgetrc
```

## What it does not do

- It does not change git's author: commits use `git config user.email`. Set that yourself if you want a stand-in there.
- It cannot change what the model has already read. It rewrites what goes out, not what came in.
- It matches fixed terms, not patterns. It will not catch an address that is not on the list.

## Test

```sh
./hush.test.sh
```

Runs the hook against a throwaway terms file with made-up names; your real list is never read or printed.

## Licence

MIT.

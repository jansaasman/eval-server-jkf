# eval-server-jkf

A TCP-based eval server for Allegro Common Lisp, plus a [Claude Code](https://claude.com/claude-code) skill (`/lispeval`) that teaches Claude how to drive it.

The server (`es.cl`, currently v1.3) accepts requests over a TCP socket, evaluates them in a fresh thread inside a long-running Lisp image, and returns the result, captured stdout, stderr, and (on error) a backtrace. Requests can be sent as a Lisp plist/alist or as JSON; the server auto-detects from the first non-blank character.

## Quick start

Start the server from a Lisp image:

```lisp
(load (compile-file "es"))
(user::start-server :port 2233
                    :lock-file "/tmp/es-cl.pid"
                    :log-file  "/tmp/es-cl.log")
```

Or as a one-liner from the shell:

```bash
mlisp -batch -e '(progn (load (compile-file "es")) (user::start-server))'
```

Send a request with `nc`:

```bash
echo '(:form "(+ 4 3)" :timeout 5)' | nc -w 10 localhost 2233
```

Response is an alist (or JSON) with `success`, `result`, `output`, `error-output`, and `backtrace` (on error).

See [`CLAUDE-EVAL-SERVER-GUIDE.md`](CLAUDE-EVAL-SERVER-GUIDE.md) for the full request option list, server start-up flags, and the Lisp-side client (`es::call-evalserver`).

## Request options

| Key          | Meaning                                                                 |
|--------------|-------------------------------------------------------------------------|
| `form`       | String to read and evaluate. Defaults to `"nil"`.                       |
| `key`        | Shared-secret auth — must match the server's `:key`.                    |
| `package`    | Package to read & print in. Sticky across subsequent connections.       |
| `compile`    | `"yes"` → compile the form and `funcall` it instead of `eval`.          |
| `timeout`    | Server-side timeout in seconds. Prefer this over `nc -w`.               |
| `reset`      | `"yes"` → interrupt all other in-flight evaluators first.               |
| `exit`       | Truthy → orderly shutdown (deletes lock file, then exits).              |

## The `/lispeval` Claude Code skill

`skills/lispeval/SKILL.md` is a skill for Claude Code that teaches Claude how to drive this server safely — wire format, hot-reload discipline, common pitfalls, and the difference from `/graphtalker`. Install it with:

```bash
./install-claude-skill.sh
export EVAL_SERVER_JKF_DIR="$(pwd)"
```

The installer copies `SKILL.md` into `~/.claude/skills/lispeval/` and registers a `/lispeval` trigger in `~/.claude/CLAUDE.md`. Re-run after every update to `SKILL.md` — it's idempotent. Uninstall with `./install-claude-skill.sh --uninstall`.

## Files

- `es.cl` — eval-server source.
- `CLAUDE-EVAL-SERVER-GUIDE.md` — canonical guide; covers everything not in the README or skill.
- `skills/lispeval/SKILL.md` — the `/lispeval` skill definition.
- `install-claude-skill.sh` — idempotent installer + uninstaller for the skill.

---
name: lispeval
description: drive jkf's TCP-based Common Lisp eval-server from any project — load/compile/test Lisp code in a running image via nc
trigger: /lispeval
---

# /lispeval

jkf's eval-server (the `es.cl` file in jkf's eval-server-jkf checkout, currently version 1.3) is a Common Lisp evaluator that accepts TCP requests, evaluates them in a fresh thread, and returns stdout/stderr/result. It's the primary remote-eval mechanism for projects that need autonomous Lisp execution. This skill teaches you how to drive that server from any project.

**Locating jkf's eval-server source** (path varies per installation):
- Check `$EVAL_SERVER_JKF_DIR` if set.
- Otherwise look at the project's `start-server.sh` (or equivalent) — it references `es.cl` by absolute path.
- Otherwise ask the user. Don't guess.

Throughout this skill, `<eval-server-jkf>` stands for whatever that resolved path is.

**Canonical reference**: `<eval-server-jkf>/CLAUDE-EVAL-SERVER-GUIDE.md` — read it for anything not covered below. The body of this skill covers entry points, dangerous patterns, and discipline rules accumulated from real incidents.

## When to use

- The user wants you to load, compile, or test Lisp code in a running Common Lisp image they're driving.
- The user wants to switch packages or set up readtables in a long-running Lisp.
- The user wants to inspect state in a Lisp image (`room`, structure slots, current bindings) without restarting.

Do **not** confuse with `/graphtalker` — that's a different eval-server with HTTP transport, JSON wire format, single shared session, and an AllegroGraph-specific tool catalogue. The two are not interchangeable.

## Step 1 — Locate the server

Each project picks its own port and lock file. Find them:

```bash
# Look for the project's startup script.
ls *server*.sh start-*.sh 2>/dev/null

# Or probe common project ports.
for p in 2233 2244 2255 2266; do
    nc -z localhost $p 2>/dev/null && echo "Port $p: server running"
done
```

If you can't find the server, ask the user which port their project uses — don't guess. The default in `start-server` is 2233, but per-project scripts often override it.

## Step 2 — Send a request

### The wire format is non-negotiable

**Always wrap your form in `(:form "...")`**. Sending a bare Lisp form via nc can crash the server:

```bash
# CORRECT
echo '(:form "(+ 4 3)" :timeout 5)' | nc -w 10 localhost <PORT>

# WRONG — can kill the server
echo '(+ 4 3)' | nc localhost <PORT>
```

### nc flags

- **Always use `-w N`** (client-side timeout in seconds).
- **Never use `-q`** — it's GNU-netcat-only and silently doesn't exist on macOS or OpenBSD.
- **Never redirect stderr to `/dev/null`** — connection-level errors print there; the server's *actual* error text comes back inside the response on stdout. Suppress stderr and you'll see an empty response with no clue why.

### Timeouts: prefer `:timeout` inside the form

Two ways to bound execution. The server-side `:timeout` is cleaner — it breaks the computation with a proper unwind. `nc -w` only kills the client socket, leaving the server-side eval running.

```bash
# Preferred: :timeout inside the form, nc -w slightly higher as safety net.
echo '(:form "(run-bench)" :timeout 60)' | nc -w 65 localhost <PORT>
```

Both string `"60"` and number `60` work for `:timeout` in current versions.

### REPL commands don't work in `:form`

`:cl` and `:ld` are ACL top-level REPL commands, **not Lisp forms**. They appear to succeed via the eval server but actually no-op, leading to confusing "undefined function" errors later.

```bash
# WRONG — silent no-op
echo '(:form ":cl test/foo")' | nc -w 5 localhost <PORT>

# CORRECT
echo '(:form "(load (compile-file \"<abs-path>/test/foo.cl\"))")' | nc -w 30 localhost <PORT>
```

### Response shape

Lisp-mode response is an alist:

```
(("success" . "ok") ("result" . "7")
 ("output" . "") ("error-output" . ""))
```

| Key            | Meaning                                                          |
|----------------|------------------------------------------------------------------|
| `success`      | `"ok"` or `"error"`. Always check before trusting `result`.      |
| `result`       | Stringified return value (ok) or error message (error).          |
| `output`       | Everything printed to `*standard-output*` during eval.           |
| `error-output` | Everything printed to `*error-output*` during eval.              |
| `backtrace`    | First 50 frames — only present on error.                         |

JSON wire format also works (request starts with `{`, response comes back JSON). Stick with Lisp form unless the caller specifically needs JSON.

## Step 3 — Common request shapes

```bash
# Compile + load (preferred for any file you've just edited — but read the
# Hot-reload Discipline section below first if the file is in the load chain).
echo '(:form "(load (compile-file \"<abs-path>/foo.cl\"))" :timeout 30)' \
  | nc -w 35 localhost <PORT>

# Set package — sticky across subsequent connections on this server.
echo '(:package "my-pkg" :form "(some-function)")' | nc -w 5 localhost <PORT>

# Compile + eval a form (faster than interpreter for hot code).
echo '(:form "(run-benchmark)" :compile "yes" :timeout 60)' | nc -w 65 localhost <PORT>

# Interrupt all other running evaluators, then run this form.
echo '(:reset "yes" :form "(room t)")' | nc -w 5 localhost <PORT>

# Orderly shutdown (deletes lock file, then exit). Avoid `kill` when this works.
echo '(:exit t)' | nc -w 5 localhost <PORT>

# Just switch package without evaluating anything.
echo '(:package "my-pkg")' | nc -w 5 localhost <PORT>
```

For forms longer than a few lines, write them to a scratch file and `(load "/tmp/scratch.cl")` instead of embedding huge S-expressions in shell command lines — bash quoting hell awaits.

## Step 4 — One-time reader macro setup

Some projects need a reader macro enabled at session start. For AllegroGraph syntax (`!foo:bar`):

```bash
echo '(:form "(enable-!-reader)" :package "db.agraph.user")' \
  | nc -w 5 localhost <PORT>
```

Do this **once per server lifetime** — the readtable is copied at server startup and the change sticks.

## Hot-reload discipline — when you can recompile, when you must restart

**Bare rule**: don't `(load (compile-file …))` a file that's already in the project's startup load chain. Doubly-loading core files can redefine `defstruct`s, methods, and packages in place and silently corrupt the running image. Symptoms: weird type errors, methods firing on wrong classes, slot offsets shifted by one.

But there are **two sanctioned exceptions** worth knowing — restarting costs ~30 s per cycle, which adds up.

### Exception A — defun-only edits (the common case)

When your diff contains **only `defun` forms**, hot-recompile is safe. Lisp `defun` just replaces the function binding; existing compiled callers pick up the new definition on their next call.

Verify with a pre-edit grep:

```bash
git diff path/to/changed-file.cl \
  | grep -E '^[+-]\(def(struct|class|method|generic|macro|var|parameter|package)|^[+-]\(in-package'
```

- Empty match → defun-only → recompile-and-load is safe:

  ```lisp
  (load (compile-file "<abs-path>/changed-file.cl"))
  ```

- Anything matches → restart instead. Specifically dangerous: `defstruct` slot changes, new/changed `defmethod`/`defgeneric`, `defmacro` (callers' compiled code is stale), `defparameter` clobbering live state, package edits.

### Exception B — let-bind a compile-time debug parameter

When you want to bump a compile-time debug param (e.g. `*rule-debug*`) so the file's macros re-expand at the higher level:

```lisp
(let ((*rule-debug* 2))
  (load (compile-file "<abs-path>/some-file.cl")))
```

The let-binding scopes the change to this compile-file invocation only. Run the same form with the level bound back to 0 when done.

### Verify hot-patches against source after restart

If you bypass the rule by sending a raw `(defun foo …)` over the eval server (rather than recompile-and-load), the source file and running image are now two separate copies. Before committing:

1. **Diff the source against what you sent** — must be byte-identical in the changed region. The eval-server response shows the sent form, not what's in memory.
2. **Ask the user to restart**, then re-run tests against the fasl-loaded image. Don't trust passes from a hot-patched image.
3. Backquote / cut symbols in Prolog clause emission are especially error-prone (`'\!` vs `''\!`, `,'\!` vs `,@'\!`). Read the diff character by character.

Real incident: a hot-patch with `''\!` (yields `(quote !)`, not `!`) passed all tests in memory but broke on next restart when the fasl rebuilt from the bad source. If a fresh-restart run can't be requested before commit, mark the commit as "tested against hot-patched image only — verify on next restart".

## Load file discipline

Two recurring footguns specific to project loader scripts:

### Never compile `load.cl` (or any orchestrator)

Load files exist only to enumerate `(load-compiled-load-pathname ...)` calls. They have no hot code paths and produce zero runtime benefit from compilation. Compile the *children* they enumerate, never the load file itself.

When editing `load.cl` (e.g. adding a new module line), do NOT then `compile-file` it.

### Delete stale `load.fasl` after editing `load.cl`

ACL's `:ld` loads whichever is newer — source or fasl. If `load.fasl` is newer than `load.cl` (from a previous compilation), `:ld` uses the old fasl and silently skips any new entries you added. Symptoms: "undefined function" errors for symbols that obviously exist in the source.

After any edit to `load.cl`:

```bash
rm path/to/load.fasl
```

Then restart. The next load reads the source directly.

## Other common pitfalls

- **Working directory is `mlisp`'s startup cwd**, not your project root. Use absolute paths for all `load` / `compile-file` calls.
- **Stale `.fasl` files** beyond just `load.fasl`: a fasl built before a loader update can silently ship stale code. When suspicious, do `(load (compile-file "..."))` on the source path and delete suspicious old fasls by hand.
- **Symbol interning into wrong package**: `(read-from-string "foo")` interns `FOO` into the current `*my-package*`. Use `(intern "FOO" :explicit-package)` if it matters.
- **ACL modern mode case sensitivity**: Allegro CL is case-preserving lowercase. `(find-symbol "DEFAULT-GRAPH-UPI")` returns nil; you need `(find-symbol "default-graph-upi")`. Comes up when introspecting the image via eval.
- **`success: "error"` on the wrong key**: if the server was started with `:key`, every request needs matching `:key "..."` — otherwise `result: "incorrect key given"`.
- **Concurrent requests share `*my-package*`**: requests run in separate threads but `*my-package*` is global. Last writer wins. Rarely matters with a single Claude driving.
- **Check parens after big changes**: unbalanced parens cause cryptic "eof encountered" errors. After any large `.cl` edit, verify paren balance before sending the load form.

## Server lifecycle

Servers should be started with `:lock-file` so restart is idempotent — a new server SIGKILLs the recorded PID, deletes the lock file, and writes its own. Plus `:reuse-address t` on the listening socket means a fresh bind succeeds even with TIME_WAIT sockets lingering.

```bash
# typical project start-server.sh pattern
mlisp -batch -e '(progn
  (load (compile-file "<eval-server-jkf>/es"))
  (user::start-server
    :port <PORT>
    :lock-file "/tmp/<project>-cl.pid"
    :log-file  "/tmp/<project>-cl.log"))' &
```

`tail -f /tmp/<project>-cl.log` is the single best way to watch the server work while you drive it. Stdout and stderr are tee'd into the log via broadcast streams, so compiler messages, test output, and warnings appear in real time.

### Three-strikes rule for restart failures

If `start-server` (or the project's start script) fails three times in a row — mlisp won't start, the load chokes, the bind keeps failing — **stop and ask the user**. Don't burn cycles chasing transient weirdness. Users often run many ACL processes simultaneously (Emacs ELI sessions, other servers); they're best placed to decide what to keep alive.

## Not to be confused with `/graphtalker`

| Feature             | `/lispeval` (jkf)                            | `/graphtalker`                              |
|---------------------|----------------------------------------------|---------------------------------------------|
| Transport           | TCP via `nc`                                  | HTTP via `requests` (Python client)        |
| Wire format         | Lisp plist/alist (or JSON)                    | JSON over HTTP POST                        |
| Concurrency         | Per-connection threads                        | Single shared session                      |
| Default port        | 2233                                          | 8080                                       |
| Auth                | Optional `:key` shared secret                 | Optional Bearer API key                    |
| Sticky state        | `*my-package*` persists across connections    | `*conversation-history*` shared globally   |
| Reload safety       | Restart for master-chain edits (with 2 narrow exceptions) | `start-server.sh` reloads `.cl` source |
| Use for             | General Lisp eval (ims2026, sister projects)  | AllegroGraph + federated SQL/NoSQL queries |

When in doubt about which one to invoke: if the project has a `start-server.sh` (or equivalent) that loads jkf's `es.cl`, use `/lispeval`. If it's a GraphTalker project, use `/graphtalker`.

## Discovering more

The canonical guide covers everything not in this skill:

```bash
cat "${EVAL_SERVER_JKF_DIR:-<eval-server-jkf>}/CLAUDE-EVAL-SERVER-GUIDE.md"
```

Notable topics in the guide:
- Full `start-server` argument table (`:detach`, `:standalone`, etc.)
- Complete per-request option list
- Eval-server-safe code checklist
- Lisp-side client (`es::call-evalserver`)
- Log file format details

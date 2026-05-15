# Using the ACL Eval Server with Claude Code

A guide for setting up and writing Lisp projects that work with remote
evaluation via the eval server, enabling Claude (or any client) to
compile, load, and test code autonomously.

Current server version: **1.3** (see `*evalserver-version*` in
`es.cl`).  1.3 adds `:reuse-address t` on the listening socket and a
`:lock-file` startup argument (plus the matching `:exit` request
option).  Together these replace the old `kill + TIME_WAIT wait` dance
that used to haunt WSL2 restarts.

---

## Two separate layers of options

The eval server has **two different sets of options** that are easy to
confuse:

1. **Startup keyword arguments to `start-server`** — Lisp keywords
   passed when the server process is launched.  Examples: `:port`,
   `:lock-file`, `:log-file`, `:detach`.  They shape the server's
   lifetime and I/O.
2. **Per-request options on the wire** — key/value pairs inside the
   message that each client sends over TCP.  Examples: `:form`,
   `:package`, `:compile`, `:timeout`, `:exit`.  They control what
   happens for that one evaluation.

The comment block at the top of `es.cl` lists only the per-request
options.  The `start-server` arguments are documented in this guide.

---

## 1. Starting the Server

Minimal launch:

```bash
mlisp -batch -e '(progn
  (load (compile-file "~/dropboxlisp/eval-server-jkf/es"))
  (user::start-server))'
```

The server listens on port 2233 by default and copies the readtable
internally, so reader-macro modifications (e.g. `enable-!-reader`)
take effect without any extra client-side setup.

### `start-server` keyword arguments

All arguments are optional:

| Argument      | Default                | Purpose                                                                 |
|---------------|------------------------|-------------------------------------------------------------------------|
| `:port`       | `2233`                 | TCP port to listen on.                                                  |
| `:key`        | `""` (disabled)        | Shared-secret string.  If set, every request must include a matching `:key`. |
| `:log-file`   | `nil`                  | Absolute path; appends every request (form + result + stdout/stderr) to the file. Line-buffered, so `tail -f` works live. |
| `:lock-file`  | `nil`                  | Absolute path to a PID file.  If the file already exists at startup, the server SIGKILLs the recorded PID, sleeps 2 s, deletes the file, then writes its own PID.  Guarantees clean restart. |
| `:detach`     | `nil`                  | If true, `fork()`s into the background, detaches from the terminal, and calls `setpgid(0,0)`.  The parent `exit`s immediately.  Pair with `:log-file` for observability. |
| `:standalone` | `nil`                  | If true, a bind failure prints to `*error-output*` and calls `(exit 1 :no-unwind t)`.  If false (the default), a bind failure `error`s normally — the right choice when you're launching the server from a larger Lisp image. |

Examples:

```bash
# Project-scoped eval server with lock file and log file — recommended.
mlisp -batch -e '(progn
  (load (compile-file "~/dropboxlisp/eval-server-jkf/es"))
  (user::start-server
    :port 2244
    :lock-file "/tmp/ims2026-cl.pid"
    :log-file  "/tmp/ims2026-cl.log"))'
```

```bash
# Detach into the background, write both files, exit parent immediately.
mlisp -batch -e '(progn
  (load (compile-file "~/dropboxlisp/eval-server-jkf/es"))
  (user::start-server
    :port 2244
    :detach t
    :standalone t
    :lock-file "/tmp/ims2026-cl.pid"
    :log-file  "/tmp/ims2026-cl.log"))' &
```

### Why `:lock-file` matters

Before 1.3, bringing the server back up after an edit meant:

1. `kill` (or `fuser -k`) the running Lisp.
2. Wait for the listening socket to leave `TIME_WAIT`.
3. Launch a new Lisp.

Step 2 was flaky on WSL2 — sometimes a fresh bind would fail for tens
of seconds.  Version 1.3 fixes both halves:

- The listening socket is now opened with `:reuse-address t`, so a new
  bind succeeds even while old sockets linger in `TIME_WAIT`.
- Passing `:lock-file` makes the *new* server kill the *old* one on
  startup, so you don't need a separate kill step at all.

**Net effect:** if your project always starts its server with a lock
file, a simple `./start-server.sh` is idempotent — it replaces the
previous server cleanly every time.

---

## 2. The Wire Protocol

### Connection model

Each TCP connection carries exactly one request and one response.  The
server **spawns a fresh Lisp process (`mp:process-run-function`) per
connection**, so multiple clients can run evaluations concurrently.
Note that `*my-readtable*` and `*my-package*` are shared mutable
globals, so two concurrent `:package` updates race (last writer wins).
In single-client usage — Claude, an editor — this is never a problem.

### Two wire formats

The server auto-detects the input format from the first non-blank
character:

- **Lisp form** — starts with `(`.  The server reads a single
  S-expression with `*read-eval*` off (safer — no `#.` evaluation).
  Both plist and alist shapes work:

  ```
  (:form "(+ 3 4)" :package "db.agraph.user")
  (("form" . "(+ 3 4)") ("package" . "db.agraph.user"))
  ```

- **JSON object** — starts with `{`.  Parsed with `st-json`; the
  response comes back as JSON.

  ```
  {"form": "(+ 3 4)", "package": "db.agraph.user"}
  ```

Responses mirror the input format: Lisp request → Lisp alist response,
JSON request → JSON object response.

### Sending a request from the shell

```bash
echo '(:form "(+ 4 3)")' | nc -w 5 localhost 2233
```

Always set a client-side timeout with `nc -w N`.  Avoid `nc -q N` —
it's a GNU-netcat-only flag and doesn't exist on BSD netcat or
OpenBSD's `nc`.

---

## 3. Per-Request Options

All keys are optional unless noted.

| Option      | Value                     | Description                                                                 |
|-------------|---------------------------|-----------------------------------------------------------------------------|
| `:form`     | string                    | Lisp form to read and evaluate.  If omitted, the server evaluates `nil`.    |
| `:package`  | string (package name)     | Sets the read/print package.  **Sticky** — persists across subsequent connections.  May be sent alone (without `:form`) if you just want to switch packages.  If the named package doesn't exist, returns an error without crashing the server. |
| `:compile`  | `"yes"`                   | Compile the form and `funcall` it instead of `eval`-ing it.  Recommended for machine-generated code or hot loops. |
| `:timeout`  | seconds — string or number | Server-side timeout via `mp::with-timeout`.  Both `"30"` and `30` work in current versions (the old "string required" restriction is gone).  On timeout you get `success: "error"` and a `result` saying the expression timed out. |
| `:reset`    | `"yes"`                   | Before evaluating the current form, interrupt every *other* running evaluator on this server with an error.  Useful when a previous long-running form is stuck. |
| `:exit`     | anything truthy           | Shut the server down cleanly: delete the lock file (if any), then `(exit 0 :no-unwind t)`.  The current connection gets no response — the process dies first.  Use this instead of `kill` when you need an orderly shutdown. |
| `:key`      | string                    | Shared secret.  Required when the server was started with `:key`; rejected with `success: "error"` on mismatch. |

### Examples

```bash
# Simple evaluation.
echo '(:form "(+ 4 3)")' | nc -w 5 localhost 2233

# Set package once — it sticks for this server.
echo '(:package "db.agraph.user" :form "(enable-!-reader)")' \
  | nc -w 5 localhost 2233

# Compile + eval, with server-side timeout (both forms work).
echo '(:form "(run-bench)" :compile "yes" :timeout "60")' \
  | nc -w 65 localhost 2233
echo '(:form "(run-bench)" :compile "yes" :timeout 60)' \
  | nc -w 65 localhost 2233

# Clear a stuck evaluator, then run a fresh form.
echo '(:reset "yes" :form "(room t)")' | nc -w 5 localhost 2233

# Orderly shutdown.
echo '(:exit t)' | nc -w 5 localhost 2233

# JSON input + JSON output.
echo '{"form": "(+ 1 2)"}' | nc -w 5 localhost 2233

# Switch package without evaluating anything — :form defaults to nil.
echo '(:package "db.agraph.user")' | nc -w 5 localhost 2233
```

---

## 4. Response Format

Lisp-mode responses are alists, printed with `write-to-string`:

```
(("success" . "ok") ("result" . "7")
 ("output" . "") ("error-output" . ""))
```

On error:

```
(("success" . "error")
 ("result"  . "evaluation resulted in error: ...")
 ("backtrace" . "..."))
```

| Key            | Meaning                                                                       |
|----------------|-------------------------------------------------------------------------------|
| `success`      | `"ok"` or `"error"`.                                                          |
| `result`       | Stringified return value (ok) or error message (error).                        |
| `backtrace`    | First 50 frames of the backtrace — only present on error.                      |
| `output`       | Everything printed to `*standard-output*` during evaluation.                    |
| `error-output` | Everything printed to `*error-output*` during evaluation.                       |

JSON-mode responses are the same shape, encoded as a JSON object with
string values.

Do **not** redirect stderr of your `nc` invocation to `/dev/null`.  The
server's actual error text arrives inside the response payload on
stdout, but netcat and the shell may report connection-level issues
on stderr — if you suppress them you'll see an empty reply and no
clue why.

---

## 5. Lifecycle: Restart and Shutdown

With a lock file, the recommended pattern is a single script that you
can re-run at will:

```bash
#!/bin/bash
# start-my-eval-server.sh
PORT=${1:-2244}
LOCK="/tmp/my-project-cl.pid"
LOG="/tmp/my-project-cl.log"

mlisp -batch -e "(progn
  (load (compile-file \"~/dropboxlisp/eval-server-jkf/es\"))
  (user::start-server
    :port ${PORT}
    :lock-file \"${LOCK}\"
    :log-file  \"${LOG}\"))" &

# Wait for the port to come up, then push project setup.
until nc -z localhost ${PORT}; do sleep 0.2; done
echo "(:form \"(load \\\"/abs/path/to/load.cl\\\")\")" \
  | nc -w 30 localhost ${PORT}
echo '(:package "my-pkg" :form "(enable-!-reader)")' \
  | nc -w 5 localhost ${PORT}
```

Re-running the script kills the previous server via the lock file and
brings up a fresh one on the same port.

To shut down without restarting (e.g. before a reboot), ask the server
to exit:

```bash
echo '(:exit t)' | nc -w 5 localhost 2244
```

The server deletes its lock file before exiting, so the next startup
won't try to SIGKILL a PID that's already gone.

---

## 6. The Log File

When started with `:log-file`, the server writes every interaction in
append-only, line-buffered form:

```
--- eval (load "/abs/path/to/foo.cl") ---
<any stdout/stderr printed during evaluation>
<ans>
--- eval (test-foo) ---
...
```

`tail -f` on this file is the single best way to watch what's going on
inside the server when Claude (or a script) is driving it.  Stdout and
stderr are tee'd into the log via broadcast streams, so you see
compiler messages, test output, and warnings in real time.

---

## 7. Access Control (`:key`)

Launch the server with a shared secret:

```lisp
(user::start-server :port 2244 :key "hunter2")
```

Every request must include a matching key:

```bash
echo '(:key "hunter2" :form "(+ 1 1)")' | nc -w 5 localhost 2244
```

A missing or wrong key returns `success: "error"` with
`result: "incorrect key given"`.  Empty string (the default) means
access control is disabled.

Note: the protocol has no transport encryption, so `:key` only defends
against accidental use from other tools on the same host — not against
anyone who can see your loopback traffic.

---

## 8. Lisp-Side Client

For in-Lisp clients, `es.cl` exports `call-evalserver`:

```lisp
(es::call-evalserver '(+ 3 4) "localhost" 2244)
;; => 7

(es::call-evalserver '(bad-form) "localhost" 2244)
;; => prints "Error occured" plus a backtrace to *standard-output*.
```

It does `read-from-string` on the server's `"result"` string and
returns the value (on success), so arbitrary Lisp values round-trip as
long as they print readably.

---

## 9. Known Pitfalls

### 9.1 The `!` reader macro is per-readtable

The server copies the readtable once at startup, so enabling reader
macros like AG's `!` is a one-time step:

```bash
echo '(:form "(enable-!-reader)")' | nc -w 5 localhost 2244
```

After this, all subsequent forms on that server can use `!foo:bar`.

### 9.2 `read-from-string` interns into `*package*`

Any code that dynamically builds symbols — Prolog functor generators,
CLOS method combinators, etc. — will intern them into whatever
`*package*` is active when the form runs.  Under the eval server
that's `*my-package*`, which is whatever was most recently set via
`:package`.  To avoid surprises, always bind `*package*` explicitly:

```lisp
;; BAD — symbol lands in whatever *package* happens to be.
(defun make-accessor (field)
  (read-from-string (format nil "get-~a" field)))

;; GOOD — use intern with an explicit package.
(defun make-accessor (field)
  (intern (format nil "get-~a" field) :my-package))
```

### 9.3 `eval` is interpreted — prefer `:compile "yes"` for hot code

Forms evaluated with `eval` run in the interpreter — slower and more
GC pressure than compiled code, which matters for query compilers and
DSLs.  Either pass `:compile "yes"` from the client, or in your Lisp
source wrap generated forms:

```lisp
;; Good — compile to native code, then call.
(funcall (compile nil `(lambda () ,generated-form)))
```

### 9.4 Working directory is wherever `mlisp` was started

Not wherever your project lives.  Use absolute paths for `load` /
`compile-file`, or set `*default-pathname-defaults*` once at startup:

```lisp
(setq *default-pathname-defaults* #P"/abs/path/to/project/")
```

### 9.5 Concurrent requests share `*my-package*`

Requests run in separate threads, but `*my-package*` is global.  If
two clients change the package simultaneously, the result is
last-writer-wins.  In practice this only matters if you script
multiple clients against the same server — Claude uses one connection
at a time and is unaffected.

### 9.6 Stale `.fasl` files

ACL's `:ld` loads whichever is newer — source or fasl — but if a fasl
was built before you added new files to a loader script, the fasl can
silently ship the old version.  Via the eval server, always use
`(load (compile-file "..."))` on the `.cl` path to force a rebuild,
and delete stale `load.fasl` files by hand when in doubt.

### 9.7 Never reload master-chain files through the eval server

(Project-specific — this is an IMS2026 rule but the logic applies to
any long-loaded Lisp image.)  If a file is in the startup load chain
of your project, it's already loaded.  Re-compiling and re-loading it
through the eval server can redefine `defstruct`s and generic
functions in place and corrupt the running image.  **Restart the
server instead.**  Files that are not in the load chain — one-off test
scripts, scratch experiments — are safe to `(load (compile-file …))`
via the eval server.

---

## 10. Recommended Project Load Pattern

```lisp
;; my-project/load.cl

(eval-when (load compile eval)
  (require :agraph "/path/to/agraph.fasl"))

(in-package :my-package)

(defun load-module (name)
  (let* ((dir (directory-namestring
                (or *load-pathname* *default-pathname-defaults*)))
         (path (merge-pathnames name dir)))
    (load (compile-file path))))

(load-module "core/base.cl")
(load-module "core/utils.cl")
;; ...
```

No readtable copy needed at the top — the server does it for you.

---

## 11. Eval-Server-Safe Code Checklist

- [ ] No `read-from-string` for symbol creation without an explicit
      `*package*` binding or a direct `intern` with a package argument.
- [ ] No reader-macro installs on shared readtables after the server
      starts (the initial copy is fine; later loads may not see it).
- [ ] No assumptions about `*package*` being a particular value —
      always bind locally when it matters.
- [ ] Hot paths use `compile` + `funcall`, not `eval`.
- [ ] File paths are absolute or relative to `*load-pathname*`.
- [ ] Long-running work accepts `:timeout` or breaks into steps.
- [ ] Loader scripts stay in sync with their `.fasl`s — delete stale
      fasls.
- [ ] Restart rather than hot-reload anything already in the master
      load chain.

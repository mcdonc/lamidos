# lamidos agent instructions

Project-specific guidance for coding agents working in this repo.

## Prefix most commands with `devenv --quiet shell --`

Lamidos uses [devenv](https://devenv.sh) (Nix-based) for its dev
environment. **Every command that touches the project toolchain must
be run through the devenv shell**, including git. The toolchain —
Python venv, ruff, pre-commit hooks, etc. — only exists inside the
shell.

```bash
devenv --quiet -O dotenv.enable:bool false shell -- git commit -m "..."
devenv --quiet -O dotenv.enable:bool false shell -- unit-tests
```

The flags: `--quiet` suppresses noisy devenv output; `-O
dotenv.enable:bool false` prevents devenv from loading `.env`
(which can interfere with test environments that set their own env
vars via monkeypatch). `shell --` launches an ephemeral shell with
the full environment, runs the command, and exits — this is the
pattern agents should use for one-off commands. (`devenv shell`
with no `--` drops into an interactive shell; not useful for
non-interactive agents.) This applies to **all** commands: builds,
tests, lint, `git`, `gh`.

## Never run project Python on the ambient interpreter

`python3` outside the devenv shell is whatever the host happens to
provide, while the project pins 3.14 (`devenv.nix`,
`languages.python.package`). A bare `python3 -c`, or a heredoc
piped into `python3`, used to inspect, parse, or run anything from
this repo — even a one-liner like `ast.parse(open(f).read())` —
yields false failures or validates against the wrong semantics.
Every Python invocation, however small, goes through the shell:

```bash
devenv --quiet -O dotenv.enable:bool false shell -- python -c "..."
```

Inside the shell, `python` and `python3` both resolve to the venv's
3.14 with the project's dependencies installed.

## Naming: no leading underscores on helper functions

Module-level helper functions are named without a leading underscore
(`resolve_path`, not `_resolve_path`). The prefix buys nothing at
module scope — there are no star imports and the modules are small —
and the complexity-gate splits create many single-use helpers where
it reads as ceremony. Underscores stay on names that genuinely
shadow or collude with builtins.

## Exception handling: no bare return from a raw catch

A handler that catches the raw `Exception` class must not answer
with an implicit `None`: neither a bare `return` nor `return None`.
The same holds for `BaseException` and for a bare `except:`, which
also traps `KeyboardInterrupt` and `SystemExit`. The silent `None`
turns every error into the same answer: a missing volume and a
`TypeError` vanish the same way, and the caller cannot tell a
failure from an answer.

```python
Wrong:
    try:
        node = self.fs.resolve(path)
    except Exception:
        return

Right:
    try:
        node = self.fs.resolve(path)
    except FsError:
        return  # the listing's own error line names the failure
```

Catch the narrowest type the call can actually raise: the seam's
named error (`FsError` for a filesystem exchange, `CmdError` for a
command) , `OSError` for a file read, `subprocess.SubprocessError`
for a child process. When a failure must be absorbed, make it
visible somewhere: log it, print it, or return an explicit failure
value. A handler that prints or logs the error first is fine. Its
`return` is control flow, not the answer.

Two designs keep the raw catch, and the comment beside it names the
design: a best-effort probe (any failure it touches is the
caller's silence) and a fire-and-forget task (a raising body must
not reach the REPL loop).

The rule governs shipped code under `src/lamidos/lamidos/`. A test
helper may flatten every failure into a sentinel value; that is the
harness's own contract, not a swallow.

## Coverage gates

Local `unit-tests` reproduces the CI coverage gate exactly at the
same tree. The suite runs under pytest-xdist (`-n auto`) with the
sysmon coverage core (`conftest.py` pins `COVERAGE_CORE=sysmon`):
a single-process run under-counts branch coverage on 3.14, so
always read the parallel run's total. Run it on the tree being
pushed: commit first, or
confirm `git status --porcelain` is empty. Any change after the
last run — including a post-review `--amend` — requires re-running
it. If CI reports a gap local runs missed, the gap is real: check
out the failing commit and write the pinning test.

## Pre-flight the commit gates before the first commit attempt

The pre-commit hooks run their gates over the staged tree at commit
time; each rejection costs a full edit → test → commit round, and
reading one gate's failure at a time grows a one-offender-per-round
loop. `lamidos-preflight` delivers the same feedback before the
first commit attempt, all offenders at once:

```bash
devenv --quiet -O dotenv.enable:bool false shell -- lamidos-preflight
```

It prints every ruff violation, every deferred import, every import
cycle (`scripts/check_import_cycles.py`), every import-graph gate
violation (`scripts/check_import_graph.py` over `import-graph.toml`
— package DAG, ranks, snapshot counts, fan-in ceiling,
reachability, facades), every xenon block above rank A, the jscpd
clone report over the package sources, and every module-length
offender.
When anything under `src/lamidos/` differs from the fork point on
`origin/main` (committed or working tree), it then runs the gated
suite — the `unit-tests` suite under the same coverage gate, with
quiet output and the term-missing report of every uncovered line
and branch arc (`bash scripts/preflight.sh --fast` skips the suite
for an instant lint/complexity pass).

The working rule: run the pre-flight after writing code, fix
EVERYTHING it names in one editing pass, re-run, then commit. A
green pre-flight means the Python gates hold at commit time; the
doc, nix, shell, and yaml hooks still run there, and their failures
name one file and one rule apiece — a single extra round settles
them.

Triage a coverage gap at write time, not after a red gate:

- Reach for deterministic cover first: rigged virtual-filesystem
  state for error paths, tmp dirs for host-filesystem seams.
- A branch the test host cannot reach (platform-specific, or only
  schedulable through a race the suite cannot arrange) takes
  `# pragma: no cover` with a comment naming the reason.

## Import-graph gates

The import graph is checked by gates. Each gate is a rule plus a
small config file, so any codebase can adopt them by writing
config, not code.

- **No cycles.** Modules must not import in circles. Neither may
  packages. A package cycle needs a named exemption; exemptions only
  shrink, never grow.
- **Imports point down.** Each package has a rank number. An import
  may only go from a higher rank to a lower one. A new package gets
  a rank before it gets imports.
- **Coupling only shrinks.** Import counts between each package pair
  are stored in a snapshot file. A count may not grow unless the
  snapshot is updated in the same commit, with the reason.
- **No module is imported by too many others.** A ceiling is recorded
  in a file. When a module hits it, split the module. The ceiling
  only goes down.
- **Shipped code must be reachable.** Every module in the shipped
  package must be imported, directly or indirectly, from a declared
  entry point. Test-only code lives in the test tree.
- **Config files must match the code.** An allowlist entry nothing
  uses fails the gate. Remove it in the same PR that removed its last
  use.
- **Import names from the module that defines them.** Importing
  through a module that only re-exports fails, unless that module is
  on the facade list.

Run the gates after writing code and fix all findings in one pass.
Widening a config file is a deliberate edit: the diff states why.

## Lines gate

`scripts/lines-gate.sh` fails when a module under
`src/lamidos/lamidos/` exceeds the ceiling the script carries
(1,000 lines; the ceiling only goes down). The gate names the file
and its count and does nothing else. Do not grow the file past the
ceiling, and do not reach for the exemption list first.

Split the module into a package. Read it and group what belongs
together: one responsibility per submodule, each submodule's
docstring stating that responsibility. A mechanical cut (midpoint
halves, fixed-size chunks) passes the gate and is still the wrong
split. The import-graph rules apply to the new package: it gets a
rank before it gets imports, and pair counts resnapshot in the same
commit.

`scripts/lines-exemptions.txt` is the last resort, for a file whose
split cannot land in the change that crossed the ceiling. An entry
whose file is at or under the ceiling fails the gate as stale; the
commit that brings a listed file back under removes its entry.

## Changelog (`docs/changes.md`)

`docs/changes.md` is the single source of truth for human-authored
release notes, formatted as
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Version
headings escape the opening bracket (`## \[Unreleased]`,
`## \[v1.2.3] - date`) so Markdown tooling does not parse them as
link references; they render as plain `## [Unreleased]`-style
headings.

Add a bullet under `## \[Unreleased]` **in the same PR that
introduces the change** (not as an afterthought, not after merge).
Use the matching subsection: **Added** for new features, commands,
flags; **Changed** for changed behavior; **Deprecated**,
**Removed**, **Fixed**, **Security** as they arise.

Each entry is **2–4 sentences max**. Lead with the **bold feature
or command name**, then the issue number in parens. State what
changed and what users need to know. Do not include internal
justification, migration history, implementation notes (module
names, internal APIs, code paths), or test infrastructure detail.

Skip entries for: pure internal refactors, test/CI/doc churn with
no user-visible effect, and dependency bumps that don't change
behavior.

Right before a release: rename `## \[Unreleased]` →
`## \[vX.Y.Z] - YYYY-MM-DD`, insert a fresh empty
`## \[Unreleased]` heading above it, bump the version in
`pyproject.toml` (and `uv.lock` via `uv lock`), and commit.

## Worktrees

- When asked to create a worktree, put the worktree inside the
  repository root's `.worktrees` subdirectory. When using a
  worktree, do not commit anything to the main branch or use the
  main repository to commit anything — all commits go on the
  worktree's own branch within the worktree.
- Worktrees should have a directory name no longer than 16
  characters.

## Pull request titles

- Every PR created to address a GitHub issue must include that
  issue's number in the PR title, as a parenthesized suffix — e.g.
  `Add the virtual filesystem (#3)`. GitHub appends the PR's own
  number at squash-merge time, so the issue number in the title is
  what ties the PR back to its originating issue in lists,
  history, and notifications.
- This applies to every PR opened from a `gh issue` (via `/workon`,
  `/stackon`, or directly) — check the title before `gh pr create`.

## Closing the issue on merge

- The PR body must contain the exact phrase `Closes #<issue>` (or
  `Fixes`/`Resolves #<issue>`) for the originating issue. GitHub
  closes the issue automatically only on those keyword forms;
  near-misses such as "closing #2" do nothing, and the issue stays
  open after the merge until someone closes it by hand.
- Put the phrase in its own sentence in the Summary (e.g.
  "Closes #2."), and check the issue state after merging; if it is
  still open, close it with a comment recording the landing
  commits.

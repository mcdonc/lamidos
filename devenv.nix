{
  pkgs,
  config,
  lib,
  ...
}:
let
  # jscpd token-clone scanner (ported from msks, originally klangk
  # #2904): 5.x ships a prebuilt Rust binary via platform-specific
  # npm packages (esbuild-style), so it is not in nixpkgs; pin the
  # binary per platform with fixed hashes (the fmtk pattern). One
  # pinned version keeps clone reports reproducible across
  # contributors and CI. The `lamidos-jscpd` script and the
  # pre-commit gate hook run it over the package. Any platform not
  # pinned here fails at eval time instead of silently installing a
  # foreign-arch binary.
  jscpdBinaryVersion = "5.0.16";
  jscpd = pkgs.stdenv.mkDerivation {
    pname = "jscpd";
    version = jscpdBinaryVersion;
    src = pkgs.fetchurl {
      url =
        if pkgs.stdenv.isDarwin then
          "https://registry.npmjs.org/jscpd-darwin-"
          + (if pkgs.stdenv.hostPlatform.darwinArch == "arm64" then "arm64" else "x64")
          + "/-/jscpd-darwin-"
          + (if pkgs.stdenv.hostPlatform.darwinArch == "arm64" then "arm64" else "x64")
          + "-${jscpdBinaryVersion}.tgz"
        else if pkgs.stdenv.hostPlatform.isx86_64 then
          "https://registry.npmjs.org/jscpd-linux-x64-gnu/-/jscpd-linux-x64-gnu-${jscpdBinaryVersion}.tgz"
        else if pkgs.stdenv.hostPlatform.isAarch64 then
          "https://registry.npmjs.org/jscpd-linux-arm64-gnu/-/jscpd-linux-arm64-gnu-${jscpdBinaryVersion}.tgz"
        else
          throw "jscpd: no prebuilt binary for ${pkgs.stdenv.hostPlatform.system}";
      hash =
        if pkgs.stdenv.isDarwin then
          (
            if pkgs.stdenv.hostPlatform.darwinArch == "arm64" then
              "sha256-vntXwMkns8HqtHwVzxthzun0tpRAe755YKB5k4c3Wqg="
            else
              "sha256-X2hK+EAgrXGRLUymdo5qgTuWoFQ3U0cz9J064UFQppM="
          )
        else if pkgs.stdenv.hostPlatform.isx86_64 then
          "sha256-+6PhbDzUn0e4sQgsUs/kF0C5HlMOixZvlNolO9a4VdI="
        else
          "sha256-hTlIJMcf3vi8qbJLKR0Txc1a5BOYYjkPc6YWTwCiEEc=";
    };
    sourceRoot = ".";
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
      install -Dm555 -t $out/bin package/bin/jscpd
    '';
  };
in
{
  # lamidos dev environment: Python 3.14 and the msks/klangk gate
  # conventions (AGENTS.md): CI-identical test task, xenon rank-A
  # gate via a single script shared with the pre-commit hook.
  languages.python = {
    enable = true;
    # Pinned to the channel's python314 rather than the `python3`
    # alias — the toolchain version is a project decision, not an
    # accident of the pinned nixpkgs channel's default minor
    # (klangk #2844 precedent).
    package = pkgs.python314;
    venv.enable = true;
    uv = {
      enable = true;
      # sync.enable left off: devenv's sync gate fingerprints only
      # the root pyproject.toml and not uv.lock, so lock-only bumps
      # (uv lock --upgrade) skip sync and the venv goes stale.
      # lamidos:uv-sync below owns dependency sync (klangk
      # workaround, see their devenv.nix).
    };
    directory = ".";
  };

  packages = with pkgs; [
    bash # explicit bash for shell scripts (CI /bin/sh may be dash)
    jscpd # token-clone scanner, pinned rust binary (see above)
    ruff
    # cyclomatic-complexity gate tool: built against python3.14
    # because nixpkgs' top-level xenon runs on an older python
    # whose parser can reject syntax ruff format writes for a
    # 3.14 codebase, silently skipping files (klangk #3411/#3415
    # precedent). scripts/xenon-gate.sh turns any such skip into
    # a hard failure.
    (pkgs.callPackage (pkgs.path + "/pkgs/by-name/xe/xenon/package.nix") {
      python3 = pkgs.python314;
    })
    (python314Packages.radon) # complexity introspection (radon cc)
  ];

  env.UV_PYTHON = config.languages.python.package;

  tasks = {
    # WORKAROUND (klangk pattern): devenv's uv sync gate only hashes
    # the root pyproject.toml, never uv.lock — lock-only changes
    # skip sync and the venv silently goes stale. This task runs
    # `uv sync` unconditionally: on a current venv it is a ~0.1s
    # no-op, cheaper than getting the gate right. `after` pins
    # ordering: the venv must exist before sync, or
    # devenv:python:virtualenv would `rm -rf` the freshly-synced
    # deps.
    "lamidos:uv-sync" = {
      exec = ''
        cd "$DEVENV_ROOT"
        uv sync -p "$UV_PYTHON" --group dev
      '';
      after = [ "devenv:python:virtualenv" ];
      before = [ "devenv:enterShell" ];
    };
    # WORKAROUND (klangk #3444 pattern): devenv 2.3.x's
    # RunMode::All scheduler adds the prerequisites of every
    # visited task — including the skipped devenv:enterTest (it
    # sits `after` enterShell), whose prerequisite
    # devenv:git-hooks:run is the full pre-commit suite — so a
    # failing hook aborts `devenv shell` before it opens. Clearing
    # the `before` edge keeps that task out of the shell's task
    # graph (mkForce replaces the upstream list; a plain
    # `before = [ ]` concatenates with it and changes nothing). The
    # commit-time hook keeps enforcing the suite on `git commit`.
    # Remove this override once an upstream release stops
    # scheduling prerequisites of skipped tasks.
    "devenv:git-hooks:run" = lib.mkIf config.git-hooks.enable {
      before = lib.mkForce [ ];
    };
  };

  # --- lamidos command scripts ---
  # Plain scripts on the shell's PATH: invoked directly from a
  # devenv shell (`lamidos-xenon`) or from outside (`devenv shell --
  # lamidos-xenon`).

  scripts.lamidos-xenon = {
    description = "Complexity gate: rank A everywhere";
    exec = ''exec bash "$DEVENV_ROOT/scripts/xenon-gate.sh" "$@"'';
  };

  scripts.lamidos-jscpd = {
    description = "Token-clone gate over the package";
    exec = ''exec bash "$DEVENV_ROOT/scripts/jscpd-gate.sh" "$@"'';
  };

  scripts.lamidos-lines = {
    description = "Module-length gate: 1000-line ceiling, shrinking exemptions";
    exec = ''exec bash "$DEVENV_ROOT/scripts/lines-gate.sh" "$@"'';
  };

  scripts.lamidos-preflight = {
    description = "All pre-commit offenders in one pass, before the commit attempt (--fast skips the suite)";
    exec = ''exec bash "$DEVENV_ROOT/scripts/preflight.sh" "$@"'';
  };

  # CI-identical full suite: -n auto is how CI runs it. addopts in
  # pyproject.toml carry the coverage flags; the conftest pins
  # COVERAGE_CORE=sysmon.
  scripts.unit-tests.exec = ''
    cd $DEVENV_ROOT
    exec python -m pytest src/lamidos/tests -v -n auto "$@"
  '';

  # --- Pre-commit hooks (the msks suite, lamidos paths) ---
  git-hooks.hooks = {
    # Python: ruff lint + format
    ruff-lint = {
      enable = true;
      name = "ruff check";
      entry = "${pkgs.ruff}/bin/ruff check --fix";
      files = "\\.py$";
      language = "system";
      pass_filenames = true;
    };
    ruff-format = {
      enable = true;
      name = "ruff format";
      entry = "${pkgs.ruff}/bin/ruff format";
      files = "\\.py$";
      language = "system";
      pass_filenames = true;
    };
    # Complexity gate: rank A everywhere. pass_filenames = false —
    # the hook grades the full tree via scripts/xenon-gate.sh (a
    # staged subset's average can exceed 5 while the whole tree
    # passes); `files` stays as the run trigger.
    xenon = {
      enable = true;
      name = "xenon";
      entry = "scripts/xenon-gate.sh";
      files = "^src/lamidos/lamidos/.*\\.py$|^scripts/.*\\.py$";
      language = "system";
      pass_filenames = false;
    };
    # Lines gate: no module under the shipped package past the
    # ceiling scripts/lines-gate.sh carries (1000 today; it only
    # goes down). Over-ceiling files live on the shrinking
    # scripts/lines-exemptions.txt list, which also triggers the
    # hook — a list edit is exactly when the gate should re-run.
    # Whole-tree like xenon above (a staged subset's pass is not
    # the tree's pass); `files` stays as the run trigger.
    lines-gate = {
      enable = true;
      name = "lines-gate";
      entry = "bash scripts/lines-gate.sh";
      files = "^src/lamidos/lamidos/.*\\.py$|^scripts/lines-exemptions\\.txt$";
      language = "system";
      pass_filenames = false;
    };
    # Token-clone gate: no exact clone of >= 70 tokens in the
    # package. pass_filenames = false — cross-file clones only show
    # when the whole tree is scanned (a staged subset can hide
    # them); `files` stays as the run trigger.
    jscpd = {
      enable = true;
      name = "jscpd";
      entry = "scripts/jscpd-gate.sh";
      files = "^src/lamidos/lamidos/.*\\.py$";
      language = "system";
      pass_filenames = false;
    };
    # Deferred-imports gate (klangk's AST checker): imports live at
    # module scope. Plain top-level, ``if TYPE_CHECKING:`` blocks,
    # and module-scope ``try/except ImportError`` guards are exempt;
    # ``# allow-deferred-import`` suppresses an individual import
    # (on the line or the comment line above). Staged files are
    # mapped to their package roots, so the hook scans whole
    # packages. The interpreter is the pinned python from
    # `languages.python` by store path, NOT a bare `python3`:
    # pre-commit prepends its own interpreter's bin to hook PATHs,
    # which cannot parse the project's newer syntax — under a bare
    # `python3` the checker silently skipped the whole backend and
    # passed vacuously in msks (found via the review of their #84).
    # require_serial: one invocation with all files —
    # pass_filenames maps them to package roots, and chunked
    # invocations would rescan (and re-print) the same packages
    # once per chunk. Non-package files (scripts/, tests/) map to
    # no package root and are skipped by design — the msks
    # semantics; xenon still grades scripts/*.py.
    deferred-imports = {
      enable = true;
      name = "deferred-imports";
      entry = "${config.languages.python.package}/bin/python scripts/check_deferred_imports.py";
      files = "\\.py$";
      language = "system";
      pass_filenames = true;
      require_serial = true;
    };
    # Import-cycle gate: the module-level walk lives in
    # scripts/check_import_cycles.py. Whole-tree check, so
    # pass_filenames = false; `files` is the run trigger, matching
    # the xenon idiom above.
    import-cycles = {
      enable = true;
      name = "import-cycles";
      entry = "${config.languages.python.package}/bin/python scripts/check_import_cycles.py";
      files = "^src/lamidos/lamidos/.*\\.py$|^scripts/.*\\.py$";
      language = "system";
      pass_filenames = false;
    };
    # Import-graph gates (AGENTS.md, "Import-graph gates"): six
    # invariants over the same walk, each driven by the checked-in
    # import-graph.toml — the package DAG with a shrinking exemption
    # list, the layer rank map, exact per-pair import counts, the
    # fan-in ceiling, entry-point reachability, and the re-export
    # facade list. Whole-tree check like import-cycles: it triggers
    # on the tree, the walker scripts, or the config file.
    import-graph = {
      enable = true;
      name = "import-graph";
      entry = "${config.languages.python.package}/bin/python scripts/check_import_graph.py";
      files = "^src/lamidos/lamidos/.*\\.py$|^scripts/.*\\.py$|^import-graph\\.toml$";
      language = "system";
      pass_filenames = false;
    };
    # Shell (klangk settings): format + static analysis + the
    # shebang guard on executable text files.
    shfmt.enable = true;
    shfmt.settings.indent = 2;
    check-executables-have-shebangs.enable = true;
    shellcheck.enable = true;
    # Markdown lint (klangk rules). Division of labor with the
    # prettier hook: prettier owns formatting, markdownlint stays a
    # lint-only gate (no --fix) over rules prettier either enforces
    # itself (blank lines around headings/lists, single blank runs,
    # final newline) or never touches (code-fence languages, heading
    # text, duplicate siblings). The three disabled rules are the
    # prettier-owned ones — MD013 line length (prettier preserves
    # prose wrapping and pads table rows past 80), MD034 bare URLs
    # (prettier wraps them in <>), MD060 table-pipe alignment
    # (prettier realigns pipes) — so a prettier-formatted file
    # always passes markdownlint and the two hooks cannot ping-pong.
    # Keep new rules inside that invariant. Passed inline as JSON
    # config; this git-hooks pin takes a structured settings
    # attrset, so no generated .markdownlint.yaml is needed.
    markdownlint.enable = true;
    markdownlint.settings.configuration = {
      MD013 = false;
      MD024.siblings_only = true;
      MD034 = false;
      MD060 = false;
    };
    # GitHub Actions workflows.
    actionlint.enable = true;
    # Secrets: trufflehog over the staged file contents. The pin's
    # stock hook runs `git --since-commit HEAD`, which scans commits
    # strictly newer than HEAD — the empty set at commit time and on
    # any clean checkout, so it can never fail. This entry scans the
    # files pre-commit passes — staged files at commit time, all
    # tracked files under --all-files (what CI runs). Only
    # credentials that verify live fail the commit
    # (--results=verified --fail), so key-shaped test fixtures stay
    # green and offline runs degrade to a pass (verification errors
    # land in `unknown`).
    trufflehog = {
      enable = true;
      name = "trufflehog";
      entry = "${pkgs.trufflehog}/bin/trufflehog filesystem --fail --results=verified";
      language = "system";
      pass_filenames = true;
    };
    # Nix (klangk width).
    nixfmt.enable = true;
    nixfmt.settings.width = 80;
    # TOML: every staged TOML file must parse.
    check-toml.enable = true;
    # YAML (klangk rules): relaxed preset, lines up to 200 columns.
    # Warnings stay non-fatal (strict = false).
    yamllint.enable = true;
    yamllint.settings = {
      configuration = ''
        extends: relaxed
        rules:
          line-length:
            max: 200
      '';
      strict = false;
    };
    # JS/TS/JSON/YAML/Markdown formatting (klangk settings): rewrite
    # in place. Unknown file types (.py, .nix, .sh, .lock) are
    # skipped (--ignore-unknown is this pin's default); the excludes
    # keep lock files out of the file set regardless. Hook ids sort
    # lexicographically in the generated manifest, so this runs
    # after markdownlint/nixfmt but before the ruff hooks — the
    # one-run rewrite dance is harmless either way, because prettier
    # (--ignore-unknown) and ruff touch disjoint file sets. A run
    # that rewrites fails once with "files were modified"; the
    # re-staged run validates the final bytes (see the markdownlint
    # comment for why those bytes always pass).
    prettier = {
      enable = true;
      settings.write = true;
      excludes = [ "\\.lock$" ];
    };
  };

  # Generated (not committed) formatter configs (klangk pattern):
  # enterShell writes .prettierignore so hand-run prettier
  # invocations skip the same trees the hook excludes.
  enterShell = ''
    cat > "$DEVENV_ROOT/.prettierignore" <<'PRETTIER'
    # Lock files are machine-managed (devenv/uv regenerate them);
    # prettier's --ignore-unknown also skips them, this keeps direct
    # prettier runs quiet too.
    *.lock
    .devenv/
    PRETTIER
    # Tidy the state tree: every `devenv shell --` / `devenv tasks
    # run` invocation writes a one-shot wrapper (shell-<hash>.sh)
    # at the top of .devenv/ and leaves it there. The wrapper execs
    # away within milliseconds, so only the just-written current one
    # is ever young — anything past an hour is stale by any measure
    # and goes.
    find "$DEVENV_ROOT/.devenv" -maxdepth 1 -name 'shell-*.sh' -mmin +60 \
      -delete 2>/dev/null || true
  '';
}

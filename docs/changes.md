# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## \[Unreleased]

### Added

- **Project bootstrap (#2).** devenv (Nix) toolchain on nixpkgs
  unstable with pinned Python 3.14, uv-managed venv, the msks
  pre-commit hook suite (ruff, xenon, lines, jscpd,
  deferred-imports, import-cycles, import-graph, shfmt, shellcheck,
  markdownlint, actionlint, trufflehog, nixfmt, check-toml,
  yamllint, prettier), the `lamidos-preflight` one-pass gate
  runner, CI workflows, and the AGENTS.md agent rulebook.

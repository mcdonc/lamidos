# lamidos

An AmigaDOS-style shell emulator: it behaves like the classic
Amiga CLI/Shell — same prompt, commands, path syntax, wildcard
rules, error wording, and scripting — over a virtual filesystem.
It does not run real Amiga programs.

See the [AmigaDOS command reference][1] for the behavior being
emulated.

[1]: https://wiki.amigaos.net/wiki/AmigaOS_Manual:_AmigaDOS_Command_Reference

## Development

The toolchain is [devenv](https://devenv.sh) (Nix-based). Enter a
shell with `devenv shell`, or run one-off commands through it:

```bash
devenv --quiet -O dotenv.enable:bool false shell -- unit-tests
```

See `AGENTS.md` for the full conventions (commit gates, coverage,
changelog).

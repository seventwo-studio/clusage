<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Clusage app icon">
</p>

<h1 align="center">Clusage</h1>

<p align="center">
  <strong>This project is archived and no longer maintained.</strong>
</p>

---

## Status

Clusage is no longer being developed. The repository is kept online as a read-only archive so existing installs keep working and the source remains available, but there will be no further releases, bug fixes, or support.

If you have it installed it will continue to run for as long as macOS and the underlying Claude APIs allow, but you should plan to migrate to one of the alternatives below.

## Alternatives

If you were using Clusage to track your Claude Code usage, these projects are actively maintained and cover most of the same ground:

- **[ccusage](https://github.com/ryoppippi/ccusage)** — A CLI tool that analyzes your local Claude Code (and Codex CLI) JSONL logs. Fast, scriptable, and ships an MCP server. The closest match if you mostly want numbers in the terminal.
- **[Claude Code Usage Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor)** — A real-time TUI monitor with predictions and warnings. The closest match if you liked the always-visible momentum/projection view that Clusage provided.

Neither lives in the macOS menu bar the way Clusage did, but together they cover the underlying use case.

## Why archive?

Clusage relied on Anthropic endpoints that turned out to be too unstable to depend on — connection issues kept breaking usage tracking in ways I couldn't reliably fix. At the same time, the alternatives above have become genuinely good, so a separate macOS menu-bar app no longer earns its keep.

Thanks to everyone who used it, filed issues, and contributed.

## Source

The source remains available under the MIT license. Feel free to fork it if you want to keep a menu-bar tracker alive — but please don't expect upstream updates from this repo.

## License

MIT

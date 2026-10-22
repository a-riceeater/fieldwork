# Third-party notices

Fieldwork's own code is licensed under the Apache License 2.0 (see `LICENSE`).

## Bundled components

| Component | Location | License |
|---|---|---|
| SQLite 3.46.1 amalgamation | `packages/DrillDocument/Sources/CSQLite/` | Public domain ([sqlite.org/copyright.html](https://www.sqlite.org/copyright.html)) |
| 3du-converter (Git submodule, built into `Contents/MacOS/3du-converter`) | `vendor/3du-converter/` | MIT or Apache-2.0. Its binary also contains SQLite (public domain, through `rusqlite`) and the MIT/Apache-2.0 Rust crates in its `Cargo.lock`. |

There is no other third-party source code in the repository. The converter's source is not copied here; the submodule only points at its repository. In particular:

- No OpenMarch (AGPL-3.0 / GPL-3.0) or Pyware code has been copied, translated or adapted. Future `.dots` interoperability will be written independently from documented behavior and real fixtures.
- The ZIP, SHA-256, CRC-32, WAV and PDF implementations are original code.
- Fonts: the Mac app uses the system font through the platform API. No Apple fonts, SF Symbols or other font files are redistributed. Windows will use Segoe UI Variable, or Inter shipped with its SIL OFL notice.

## Platform runtimes (not redistributed in this repository)

- Swift runtime and Foundation on Windows: they come with the Swift toolchain (Apache License 2.0 with Runtime Library Exception). A packaged Windows app must ship them from the toolchain's `Redistributables` folder together with their notices.
- .NET (MIT) for the C# interop smoke test.

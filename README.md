# NotepadMac

A fast, lightweight text editor for macOS — one document per window, regex-based syntax highlighting, and a search & replace sheet with regular-expression support. Built natively in Swift + AppKit (no SwiftUI dependency), packaged as a launchable `.app` bundle via `build_app.sh`.

[MIT licensed](LICENSE) · [Security policy](SECURITY.md) · [Contributing](CONTRIBUTING.md)

## Requirements

| Component | Minimum version |
|---|---|
| macOS | 13.0 (Ventura) or later |
| Xcode Command Line Tools / Swift toolchain | Swift 5.9 or later (`xcode-select --install`) |

No other dependencies — the project uses only Apple's frameworks and builds with plain SwiftPM.

## Quick start

### 1. Build & run (debug, fast iteration)

```bash
cd Notepad-Mac
swift run NotepadMac
```

Or launch the compiled binary directly:

```bash
swift build
.build/debug/NotepadMac
```

Useful flags:

| Command | Effect |
|---|---|
| `swift run NotepadMac --selftest` | Runs offline unit tests for search & encoding, prints `SELFTEST PASSED`, exits |
| `.build/debug/NotepadMac /path/to/file.txt` | Opens a specific file in a new window on launch |

### 2. Build the release app bundle (what you double-click)

```bash
./build_app.sh
```

This produces a self-contained macOS application at:

```
build/NotepadMac.app
```

Launch it any of these ways:

```bash
open build/NotepadMac.app                        # from terminal
# or simply double-click "NotepadMac.app" in Finder
```

> **Tip:** for day-to-day development use `swift run NotepadMac` (compile ≈ seconds). Use `./build_app.sh` when you want a distributable `.app` to move around, install, or share.

## Features

- **Multi-window editor** — every document gets its own resizable window; close one without affecting the others
- **15 languages with regex syntax highlighting** — Plain text, C/C++/C#/Java, JavaScript/TypeScript, Python (incl. triple-quoted strings), PHP, Go, Rust, JSON, SQL, HTML/XML, CSS/SCSS, Shell/Bash, Ruby, YAML/TOML/INI, Markdown; comments render italic
- **Search & Replace** — floating panel with regex support (`.*`, `\d+`…), case-sensitivity toggle, wrap-around search, and "Replace All" across the document
- **Editor view options** — whitespace marker dots and indent guides (both on by default), word-wrap toggle, font zoom in/out/reset
- **Encoding & EOL handling** — auto-detects UTF-8/UTF-16 LE-BE with Latin-1 fallback; preserves CRLF/LF line endings on save
- **Line numbers** — logical line numbers stay aligned while scrolling, editing, and wrapping
- **Find All navigation** — click a result to select its match; double-click to select the whole line
- **Status bar** — live line/column, selection size, detected encoding and line-ending style per window
- **Save-safety prompts** — closing a dirty document asks Save / Don't Save / Cancel; "Save All" flushes every open window at once
- **File associations** — the release bundle registers as an editor for `public.plain-text` documents (Info.plist)

## Project structure

```
Notepad-Mac/
├── Package.swift              # SwiftPM manifest (executable target, macOS 13+)
├── build_app.sh               # Release bundler → build/NotepadMac.app (+ Info.plist, ad-hoc codesign)
├── .gitignore                 # Ignores .build/, DerivedData/, and the generated build/ bundle
└── Sources/NotepadMac/
    ├── main.swift             # Entry point; handles --selftest, boots NSApplication
    ├── AppDelegate.swift      # App lifecycle, menu bar (File/Edit/View/Window), file open/save orchestration
    ├── EditorDocument.swift   # Document model: path, dirty flag, encoding/EOL metadata
    ├── EditorWindow.swift     # Window controller per document; toolbar wiring; save/close prompts
    ├── NotepadTextView.swift  # NSTextView subclass: whitespace dots + indent guides rendering
    ├── ToolbarHeader.swift    # In-window toolbar (New/Open/Save All/Zoom/Wrap toggles)
    ├── StatusBar.swift        # Line/column, selection, encoding, EOL display
    ├── SearchEngine.swift     # Regex search & replace logic (pure functions → unit-testable)
    ├── SearchPanel.swift      # Find/Replace sheet UI with options checkboxes
    ├── Highlighter.swift      # Tiered regex highlight engine (keywords→numbers→strings→comments)
    ├── LanguagesCore.swift    # Language defs: plain, C-family, JS/TS, Python, PHP, Go, Rust
    ├── LanguagesWeb.swift     # Language defs: JSON, SQL, HTML/XML, CSS, Shell, Ruby, YAML/TOML, Markdown
    ├── EncodingUtils.swift    # BOM/byte-order detection + safe UTF-8 fallback decoding
    └── SelfTest.swift         # Offline assertions for search & encoding (run with --selftest)
```

## Development workflow

1. **Iterate** — edit Swift sources, then `swift run NotepadMac` to see changes in seconds.
2. **Verify logic offline** — `swift run NotepadMac --selftest` exercises the regex engine and encoders without launching a UI (good for CI).
3. **Ship it** — when satisfied, `./build_app.sh` regenerates `build/NotepadMac.app`; drag that folder anywhere on macOS to "install" or share it.

### Notes

- The app is ad-hoc signed (`codesign -s -`). To distribute outside your own machine long-term, use a real Developer ID certificate:
  ```bash
  codesign --force --sign "Developer ID Application: YOUR NAME (TEAMID)" build/NotepadMac.app
  ```
- Highlighting is skipped for files > ~3 MB to keep the UI responsive.
- Everything is programmatic AppKit — no nibs, no storyboards, no third-party packages — so builds stay hermetic and fast.

## License

Copyright (c) 2026 Kiran Ramesh Bharadwaj. Released under the [MIT License](LICENSE).

The application is implemented in Swift using Apple frameworks. No third-party packages are declared in `Package.swift`. Contributions must be original or include the notices required by their license.

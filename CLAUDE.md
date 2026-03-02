# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ztrans** is a Flutter + Rinf desktop translation application. Rinf bridges Flutter (Dart) and Rust, enabling a Rust backend with a Flutter UI frontend.

## Commands

### Setup
```bash
cargo install rinf_cli          # Install Rinf CLI tool
```

### Development
```bash
flutter run                     # Run app in debug mode (auto-selects connected device/desktop)
flutter run -d linux            # Run on Linux desktop specifically
rinf gen                        # Regenerate Dart bindings after changing Rust signal structs
```

### Build
```bash
flutter build linux             # Build Linux desktop release
flutter build windows           # Build Windows desktop release
flutter build macos             # Build macOS desktop release
```

### Test & Lint
```bash
flutter test                    # Run all Flutter tests
flutter test test/widget_test.dart  # Run a single test file
flutter analyze                 # Dart static analysis
cargo clippy                    # Rust linting (unwrap/expect/wildcard_imports are denied)
```

## Architecture

### Dart ↔ Rust Communication (Rinf Signals)

All Dart-Rust IPC uses **signal structs** defined in `native/hub/src/signals/mod.rs`. After editing signals, run `rinf gen` to regenerate the Dart bindings in `lib/src/bindings/`.

**Signal direction:**
- `#[derive(Deserialize, DartSignal)]` — Dart sends → Rust receives. Dart calls `.sendSignalToRust()`.
- `#[derive(Serialize, RustSignal)]` — Rust sends → Dart receives via `.rustSignalStream` broadcast stream.
- `#[derive(Serialize, SignalPiece)]` — Nested data inside a signal (not itself a signal).

Serialization uses **bincode** (binary, not JSON).

### Rust Backend (`native/hub/`)

The single Rust crate `hub` (name cannot be changed — Rinf requirement) uses:
- **`write_interface!()`** macro in `lib.rs` — establishes the Dart-Rust bridge
- **tokio** with `current_thread` flavor — single-threaded async runtime; no blocking calls on the async thread (use `spawn_blocking` for CPU-heavy work)
- **`messages` crate** — actor model for concurrency via message passing (not shared state)

Actors live in `native/hub/src/actors/`. Each actor:
- Implements the `Actor` trait
- Implements `Notifiable<SomeSignal>` to receive DartSignals
- Implements `Handler<SomeMessage>` for inter-actor request-response
- Owns `JoinHandle`s for spawned tasks (tasks cancel on actor drop)

### Flutter Frontend (`lib/`)

`lib/main.dart` initializes Rinf and starts the widget tree. Signal bindings are auto-generated — do not manually edit files under `lib/src/bindings/`.

## Key Constraints

- The Rust crate inside `native/` **must be named `hub`** (Rinf requirement).
- Never call blocking/synchronous code directly on the tokio async thread; use `tokio::task::spawn_blocking`.
- Clippy lints `unwrap_used`, `expect_used`, and `wildcard_imports` are set to `deny` in `native/hub/Cargo.toml`.
- Always run `rinf gen` after modifying any signal struct in Rust before building/running Flutter.

# The bundled 3du-converter

Fieldwork opens Pyware/UDB `.3du` drills by running
[3du-converter](https://github.com/a-riceeater/3du-converter), a separate Rust project with its
own repository, versions and releases. Fieldwork pins one converter commit as a Git submodule,
builds it from source and ships the executable inside the app. Users get a new converter only
in a new Fieldwork release.

```text
3du-converter repository ──(pinned commit)──▶ vendor/3du-converter
        scripts/build-converter.sh ──▶ build/converter/3du-converter (+ 3du-converter-build.json)
        Xcode Copy Files phase      ──▶ Fieldwork.app/Contents/MacOS/3du-converter
        Fieldwork release           ──▶ users (Sparkle on the website, the Mac App Store)
```

## First run on a Mac

The converter integration was written and tested on Windows. The converter, its build script
and `ThreeDUConverterService` passed there, but **the Mac side has never been built or run**:
the Xcode build phases, the embedded binary, signing, the sandbox and the Import Drill dialog.
Work through this list once, in order, on a Mac with Xcode 16 or newer, then record the results
in [PROGRESS.md](PROGRESS.md). Use only the synthetic drill below, never a real one.

### 1. Set up

```sh
git submodule update --init --recursive        # if Fieldwork was cloned without --recurse-submodules
rustup target add aarch64-apple-darwin x86_64-apple-darwin
./scripts/bootstrap-macos.sh
sh scripts/build-converter.sh --fixtures       # writes build/converter/fixtures/synthetic.3du
```

Install Rust from [rustup.rs](https://rustup.rs) first if `rustup` is missing. Bootstrap should
print `Staged …/build/converter/3du-converter (arm64, …)` before XcodeGen generates the project.

### 2. Run the tests

```sh
FIELDWORK_REQUIRE_CONVERTER=1 ./scripts/test-portable.sh
xcodebuild -project apps/macos/Fieldwork.xcodeproj -scheme Fieldwork -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

- [ ] The portable suites pass, including `DrillConvertTests` with nothing skipped.
- [ ] The app builds. `DrillImport.swift` and `DrillImportDialog.swift` have never been compiled,
      so expect small compile fixes there first.
- [ ] `DocumentTypeTests`, `DrillImportTests` and `BundledConverterTests` pass.

### 3. Check the bundle

```sh
xcodebuild -project apps/macos/Fieldwork.xcodeproj -scheme Fieldwork -configuration Release \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
app=build/DerivedData/Build/Products/Release/Fieldwork.app
lipo -archs "$app/Contents/MacOS/3du-converter"      # arm64 x86_64
vtool -show-build "$app/Contents/MacOS/3du-converter" | grep minos   # 14.0
"$app/Contents/MacOS/3du-converter" --version          # 3du-converter 0.1.0
cat "$app/Contents/Resources/3du-converter-build.json" # sourceCommit is the pinned commit
```

- [ ] The converter sits in `Contents/MacOS`, not `Contents/Resources`, and has both architectures.

### 4. Try the import dialog

Build Debug **without** `CODE_SIGNING_ALLOWED=NO`. Xcode then signs ad hoc, which is enough to
run the app sandboxed, as users get it:

```sh
xcodebuild -project apps/macos/Fieldwork.xcodeproj -scheme Fieldwork -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Fieldwork.app
say -o /tmp/count.wav --data-format=LEI16@44100 "one two three four five six seven eight"   # a throwaway recording
```

In another Terminal window, watch for sandbox denials while you test:

```sh
log stream --style compact --predicate 'sender == "Sandbox" AND eventMessage CONTAINS "3du-converter"'
```

Then, with File ▸ Open › `build/converter/fixtures/synthetic.3du`:

- [ ] The Import Drill dialog appears, and nothing is converted yet.
- [ ] Convert stays disabled with *Choose where to save the show.* until a show location is chosen.
- [ ] Convert with the defaults: the dialog closes, the saved show opens, and its banner starts
      with *Converted from “synthetic.3du”*.
- [ ] Mirror side to side and front to back: the performers come out mirrored and stay on the field.
- [ ] MusicXML without a recording: the `.musicxml` file is saved and opens in MuseScore or similar.
- [ ] MusicXML with `/tmp/count.wav`, *Follow the recording beat by beat* and a click check:
      all three files are saved, and the banner names the extra two (an alignment warning is
      fine for this recording).
- [ ] Save over an existing file: the save panel asks before replacing it.
- [ ] Choose a show that is open in Fieldwork as the destination: the dialog says to close it first.
- [ ] Rename any text file to `broken.3du` and open it: the dialog stays open and shows
      *This file is not a .3du drill that Fieldwork can import*, with the converter version.
- [ ] Open Recent lists `synthetic.3du` and opens the dialog again; so does dropping the file on
      the Dock icon.
- [ ] The log stream shows no denials, and `~/Library/Containers/<bundle id>/Data/tmp/Fieldwork-Conversions/`
      is empty afterwards.

### 5. Signing for distribution

With a team in `apps/macos/Config/Local.xcconfig` (see its template), archive in Xcode, export
for Developer ID, and run the commands in [Validating a build](#validating-a-build).

- [ ] The converter keeps exactly `app-sandbox` and `inherit`, the hardened runtime flag and the
      app's team.
- [ ] The exported app notarizes and passes `spctl`.

### 6. Afterwards

- [ ] Add a dated entry to [PROGRESS.md](PROGRESS.md) with the commands run and their results,
      like the existing ones.
- [ ] Check that the macOS job in `.github/workflows/ci.yml` passes on GitHub. It has never run.

## The submodule

`vendor/3du-converter` is a submodule with the SSH remote
`git@github.com:a-riceeater/3du-converter.git`. Fieldwork records one exact commit (the
gitlink), not a branch. A build never fetches or moves it.

After cloning Fieldwork:

```sh
git submodule update --init --recursive
# or clone with: git clone --recurse-submodules <fieldwork-url>
```

`scripts/bootstrap-macos.sh` runs that command if the submodule is missing.

The two histories stay independent. Change the converter in its own repository: commit, push
and (optionally) tag it there, then move Fieldwork's pin (see [Updating](#updating-the-pinned-version)).
`build-converter.sh` warns when the checkout is not at the pinned commit or has local changes,
and refuses both for an archive. To work on a converter checkout elsewhere, set
`FW_CONVERTER_SOURCE=/path/to/3du-converter` (development only).

## Building

```sh
sh scripts/build-converter.sh               # this Mac's architecture (or the host on Windows/Linux)
sh scripts/build-converter.sh --universal   # arm64 + x86_64, merged with lipo
sh scripts/build-converter.sh --fixtures    # also write build/converter/fixtures/synthetic.3du
```

Requirements: Rust 1.75 or newer from [rustup](https://rustup.rs). Universal builds also need
`rustup target add aarch64-apple-darwin x86_64-apple-darwin`; the script checks for the targets
and prints this command when one is missing.

The script:

1. Checks the source and the pin, and that the workspace still has the `3du-converter` binary
   (package `three-du-cli`).
2. Runs `cargo build --release --locked -p three-du-cli --bin 3du-converter` for each target,
   with `MACOSX_DEPLOYMENT_TARGET` set to the app's (14.0, from `Base.xcconfig`). `--locked`
   uses exactly the crates in the converter's `Cargo.lock`. Local paths are remapped out of the
   binary.
3. Merges the slices with `lipo` and checks that a universal build has both.
4. On macOS, pre-signs the staged copy (see [Signing](#signing-and-the-sandbox)).
5. Writes `build/converter/3du-converter-build.json`: version, interface number, source commit,
   whether the source was modified, architectures, deployment target and `rustc` version.

Cargo builds incrementally into `build/converter/target`, and the staged files are rewritten
only when they change, so a build with nothing to do takes about a second and does not make
Xcode re-sign the app. `build/` is ignored by git. Any failure prints `error: build-converter: …`
(Xcode shows it in the build log) and exits nonzero.

## Embedding in the app

`apps/macos/project.yml` (XcodeGen) does three things for the `Fieldwork` target:

- A **pre-build script phase** runs `build-converter.sh --xcode` before compiling. Debug builds
  use the architectures Xcode builds (`$ARCHS`); Release and archive builds are always
  universal. The phase declares its two outputs, so Xcode orders the copy after it.
- A **Copy Files phase** (destination *Executables*, **Code Sign On Copy**) puts
  `build/converter/3du-converter` in `Fieldwork.app/Contents/MacOS/`.
- The build info JSON goes to `Contents/Resources/` through the normal resources phase.

```text
Fieldwork.app/Contents/
├── MacOS/
│   ├── Fieldwork
│   └── 3du-converter
├── Resources/3du-converter-build.json
└── Info.plist
```

The project embeds a file that must exist when XcodeGen runs, which is why
`bootstrap-macos.sh` builds the converter before generating. After that, Xcode rebuilds it on
every build, so `rm -rf build` and clean builds work. Nothing is added to the project by hand,
and the generated `.xcodeproj` stays disposable. The phase sets
`ENABLE_USER_SCRIPT_SANDBOXING = NO` because Cargo reads `~/.cargo`, `~/.rustup` and the whole
source tree. If Rust is installed somewhere other than `~/.cargo/bin`, put `cargo` on the PATH
that Xcode sees.

## Importing a `.3du` drill

`Info.plist` declares the `.3du` type (`$(FW_BUNDLE_NAMESPACE).drill-3du`) with the **Viewer**
role, so File ▸ Open, the Welcome window, Open Recent, the Dock and Finder's Open With all
offer drills. `.fieldwork` stays the only type Fieldwork writes, and a drill is never opened
or changed in place.

`FieldworkDocumentController` (`Document/DrillImport.swift`) is the app's shared
`NSDocumentController`, created first in `AppDelegate.main`. Every route that opens a file
passes through its `openDocument(withContentsOf:display:completionHandler:)`. For a `.3du`, it
shows the **Import Drill** dialog (`Document/DrillImportDialog.swift`) instead of opening a
document:

| Dialog | Converter flag | Notes |
|---|---|---|
| Fieldwork show ▸ Save as | `--output` | Required. Chosen with a save panel, which also asks before replacing a file. |
| Accept approximations | `--allow-lossy` | Off by default, so the converter stops and lists anything it could not convert exactly. |
| Page map | `--page-map FILE` | Optional JSON list of `{"name", "start_count", "is_subset"}`. |
| Mirror side to side / front to back | `--flip-x` / `--flip-y` | Mirrors about the middle of the field (needs converter `4288310` or later). |
| Steps per unit | `--steps-per-unit N` | Blank reads it from the drill (1.6 for yards at 8 to 5). |
| Also export a MusicXML count track ▸ Save as | `--format musicxml --output` | A second conversion of the same drill. |
| Recording | `--audio FILE` | Optional `.wav`. Aligns count 0 with the recording. |
| Audio offset (seconds) | `--audio-offset S` | Blank aligns automatically (with a recording) or puts count 0 at 0 s. |
| Follow the recording beat by beat | `--follow-audio` | Needs a recording. For live performances that drift. |
| Save a click check ▸ Click check | `--click-check FILE` | Needs a recording. The recording with a click on every aligned beat. |

The dialog sets `--json` itself and never uses `--overwrite`, `--strict`, `--preserve-curves`
(it has no effect on Fieldwork output), `--verbose` or `--quiet`. Convert stays disabled, with
the reason shown, until every required file is chosen and the numbers parse.

On **Convert**:

1. `ThreeDUConverterService` copies the drill, page map and recording into a new folder under
   the app's temporary directory (`Fieldwork-Conversions/<uuid>/`) and runs
   `3du-converter convert … --json` there with `Process`, with an argument list and no shell.
   The converter only touches those copies and writes its outputs to the same folder, which is
   deleted when the call returns. Folders a crash left behind are removed after a day.
2. With MusicXML on, a second conversion writes the count track (and the click check).
3. Only after every conversion succeeded does Fieldwork save the files to the places chosen in
   the dialog, so a failure never leaves some files written and others not.
4. The dialog closes, and the new `.fieldwork` opens like any saved show. Its banner names the
   drill, the other files saved, and the converter's warnings for both conversions, such as
   `alignment_not_confident`.
5. A failure keeps the dialog open with the converter's reason and build, for example *This file
   is not a .3du drill that Fieldwork can import. … Converter: 3du-converter 0.1.0
   (428831051218)*. When the converter refused an approximation, the message lists what it
   would approximate and suggests turning on *Accept approximations*. Cancel stops a running
   conversion; closing the window does the same.

`ThreeDUConverterService.convert(_:to:options:)` lives in the portable `DrillConvert` library
(`packages/DrillDocument`), with `ConverterOptions` mirroring the table above. It is `async`, and
cancelling the task terminates the converter. It checks option combinations the converter would
reject with a usage error (no JSON), such as following a recording without one. It also writes
OpenMarch `.dots`, although Fieldwork has no `.dots` UI yet. `ConverterLocator` is the only
platform-specific part: `Contents/MacOS/3du-converter` through
`Bundle.url(forAuxiliaryExecutable:)` on macOS, `3du-converter.exe` beside the app's `.exe` on
Windows.

## Version contract

The converter's CLI is the interface. Fieldwork relies on:

- `convert <input> --format fieldwork|dots|musicxml --output <path> --json`, with the options in
  the dialog table above
- on stdout, `{"ok": true, "result": {"output", "diagnostics"}}` or
  `{"ok": false, "error": {"code", "message", "diagnostics"}}`, where each diagnostic is
  `{"severity": "info"|"warning"|"lossy", "code", "message"}` and messages never contain drill
  names
- exit codes 0 OK, 1 failure, 2 usage, 3 invalid input, 4 refused by the loss policy, 5 output
  exists, 6 validation failed, 7 I/O
- `--version` printing `3du-converter <semver>`

This is **interface 1**: `ThreeDUConverterService.interface` and `interface=` in
`build-converter.sh`, recorded in the build info. A test checks that they agree. If the
converter ever breaks this contract, bump both and update the service in the same Fieldwork
change. Additive changes (new diagnostics, formats or flags) need no bump. The converter needs
no Fieldwork-specific changes.

To see what a build contains:

```sh
cat Fieldwork.app/Contents/Resources/3du-converter-build.json   # version, source commit, architectures
git -C vendor/3du-converter log -1 --oneline                    # the pinned commit in a checkout
build/converter/3du-converter --version
```

In code, use `ConverterLocator.buildInfo()?.summary` or `ThreeDUConverterService().version()`.

## Updating the pinned version

```sh
sh scripts/update-converter.sh            # fetch; list upstream commits and tags not pinned yet
sh scripts/update-converter.sh v0.2.0     # or a commit; checks it out, runs the converter tests,
                                          # builds (universal on macOS) and runs the integration tests
```

The script never commits. Then, on macOS, run the app tests and try a real drill locally (see
[Debugging](#debugging-a-failed-conversion)). Commit the new pin:

```sh
git add vendor/3du-converter
git commit -m "build(converter): pin 3du-converter 0.2.0"
```

To back out instead, run `git submodule update --init --recursive`.

## How updates reach users

The converter has no updater of its own and never downloads anything. It is part of the signed
app bundle, so it changes only when Fieldwork does:

- **Website builds** update with Sparkle. Sparkle replaces the whole `Fieldwork.app`, including
  `Contents/MacOS/3du-converter`, after checking the update's EdDSA signature and its Apple code
  signature, which seals the helper. The converter needs no Sparkle configuration. (Sparkle is
  not in this repository yet. When it is added, its sandboxed-app XPC setup is unrelated to the
  converter.)
- **Mac App Store builds** update through the App Store with the rest of the bundle.

## Signing and the sandbox

Fieldwork is sandboxed (`Fieldwork.entitlements`) and uses the hardened runtime. The converter
is a plain command-line tool that inherits the app's sandbox. Its entitlements
(`apps/macos/Converter/3du-converter.entitlements`) are exactly:

```text
com.apple.security.app-sandbox = true
com.apple.security.inherit     = true
```

It needs no other entitlement, privilege, installer, launch daemon or login item.

Order of signing in an Xcode build:

1. `build-converter.sh --xcode` ad-hoc signs the staged binary with identifier
   `$(FW_BUNDLE_NAMESPACE).3du-converter`, the hardened runtime and those entitlements. When
   `CODE_SIGNING_ALLOWED=NO` the app is not sandboxed, and a tool with
   `com.apple.security.inherit` would trap at launch, so it gets a plain ad-hoc signature
   instead.
2. **Code Sign On Copy** re-signs the embedded copy with the app's identity (`-` for local
   builds, *Apple Development* from `Local.xcconfig`) and keeps the identifier, entitlements and
   runtime flag.
3. Xcode signs `Fieldwork.app` last, after every build phase, so the app's seal covers the
   final helper.

Archives use the same steps. Exporting from the Organizer re-signs nested code with the
distribution identity (Developer ID Application or Apple Distribution) and keeps each
executable's entitlements. Development builds need no distribution certificate.

### Validating a build

Signing could not be checked on the machine that set this up (no Mac). Run these on a signed
build or an exported archive:

```sh
app="path/to/Fieldwork.app"
tool="$app/Contents/MacOS/3du-converter"

lipo -archs "$tool"                                  # arm64 x86_64 (Release/archive)
vtool -show-build "$tool" | grep minos               # 14.0
codesign --verify --strict --deep --verbose=2 "$app" # valid on disk, satisfies its requirement
codesign -dvvv "$tool"                               # Identifier=org.fieldwork.3du-converter, flags=0x10000(runtime), same TeamIdentifier as the app
codesign -d --entitlements - --xml "$tool"           # only app-sandbox and inherit
codesign -d --entitlements - --xml "$app"            # app-sandbox, files.user-selected.read-write (unchanged)

# Developer ID, after notarizing the exported app:
xcrun notarytool submit Fieldwork.zip --keychain-profile <profile> --wait
xcrun stapler validate "$app"
spctl --assess --type execute -vv "$app"             # accepted, source=Notarized Developer ID

# Mac App Store: validate the exported package in Xcode's Organizer or with Transporter.
```

To check the sandbox at runtime, open the synthetic drill
(`sh scripts/build-converter.sh --fixtures` writes `build/converter/fixtures/synthetic.3du`) in a
signed build while watching for denials:

```sh
log stream --style compact --predicate 'sender == "Sandbox" AND eventMessage CONTAINS "3du-converter"'
```

The import should succeed with no denials. Conversions use
`~/Library/Containers/<bundle id>/Data/tmp/Fieldwork-Conversions/`, which is empty again
afterwards.

## Tests

| Where | What | Runs on |
|---|---|---|
| `vendor/3du-converter` | `cargo test --workspace --locked`: the converter's own suite, synthetic data only | any |
| `packages/DrillDocument/Tests/DrillConvertTests` | the service against the real built converter and its synthetic show: conversion to `.fieldwork` (decoded by `DocumentCodec`), `.dots` and MusicXML with a generated `.wav` and click check, mirroring, invalid option combinations, a non-drill input, a missing executable or input, a non-JSON result, cancellation, temp cleanup, build info | macOS, Windows, Linux |
| `apps/macos/FieldworkTests` | the `.3du` document type and import controller; the dialog's required files and option mapping; the converter is embedded in `Contents/MacOS`, runs and matches its build info; error text | macOS |

The integration tests skip when `build/converter` has no converter or fixture. CI sets
`FIELDWORK_REQUIRE_CONVERTER=1`, which turns a skip into a failure. Run them locally with:

```sh
sh scripts/build-converter.sh --fixtures
FIELDWORK_REQUIRE_CONVERTER=1 swift test --package-path packages/DrillDocument --filter DrillConvertTests
```

## Debugging a failed conversion

1. Read the message in the import dialog. It contains the converter's error code and message (for example `not_3du`,
   or the loss-policy diagnostics) and the converter version and commit.
2. Reproduce it outside the app with the unsandboxed build, on a copy of the drill:

   ```sh
   sh scripts/build-converter.sh
   build/converter/3du-converter inspect copy.3du          # counts, versions, warnings; no names
   build/converter/3du-converter convert copy.3du --format fieldwork --output /tmp/out.fieldwork --json
   ```

   Do not run `Fieldwork.app/Contents/MacOS/3du-converter` from Terminal in a signed build. It
   carries `com.apple.security.inherit` and traps when its parent is not sandboxed.
3. Exit status 4 means the converter refused an approximation. The alert lists what it would
   approximate. Status 6 (validation failed) or a crash is a converter bug. Report it in the
   converter repository with the `inspect` output and the converter commit, never the drill.
4. "Returned an unexpected result" means no valid JSON came back. Check that the app was built
   from a clean, pinned submodule (`3du-converter-build.json`).

## Private drill data

Real drills belong to real ensembles. `.gitignore` ignores `.3du`, `.3dudb`, `.dots`, `.om`,
`.omz`, `.fieldworks` and `.fieldwork` files everywhere except the public fixtures in
`examples/` and `spec/fixtures/`. Tests use only the converter's generated synthetic show.
The converter's messages never contain drill names, and Fieldwork logs nothing about drill
content.

## Windows (later)

The CLI already builds and passes its tests on Windows (`build-converter.sh` stages
`3du-converter.exe`), and `DrillConvert` and its tests run there unchanged. A Windows app will
ship the `.exe` beside its own executable, where `ConverterLocator` looks for it.

# ios-sim-metal-for-godot

Run a Godot 4.7.2 game in Apple's iOS Simulator on the **Mobile renderer over Metal**, including
the iPhone Duo foldable simulator in Xcode 27.1.

> **Unofficial.** This project is not affiliated with, or endorsed by, the Godot Foundation or the
> Godot Engine project. "Godot" is used here only to describe what the patches apply to.

Since Godot 4.4, the iOS build turns Metal off for simulator builds and simulator export is not
supported. The simulator's OpenGL ES is a CPU software renderer, too slow to use for any real game.
This repository holds five small engine patches that make a simulator build run on Metal, and a
script that builds a debug export template from them.

Every change is behind `IOS_SIMULATOR`, so device builds compiled from the same source are
unchanged. Use the template only for simulator testing. Device and store builds should keep using
the official templates.

Tested with a 2D game on the iPhone Duo simulator (iOS 27.1).

## Requirements

- An Apple Silicon Mac. The iOS 27 simulator runs arm64 apps only.
- Xcode 27.1 or later, with the iOS 27.1 simulator runtime installed. You don't need to switch
  `xcode-select`: `build.sh` reads `DEVELOPER_DIR`, which defaults to
  `/Applications/Xcode-27.1-RC.app/Contents/Developer`.
- `git`, `scons`, `python3`, `curl`.
- About 4 GB of free disk space: about 2.3 GB for the source, build and output, plus 1.3 GB if
  `build.sh` downloads the export templates.
- The Godot 4.7.2 editor, to export your project.

## Build the template

```sh
./build.sh                                  # downloads the official 4.7.2 export templates (1.3 GB)
./build.sh path/to/Godot_v4.7.2-stable_export_templates.tpz
./build.sh path/to/ios.zip                  # e.g. from your installed export templates
```

`build.sh` does the following:

1. Clones `4.7.2-stable` into `src/godot` and applies `patches/all.patch`.
2. Builds the arm64 simulator library:
   `scons platform=ios target=template_debug arch=arm64 ios_simulator=yes`. A clean build takes
   about 4 minutes on an 18-core machine.
3. Takes the official iOS template, checking its SHA-512 against the release's
   `SHA512-SUMS.txt` when it downloads it.
4. Combines the new arm64 library with the official x86_64 simulator slice.
5. Writes `dist/godot-4.7.2-ios-sim-metal-debug.zip`, Godot's `LICENSE.txt` and `COPYRIGHT.txt`
   (which apply to the template), and `dist/SHA256SUMS` for all three.

Override the Xcode with `DEVELOPER_DIR=…` and the job count with `JOBS=…`.

## Use it

1. Add an iOS export preset for the simulator. Set **Custom Template → Debug** to
   `dist/godot-4.7.2-ios-sim-metal-debug.zip`, then export the Xcode project. Leave the
   rendering method on `mobile`.
2. Exclude any plugin or GDExtension that ships a device-only (arm64 iOS) framework. Those block
   the simulator link.
3. Build and install with the same Xcode:
   ```sh
   export DEVELOPER_DIR=/Applications/Xcode-27.1-RC.app/Contents/Developer
   xcodebuild -project <name>.xcodeproj -scheme <name> -configuration Debug \
     -destination id=<SIM_UDID> CODE_SIGNING_ALLOWED=NO build
   xcrun simctl install <SIM_UDID> <path/to/name.app>
   xcrun simctl launch <SIM_UDID> <bundle.id>
   ```

### iPhone Duo

- In Xcode 27.1 the simulator UI is **DeviceHub** (`Xcode.app/Contents/Applications/DeviceHub.app`).
  `simctl boot` alone runs the device headless.
- Fold poses are changed in DeviceHub. `simctl` has no fold or posture control.
- The device boots **closed**, so the game shows on the outer display. Use
  `xcrun simctl io <SIM_UDID> screenshot --display=1 out.png` to capture it. A plain
  `simctl io screenshot` captures the inner display, which is black while the device is closed.
- **Tabletop:** unfold, rotate to landscape, then half-fold. Check which way up the device is. If
  it is upside down, the system does not report tabletop.

## The patches

| Patch | What fails without it | Change |
|---|---|---|
| `0001-sim-enable-metal` | The simulator build has no Metal and falls back to OpenGL. | `platform/ios/detect.py` no longer forces `metal=False` for simulator builds. |
| `0002-sim-metal-error-domains` | The Xcode link fails on `_MTLIOErrorDomain` and `_MTLTensorDomain`, which the simulator SDK's `Metal.tbd` does not export. | Defines both constants for the simulator. |
| `0003-sim-skip-apple4-check` | Launch shows "Your Apple GPU does not support … image cube arrays", because the simulator reports a GPU family below Apple4. | Skips that family check in the simulator. |
| `0004-sim-cube-array-as-2d-array` | Metal validation aborts creating Godot's default cube-array textures. | Stores cube-array textures as 2D arrays in the simulator, keeping every layer. |
| `0005-sim-present-without-minimum-duration` | Abort at the first present: the simulator's command buffer does not implement `presentDrawable:afterMinimumDuration:`. | Falls back to `presentDrawable:` when that selector is missing. |

`patches/all.patch` is the five patches combined, and it is what `build.sh` applies.

## Limits

- **Cube arrays are emulated as 2D arrays.** A 3D scene that samples reflection probes or a sky
  cube array may render wrongly or fail validation. 2D games don't sample them.
- **Debug template only.** It is for layout and flow testing. The simulator GPU is not a device
  GPU, so its frame times say nothing about device performance.
- **Godot 4.7.2 only.** The patches target `4.7.2-stable` and may not apply to other versions.

## License

The patches and scripts in this repository are MIT-licensed; see [LICENSE](LICENSE). They modify
Godot Engine, which is MIT-licensed. Godot's copyright notice is kept in `LICENSE` and applies to
the Godot code the patches touch. The template that `build.sh` produces is Godot Engine, built
with these patches, and carries Godot's license and its third-party notices.

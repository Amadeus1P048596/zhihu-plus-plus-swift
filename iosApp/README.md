# iOS App

This directory contains the native SwiftUI iOS app. Its Xcode target no longer builds or links the Kotlin Multiplatform `Shared.framework`.

## Requirements

- iOS 16.0 or later at runtime. iOS 26 or later is recommended for the full system Liquid Glass appearance.
- macOS with Xcode 26 or later and the iOS 26 SDK installed. The project uses Swift 5 language mode.
- Full Xcode installation, not only Command Line Tools.
- A selected developer directory:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

- Xcode first launch completed, including license and required components.
- An Apple account signed in to Xcode.
- An Apple development team configured in Xcode, or passed to CLI scripts as `TEAM_ID=<YOUR_TEAM_ID>`.
- A unique bundle identifier. The repository default is `com.github.kangyun1994.zhplus.swift`; use `BUNDLE_ID=<YOUR_BUNDLE_ID>` for CLI overrides if that identifier is unavailable for your team.
- Automatic signing enabled, or a matching development or Ad Hoc provisioning profile.
- A registered and trusted iPhone or iPad for physical device installation.

## Preflight

Run this from the repository root after installing full Xcode:

```bash
./iosApp/scripts/preflight.sh
```

For CLI signing checks:

```bash
TEAM_ID=ABCDE12345 ./iosApp/scripts/preflight.sh
```

The preflight checks selected Xcode, `iphoneos` SDK availability, iOS destination eligibility for the Xcode project and scheme, and the Xcode project metadata. It does not build the app.

If the selected Xcode installation is missing the iOS platform/runtime required by the project destination, such as iOS 26.5, preflight fails before `build-device.sh` or `export-ipa.sh`. Manually run `xcodebuild -downloadPlatform iOS`, wait for the download to complete, then rerun preflight.

## SideStore IPA

SideStore is the preferred path for the current personal install target. This route creates an unsigned IPA on the Mac and lets SideStore re-sign it on the iPhone with your Apple Account. Do not provide Apple ID, password, or `TEAM_ID` to Codex or to this script.

Start from the repository root. If `./iosApp/scripts/preflight.sh` says `no such file or directory`, you are in the wrong directory:

```bash
cd /path/to/zhihu-plus-plus-swift
```

Before building the IPA, install and set up SideStore on the device:

1. Install SideStore with the official iLoader flow.
2. Place or refresh the pairing file as described by SideStore. A pairing file can become invalid after device updates, resets, or similar changes; recreate it with iLoader when needed.
3. Trust the Developer App profile on iOS.
4. Enable iOS Developer Mode.
5. Enable SideStore's LocalDevVPN.
6. Sign in to SideStore with your Apple Account.

References used for this route:

- [SideStore](https://sidestore.io/) says SideStore can install any `.ipa`.
- [SideStore installation docs](https://docs.sidestore.io/docs/installation/install) cover Developer App trust, Developer Mode, LocalDevVPN, Apple Account login, and refreshing the 7-day counter.
- [SideStore pairing file docs](https://docs.sidestore.io/docs/advanced/pairing-file) cover pairing file refresh/replacement.
- [SideStore GitHub](https://github.com/SideStore/SideStore) documents the SideStore resigning and refresh model for the standard Apple development signing window.

Build the SideStore-importable IPA:

```bash
BUNDLE_ID=com.example.zhihuplusplus.swift ./iosApp/scripts/build-sidestore-ipa.sh
```

The script defaults to `com.github.kangyun1994.zhplus.swift`. Override it with a unique identifier that belongs to your signing account. The output is:

```text
build/iosApp/sidestore/ZhihuPlusPlus-SideStore.ipa
```

Transfer that IPA to the iPhone and open it with SideStore to install. After installation, SideStore manages the normal 7-day refresh cycle on the device.

If preflight still reports that the iOS 26.5 platform is not installed, install the missing Xcode platform first:

```bash
xcodebuild -downloadPlatform iOS
```

You can also install it from Xcode > Settings > Components. Rerun the SideStore build script only after the platform download is complete.

`Only IPA` means you only need the final `.ipa` file for SideStore import after all build prerequisites are already ready. The one-command script exists to produce that IPA repeatably from the current source tree, with the correct bundle identifier, unsigned build settings, clean `Payload/` packaging, and a stable output path.

## Open In Xcode

```bash
open iosApp/iosApp.xcodeproj
```

In Xcode:

1. Select the `iosApp` target.
2. Open `Signing & Capabilities`.
3. Choose your development team.
4. Change the bundle identifier if your team cannot use `com.github.kangyun1994.zhplus.swift`.
5. Connect a device, select it as the run destination, and press Run.

The Xcode target builds only the native Swift sources registered under `iosApp/iosApp` and has no Gradle build phase.

The image viewer leaves native pinch handling to `UIScrollView`. Custom Objective-C gesture targets must use viewer-specific selectors such as `handleGalleryPinch:`: naming a subclass target `handlePinch:` shadows UIKit's native handler and disables gesture-driven zoom even though double-tap zoom and panning still work.

Image-load waiters check cancellation before decoding a shared result, without cancelling another live waiter's request. If the viewport changes during zoom, deferred layout preserves the focal point using the current visible bounds rather than the old viewport size.

## CLI Device Build

For CLI self-signing, pass `TEAM_ID=<YOUR_TEAM_ID>` explicitly. Leave `BUNDLE_ID` unset unless the default bundle identifier is unavailable for your team or you intentionally want to override it.

Generic device build:

```bash
TEAM_ID=ABCDE12345 ./iosApp/scripts/build-device.sh
```

Build for a connected device UDID:

```bash
TEAM_ID=ABCDE12345 DEVICE_ID=00008110-001234567890801E ./iosApp/scripts/build-device.sh
```

Override the bundle identifier without editing the project:

```bash
TEAM_ID=ABCDE12345 BUNDLE_ID=com.example.zhplus.dev ./iosApp/scripts/build-device.sh
```

The script passes `-allowProvisioningUpdates` to let Xcode create or update managed development provisioning profiles for accounts that support it.

## Export IPA

Use the same signing guidance for export: pass `TEAM_ID`, and only add `BUNDLE_ID` when the default identifier is unavailable or you want a specific override.

Create an archive and export an IPA:

```bash
TEAM_ID=ABCDE12345 ./iosApp/scripts/export-ipa.sh
```

By default the export method is `debugging`, suitable for local development devices. For Ad Hoc-style release testing with a matching paid developer account and registered devices:

```bash
TEAM_ID=ABCDE12345 EXPORT_METHOD=release-testing ./iosApp/scripts/export-ipa.sh
```

Outputs are written under:

```text
build/iosApp/
```

You can also provide your own export options:

```bash
EXPORT_OPTIONS_PLIST=/path/to/ExportOptions.plist ./iosApp/scripts/export-ipa.sh
```

## Install Notes

- Xcode Run is the simplest install path for a directly connected development device.
- On the device, trust the developer certificate if iOS asks for it.
- If a CLI build succeeds but the device does not receive the app, install the generated `.app` from Xcode's Devices and Simulators window or use Xcode's device tooling for your installed Xcode version.
- A free Apple account usually supports development signing for directly connected personal devices, but Ad Hoc IPA distribution requires a paid Apple Developer Program team.

## Troubleshooting

- `xcodebuild requires Xcode`: run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- `Xcode license is not accepted`: run `sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`.
- `iphoneos SDK is not available`: open Xcode once and complete first launch/component installation.
- Missing iOS platform/runtime, such as iOS 26.5: run `xcodebuild -downloadPlatform iOS`, wait for the platform download to finish, then rerun preflight before `build-device.sh` or exporting an IPA.
- `requires a development team`: set the team in Xcode or pass `TEAM_ID=<YOUR_TEAM_ID>`.
- Bundle identifier unavailable: change it in Xcode or pass `BUNDLE_ID=<YOUR_BUNDLE_ID>`.
- Device cannot install: confirm the device is registered for the provisioning profile, unlocked, trusted by the Mac, and trusts the developer certificate.
- Stale Xcode or signing output: remove this project's DerivedData from Xcode's Settings or Organizer, then rebuild.

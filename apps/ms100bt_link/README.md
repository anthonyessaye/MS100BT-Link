# MS-100BT Link (Flutter)

The multiplatform MS-100BT Link app: macOS, Android and iOS (iOS is diagnostics only for now), on the
shared Dart protocol core in `packages/zoom_core`.

## Flutter version

The app builds with Flutter's **main** channel and the experimental **windowing** feature, so the Mac
build has real windows (main window, Effects, Diagnostics) like the native app. Install it next to any
other Flutter you use:

```bash
git clone --filter=blob:none -b main https://github.com/flutter/flutter.git ~/development/flutter-main
~/development/flutter-main/bin/flutter config --enable-windowing
```

## Build

```bash
~/development/flutter-main/bin/flutter build macos
~/development/flutter-main/bin/flutter build apk --release
~/development/flutter-main/bin/flutter build ios --no-codesign
```

After switching Flutter versions, run `flutter clean` (and delete the app's Xcode DerivedData folder)
if Xcode reports that a framework header "has been modified since the precompiled header was built".

## Tests

```bash
~/development/flutter-main/bin/flutter test                # unit and widget tests
~/development/flutter-main/bin/flutter test test_screens --update-goldens   # renders screens to test_screens/out
```

`test_screens` renders the screens with real fonts (it reads them from this machine's Flutter install)
and fails on any layout overflow, including a pass over every MS-100BT effect.

## Icons

Drawn by `tool/make-icon.swift` (`swift tool/make-icon.swift out.png mac|square|foreground`)
(`mac` for macOS, `square` for iOS and Android legacy icons, `foreground` for Android adaptive icons).

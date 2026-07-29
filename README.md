# Miso Roller

A simulated physics dice-rolling app for iOS, built with SwiftUI, SceneKit, and Metal.

Roll up to 16 d4–d20 on a tactile, top-down table with real physics-driven bouncing and settling, hand-recorded impact sounds, and a custom Metal post-processing pipeline (chromatic grading, bloom, screen-space grain/dither).

## Requirements

- Xcode 26+
- iOS 26.0+ (uses Liquid Glass APIs)

## Building

Open `MisoRoller.xcodeproj` in Xcode and run the `MisoRoller` target, or build from the command line:

```
xcodebuild -project MisoRoller.xcodeproj -target MisoRoller -configuration Debug -sdk iphonesimulator build
```

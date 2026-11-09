# AERION

AERION is a native macOS system monitor inspired by the Airbus A320's ECAM. Its Engine/Warning Display (E/WD) shows core metrics and alerts. The System Display (SD) presents detailed readings as system diagrams. Both displays share a single sampler.

## Build and run

Requires macOS 15 or later and Xcode 26.6 (the tested toolchain). The project uses SwiftUI and AppKit with no third-party packages.

1. Clone or download this repository.
2. Open `AERION.xcodeproj` in Xcode.
3. Select the **AERION** scheme and **My Mac**, then press **⌘R**. Press **⌘U** to run the tests.

On Apple silicon, you can also build and launch a local release from Terminal:

```sh
BUILD_DIR=$(mktemp -d "${TMPDIR%/}/aerion-build.XXXXXX")
xcodebuild -project AERION.xcodeproj -scheme AERION \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" build
open "$BUILD_DIR/Build/Products/Release/AERION.app"
```

To keep the locally built app, move it to **Applications**. The project is configured for local signing.

## Use the displays

| Shortcut | Action |
| --- | --- |
| **⌘1** | Open the E/WD dashboard |
| **⌘2** | Open the floating monitor |
| **⌘3** | Open the System Display in its own window |
| **⌘4** | Stack the E/WD above the SD and fit both to the current screen |
| **⌘5** | Switch the main window between E/WD and SD |
| **⌘,** | Open Settings |

The menu bar icon opens a compact monitor and provides shortcuts to both displays. Resize either ECAM window from its edge to scale the diagrams proportionally. Use the six buttons at the bottom of the SD to select a page. AERION remembers the last page.

| SD page | Readings |
| --- | --- |
| **ELEC** | Power source, battery level, and charging state |
| **THERM** | macOS thermal pressure level |
| **NET** | Network path, measured interface, receive rate, and transmit rate |
| **STOR** | Home volume capacity, used and available space, and visible local volumes |
| **MEM** | Memory pressure, estimated RAM usage, compressed memory, and swap |
| **STATUS** | System state, CPU load, uptime, and active alerts |

## Configure AERION

Open **AERION → Settings** with **⌘,**.

- **Update interval** sets foreground sampling to **0.5**, **2**, or **5 seconds**. AERION falls back to a 30-second sampling interval when all monitor surfaces are hidden and pauses sampling during sleep.
- **Display scale** offers **85%**, **100%**, and **115%** presets.
- **Show auxiliary readings** toggles extra details on the dashboard and compact displays.
- **Keep floating monitor above windows** controls the floating window level.
- **Launch at login** registers AERION with macOS. If approval is required, use **Approve in System Settings** from the app.

## Reading the data

AERION reads system metrics locally. Battery power source and charging state are separate, so the app may show **AC CONNECTED** and **NOT CHARGING** at the same time. Memory pressure shows **N/A** until macOS delivers a pressure event. RAM usage is an estimate based on Mach VM statistics. On VPNs, the network path type and measured interface can differ. APFS volumes can share available space. Thermal readings are operating-system pressure levels.

## License

[MIT](LICENSE). AERION is an independent project inspired by aircraft instrumentation and is intended for desktop system monitoring.

# EveryMacTool

A native macOS menu bar dashboard for battery and charging telemetry, USB devices, display modes, and network traffic. Developed by **Ahas Nimsandu**.

## Features

- Live battery level, charge/discharge watts, adapter input, system load, and USB Power Delivery profiles.
- Adaptive local charge/discharge time forecast with recent trend smoothing and macOS estimate comparison.
- Battery health and cycles, session energy totals, charging headroom, and optimization hints.
- USB device discovery, display resolution and refresh, per-interface network throughput, and history charts.
- Simple and Pro interface modes, expandable See more analysis, adjustable liquid-glass intensity, and a performance mode.
- Refresh intervals from 0.25 to 10 seconds for power/network data, plus a recent power-event log. USB/display inventory is scanned less often to keep fast updates light.
- A shortcut to Apple Battery settings for the system charge limit and a customizable in-app MagSafe status glow.
- A one-tap quick Mac read using Apple's on-device Foundation Models (Apple Intelligence), with a local telemetry-only fallback. The build probes the selected SDK and includes Apple's Private Cloud Compute fallback only when that API is present and Apple reports the model available on macOS 27+.
- Menu bar popover with native macOS transitions and liquid glass on macOS 26+.

All analysis runs locally. Forecasts use the recent battery power trend and pack capacity; they are estimates, not guarantees. Per-device USB power, cable e-marker identity, physical empty-port count, and some display-link details are not exposed through ordinary public macOS APIs and are reported as unavailable rather than fabricated.

## Build and package

Requirements: macOS 26 or later, Swift compiler, and `hdiutil` (included with macOS).

```sh
./tools/Build.command
```

This creates `build/EveryMacTool.app` and a drag-to-Applications disk image in `dist/`. The app is built for the current Mac architecture and requires macOS 26 or later. Apple Intelligence summaries use Apple's on-device Foundation Models when available; an offline local sentence is shown when the model is unavailable. The current installer was built with the macOS 26.2 SDK, which does not expose Apple's Private Cloud Compute model API. Enabling that Apple cloud fallback requires a macOS 27 SDK and Apple's managed Private Cloud Compute entitlement. The bundle is ad-hoc signed because this Mac has no Apple Developer ID signing identity installed; Gatekeeper may require manual approval on first launch. The physical MagSafe LED is controlled by macOS and cannot be changed from this app; the selectable color only affects EveryMacTool.

Open the app, then click the bolt/watt item in the menu bar. Use the panel's Settings page to switch Simple/Pro, adjust the glass effect, or enable dashboard performance mode. Performance mode reduces EveryMacTool's sampling frequency; it does not modify macOS power settings or other apps.

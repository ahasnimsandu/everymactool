# Release notes

## 1.0.2 — 2026-10-10

- Show Mac system power draw in the menu bar with one decimal place.
- Set power and network sampling to a 0.5-second default; keep USB and display discovery on its slower scan to limit overhead.
- Identify battery versus external power and add a MagSafe/USB-C charging details card in Devices.
- Refresh the local Quick Mac Read automatically every minute.
- Compact the menu popover and make each pane control a clearly boxed, larger click target.
- Set liquid-glass intensity to 20% by default and preserve the user adjustment in Settings.
- Continue to report unavailable hardware details honestly when macOS does not expose them. Physical MagSafe LED control remains managed by macOS.

### Installer

`EveryMacTool-1.0.2-macOS-arm64.dmg` is a drag-to-Applications installer for Apple silicon Macs running macOS 26 or later. The app is ad-hoc signed; macOS may require approval on first launch.

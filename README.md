# Mischief Managed

**Put your windows in their place.**

Mischief Managed is a native Mac app that remembers your work layouts and lets you share just the part of your screen you choose. Less window shuffling. More actual work.

- **Pick up where you left off.** Save an activity with the windows and websites you use together. Open it when you switch tasks.
- **Make room your way.** Draw unequal tiles, or arrange your windows on the desktop and save their positions. Keep subtle guides visible if you like. Save separate layouts for the displays you use at home and at work.
- **Share a corner of your screen.** Move and resize a capture area, start a preview, then select the Mischief Managed preview window in your meeting app. Anything visible inside that area can appear in the preview, including notifications.

## Build from source

Mischief Managed requires macOS 14 or later and Apple’s Swift development tools. It uses SwiftUI, AppKit and ScreenCaptureKit and has no third-party package dependencies.

```sh
bash scripts/check.sh
open "dist/Mischief Managed.app"
```

The build uses an ad hoc signature by default for local development. To keep the app identity consistent across rebuilds, set `FRAMEDESK_SIGN_IDENTITY` to a signing identity from your own Keychain. If your toolchain stalls in Swift Build, try `FRAMEDESK_BUILD_SYSTEM=native bash scripts/check.sh` on toolchains that still provide the native build engine.

## First use

1. Create an activity and give it a name. Open it to activate its layout.
2. Arrange your windows and choose **Save window arrangement…**. Select the windows you want Mischief Managed to remember. Use **Edit tiles** when you want reusable snap targets.
3. Drag a window by its title bar to snap. Turn on **Show guides** for desktop outlines. Hold Option while dragging to place a window freely.
4. Open **Settings → Display setups** to register each monitor setup. Mischief Managed recognizes registered setups and can restore the active activity’s layout on reconnect if you enable that option.
5. For meetings, choose **Share part of your screen**. Adjust the area if needed, start the preview, then choose its window in your meeting app.

Accessibility lets Mischief Managed read and position windows. Screen Recording lets it create the preview. Edge Automation is optional and only needed for opening or saving website activity windows. Mischief Managed stores layouts locally and makes no recording of the capture stream. A saved layout restores available windows. It cannot reconstruct closed documents or windows in other macOS Spaces.

## License

[MIT](LICENSE).

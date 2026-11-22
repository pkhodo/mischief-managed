# Mischief Managed app icon

Original geometric artwork authored for Mischief Managed on 19 November 2026.

- Source: `scripts/make-icon.swift` (AppKit vector paths and gradients).
- Master: `AppIcon.png`, 1024×1024 with transparent margins and PNG description provenance.
- Shipping icon: `AppIcon.icns`, containing the ten standard 1×/2× macOS icon representations from 16 to 1024 pixels.
- Motif: a tall document window, a cyan reference window and an orange capture quadrant, on an ink-blue macOS rounded square. No font, stock art, third-party logo or external image is used.

Rebuild from the repository root:

```sh
swift -module-cache-path /private/tmp/framedesk-icon-cache scripts/make-icon.swift
```

Apple's `iconutil` needs normal macOS tool execution; this Mac's restricted sandbox reported valid PNGs as an invalid iconset. Running the same packaging command outside that sandbox succeeded. Icon artwork is separate from the system-native in-app color scheme.

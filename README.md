# Shady

A curtain for your Mac. Swipe down with two fingers from just beyond the top
edge of the trackpad. Drag back up, press Escape, or click it to dismiss.

No Dock or menu bar icon — right-click the curtain for its menu.

## First run

macOS blocks it because it is not notarized. After moving it to Applications:

```sh
xattr -dr com.apple.quarantine /Applications/Shady.app
```

Grant Accessibility when it asks (**System Settings > Privacy & Security >
Accessibility**) — without it, scroll suppression and Escape-to-close don't work.

macOS 14+, Apple silicon. Build with `./build.sh`.

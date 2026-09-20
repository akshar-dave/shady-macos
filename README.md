# Shady
iOS like pull-down notification shade for your mac.

## First run

macOS blocks it because it is not notarized. After moving it to Applications:

```sh
xattr -dr com.apple.quarantine /Applications/Shady.app
```

Grant Accessibility when it asks (**System Settings > Privacy & Security >
Accessibility**) — without it, pulling the curtain down also scrolls whatever is
behind it, and Escape won't close it.

macOS 14+, Apple silicon. Build with `./build.sh`.

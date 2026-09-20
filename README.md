# Shady

## First run

Shady is not notarized by Apple, so macOS will refuse to open it until the
quarantine flag is cleared. Run this once, after moving Shady to Applications:

```sh
xattr -dr com.apple.quarantine /Applications/Shady.app
```

Then it opens on a normal double-click.

## Accessibility permission

Shady asks for Accessibility on first launch. Grant it in **System Settings >
Privacy & Security > Accessibility**.

It runs without it, but two things need it:

- scroll suppression, so pulling the curtain down does not also scroll whatever
  is underneath it
- the Escape key closing the curtain from any app

## Using it

Swipe down with **two fingers** from just beyond the top edge of the trackpad —
start with your fingers off the pad and move onto it. A curtain follows them
down. Drag back up, press Escape, or click it to dismiss.

Shady has no Dock icon and no menu bar icon. Right-click the curtain for its
menu: Close, Open at Login, Quit Shady.

On a Mac with no trackpad the gesture can never fire, so a menu bar icon appears
instead — it is the only way to open the curtain there.

## Requirements

macOS 14 (Sonoma) or later, on an Apple silicon Mac.

## Building

```sh
./build.sh     # build/Shady.app
./install.sh   # install to ~/Applications with a launch agent
```

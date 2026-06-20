# ClipMenuModern

A lightweight clipboard history manager for macOS, rebuilt with Swift and AppKit. It runs in the menu bar and supports text, image, and file clipboard entries.

## Acknowledgements

ClipMenuModern is an independent modern reimplementation inspired by [ClipMenu](https://github.com/naotaka/ClipMenu), the original macOS clipboard manager created by [Naotaka Morimoto](https://github.com/naotaka). Its menu-bar workflow and clipboard-management concepts provided the foundation and inspiration for this project.

This project is not an official continuation of ClipMenu. Sincere thanks to Naotaka Morimoto for creating and open-sourcing the original application. The original MIT copyright notice is preserved in [LICENSE](LICENSE).

## Features

- Clipboard history for text, images, and files
- Search, favorites, and configurable history limits
- Reusable snippets and custom text actions
- Global keyboard shortcut and optional automatic paste
- English and Simplified Chinese interface
- Local-only storage

## Privacy

Clipboard history, snippets, settings, and cached images are created locally at runtime under:

```text
~/Library/Application Support/ClipMenuModern/
```

This repository does not contain the author's clipboard history, personal snippets, settings, or cached clipboard images. The included `.gitignore` also excludes these files if they are copied into the project accidentally.

## Requirements

- macOS 12.0 or later
- Xcode with the macOS SDK

## Download

Prebuilt universal macOS packages are available on the [Releases](https://github.com/sarayaya/ClipMenuModern/releases) page.

The current package is not notarized with an Apple Developer ID. On first launch, Control-click the app, choose **Open**, then confirm **Open**. macOS may also require approval in **System Settings → Privacy & Security**.

### If macOS says it cannot check the app for malicious software

This warning appears because the current release is not notarized with an Apple Developer ID. It does not indicate that the ZIP is damaged.

First try the standard macOS override:

1. Attempt to open `ClipMenuModern.app` once.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the **Security** section and click **Open Anyway** for ClipMenuModern.
4. Authenticate, then confirm **Open**.

If **Open Anyway** is unavailable, move the app to the Applications folder and run:

```bash
xattr -dr com.apple.quarantine /Applications/ClipMenuModern.app
open /Applications/ClipMenuModern.app
```

Only remove the quarantine attribute from an app you downloaded from this repository and trust. You can compare the ZIP's SHA-256 checksum with the value shown in the corresponding Release notes before opening it.

## Build

1. Clone this repository.
2. Open `ClipMenuModern.xcodeproj` in Xcode.
3. Select the `ClipMenuModern` scheme and the **My Mac** destination.
4. Build and run.

Automatic paste may require Accessibility permission in **System Settings → Privacy & Security → Accessibility**.

## License

MIT. See [LICENSE](LICENSE), which preserves the original ClipMenu copyright notice.

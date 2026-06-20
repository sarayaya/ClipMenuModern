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

## Build

1. Clone this repository.
2. Open `ClipMenuModern.xcodeproj` in Xcode.
3. Select the `ClipMenuModern` scheme and the **My Mac** destination.
4. Build and run.

Automatic paste may require Accessibility permission in **System Settings → Privacy & Security → Accessibility**.

## License

MIT. See [LICENSE](LICENSE), which preserves the original ClipMenu copyright notice.

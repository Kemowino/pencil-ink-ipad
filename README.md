# Pencil Ink Native (iPadOS — Rough Draft v0.1.0)

Native UIKit + PDFKit companion app for Obsidian Pencil Ink.

- **True UIKit Hardware Touch Splitting**: `UIScrollView` accepts only `.direct` touches (fingers), while `PencilDrawingGestureRecognizer` accepts only `.pencil` touches — giving native Apple palm rejection and 0ms scroll transitions.
- **1-Tap 2-Finger Scroll Lock**: Tap the hand/lock icon in the toolbar to switch `UIScrollView` to 2-finger scrolling for 100% forearm immunity.
- **Exact `.ink.json` Compatibility**: Opens PDFs in-place from your Obsidian vault folder and reads/writes the exact `.ink.json` sidecar files without re-uploading large PDFs.
- **Zero-Mac Cloud Builds**: Push to GitHub and download `PencilInkNative.ipa` from the **Actions** tab to install in LiveContainer.

# just_screenshot

A Flutter plugin for capturing screenshots on Windows desktop. Supports full screen capture and interactive region selection.

## Features

- 🖥️ **Full Screen Capture**: Capture the entire primary display with a single call
- ✂️ **Region Selection**: Interactive overlay for selecting and capturing specific screen areas
- 📌 **Pinned Region Capture**: Re-capture a previously selected physical rectangle on demand
- 🖱️ **Cursor Support**: Optional cursor inclusion in screenshots
- 🎨 **PNG Encoding**: Lossless PNG format with automatic encoding
- ⚡ **High Performance**: Fast native Windows implementation using Win32 APIs
- 🎯 **DPI Aware**: Correct handling of high-DPI displays (125%, 150%, 200% scaling)

## Platform Support

| Platform | Support |
|----------|---------|
| Windows  | ✅ Full |
| macOS    | ❌ Not yet |
| Linux    | ❌ Not yet |

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  just_screenshot: ^0.1.0
```

Then run:

```bash
flutter pub get
```

## Usage

### Capture Full Screen

```dart
import 'package:just_screenshot/screenshot.dart';

// Capture the entire primary display
final CapturedData? data = await Screenshot.instance.capture(
  mode: ScreenshotMode.screen,
  includeCursor: true, // Optional, defaults to false
);

if (data != null) {
  print('Captured ${data.width}x${data.height} screenshot');
  // Use data.bytes (PNG-encoded Uint8List)
  Image.memory(data.bytes);
}
```

### Re-capture a Previous Region

```dart
final previousBounds = data?.bounds;
if (previousBounds != null) {
  // Captures only this rectangle; it does not show the interactive selector.
  // Bounds use physical screen pixels and may have negative origins.
  final refreshed = await Screenshot.instance.captureAtBounds(previousBounds);
}
```

### Capture Screen Region

```dart
import 'package:screenshot/screenshot.dart';

// Show interactive overlay for region selection
final CapturedData? data = await Screenshot.instance.capture(
  mode: ScreenshotMode.region,
);

if (data != null) {
  print('Captured region: ${data.width}x${data.height}');
  Image.memory(data.bytes);
} else {
  print('User cancelled selection');
}
```

### Error Handling

```dart
import 'package:screenshot/screenshot.dart';

try {
  final CapturedData? data = await Screenshot.instance.capture(
    mode: ScreenshotMode.screen,
  );
  
  if (data != null) {
    // Screenshot captured successfully
    Image.memory(data.bytes);
  } else {
    // User cancelled (region mode only)
    print('Capture cancelled');
  }
} on ScreenshotException catch (e) {
  // Handle errors
  switch (e.code) {
    case 'cancelled':
      print('User cancelled: ${e.message}');
      break;
    case 'internal_error':
      print('Internal error: ${e.message}');
      print('Details: ${e.details}');
      break;
    case 'invalid_argument':
      print('Invalid argument: ${e.message}');
      break;
    default:
      print('Error: ${e.message}');
  }
}
```

## API Reference

### Screenshot

Singleton class providing screenshot capture functionality.

#### Methods

- `capture({required ScreenshotMode mode, bool includeCursor = false, int? displayId})`: Capture a screenshot
  - `mode`: Capture mode (screen or region)
  - `includeCursor`: Whether to include the cursor (default: false)
  - `displayId`: Target display ID (default: null = primary display)
  - Returns: `Future<CapturedData?>` - Captured screenshot or null if cancelled
- `captureAtBounds(ScreenshotBounds bounds)`: Capture an existing physical rectangle without opening the selector
  - Rejects stale regions, gaps between monitors, invalid dimensions, and areas above 20 megapixels

### ScreenshotMode

Enum defining capture behavior:
- `screen`: Capture entire primary display
- `region`: User-selected rectangular area via interactive overlay

### CapturedData

Immutable class containing screenshot data:
- `width` (int): Image width in pixels
- `height` (int): Image height in pixels  
- `bytes` (Uint8List): PNG-encoded image data

### ScreenshotException

Exception thrown when capture fails:
- `code` (String): Error code (cancelled, internal_error, invalid_argument, not_supported)
- `message` (String): Human-readable error message
- `details` (dynamic): Optional additional error details

## Region Selection Controls

When using `ScreenshotMode.region`, an interactive overlay appears:

- **Left-click and drag**: Select rectangular region
- **Drag the eight handles**: Resize the selected region
- **Drag inside the selection**: Move the selected region
- **Enter**: Confirm the current selection and capture
- **ESC key**: Cancel selection
- **Right-click**: Cancel selection
- Selections smaller than 12 × 12 physical pixels must be redrawn

## Requirements

- Flutter 3.3.0 or higher
- Dart 3.7.2 or higher
- Windows 10 or higher

## Performance

- Full screen capture: <500ms @ 1920x1080
- Overlay responsiveness: <16ms (60 FPS mouse tracking)
- Memory usage: <100MB per capture

## Example

See the `example/` directory for a complete demonstration app showing both screen and region capture modes.

```bash
cd example
flutter run -d windows
```

## Contributing

Contributions are welcome! Please read the contributing guidelines before submitting pull requests.

## License

This project is licensed under the BSD 3-Clause License - see the LICENSE file for details.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Issues

Please file issues on the [GitHub issue tracker](https://github.com/yourusername/screenshot/issues).

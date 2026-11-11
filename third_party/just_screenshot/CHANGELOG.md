# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-12-03

### Added
- Initial release of Windows screenshot plugin
- Full screen capture support (ScreenshotMode.screen)
- Interactive region selection with overlay (ScreenshotMode.region)
- Optional cursor inclusion in screenshots
- PNG encoding for captured images
- DPI awareness for high-resolution displays
- Comprehensive error handling with typed exceptions (ScreenshotException)
- Support for cancellation in region mode (ESC key or right-click)
- Native Windows implementation using Win32 APIs (BitBlt, WIC)
- Example application demonstrating all features

### Features
- **User Story 1**: Capture full screen screenshot with single API call
- **User Story 2**: Select and capture screen region via interactive overlay
- **User Story 3**: Graceful cancellation handling and error reporting

### Platform Support
- Windows 10+ (x64)

### Performance
- Full screen capture: <500ms @ 1920x1080
- Overlay mouse tracking: <16ms (60 FPS)
- Memory usage: <100MB per capture

### Requirements
- Flutter 3.3.0+
- Dart 3.7.2+
- Windows 10+

## [0.0.1] - Initial Template

* Initial plugin template (not released)

typedef ScreenshotHostExit = Future<void> Function();

/// Resolves an explicit screenshot-tool quit through the owning app's exit
/// controller when it is available.
///
/// The direct window close is only a fallback for standalone previews that do
/// not have the main application shell's close controller.
ScreenshotHostExit resolveScreenshotHostExit({
  required ScreenshotHostExit? requestHostClose,
  required ScreenshotHostExit closeWindow,
}) => requestHostClose ?? closeWindow;

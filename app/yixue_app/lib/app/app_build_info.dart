abstract final class AppBuildInfo {
  static const label = String.fromEnvironment(
    'YIXUE_BUILD_LABEL',
    defaultValue: '开发版',
  );
}

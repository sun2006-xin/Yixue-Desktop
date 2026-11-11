import 'package:yixue_app/core/model_package_discovery_service.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length > 1) {
    throw ArgumentError('expected zero or one scan root');
  }
  const service = ModelPackageDiscoveryService(maximumDepth: 10);
  final roots = arguments.isEmpty
      ? await service.recommendedSearchRoots()
      : arguments;
  final models = await service.discoverModels(roots);
  for (final model in models) {
    // This developer smoke tool intentionally reports only model metadata.
    // ignore: avoid_print
    print('${model.displayName}|${model.familyLabel}|${model.readinessLabel}');
  }
}

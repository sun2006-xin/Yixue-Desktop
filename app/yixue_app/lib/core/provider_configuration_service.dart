import 'dart:async';
import 'dart:io';

import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/provider_secret_store.dart';

bool isLocalCompatibleEndpoint(String? rawEndpoint) {
  final uri = Uri.tryParse(rawEndpoint?.trim() ?? '');
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return host == 'localhost' ||
      InternetAddress.tryParse(host)?.isLoopback == true;
}

void _validateRemoteEndpoint(String rawEndpoint) {
  final endpoint = Uri.tryParse(rawEndpoint.trim());
  if (endpoint == null ||
      !endpoint.hasAuthority ||
      (endpoint.scheme != 'http' && endpoint.scheme != 'https')) {
    throw const FormatException('remote endpoint is invalid');
  }
}

void _requireApiKeyForPublicEndpoint({
  required String endpoint,
  required String apiKey,
}) {
  if (apiKey.trim().isEmpty && !isLocalCompatibleEndpoint(endpoint)) {
    throw const FormatException('remote API key is required');
  }
}

class ProviderConfigurationService {
  const ProviderConfigurationService(this._core, this._secrets);

  final AppCore _core;
  final ProviderSecretStore _secrets;

  void saveLocalProvider({
    required String id,
    required String displayName,
    required String modelId,
    required String modelPath,
  }) {
    _core.saveProviderProfile(
      ProviderProfileData(
        id: id,
        displayName: displayName,
        kind: ProviderProfileKind.localModel,
        enabled: false,
        modelId: modelId,
        modelPath: modelPath,
      ),
    );
  }

  void saveValidatedLocalProvider({
    required ModelPackageValidationData package,
    required String modelPath,
  }) {
    _core.saveProviderProfile(
      ProviderProfileData(
        id: package.packageId,
        displayName: package.displayName,
        kind: ProviderProfileKind.localModel,
        enabled: true,
        modelId: package.baseModel,
        modelPath: modelPath,
        assignedRoles: const {ModelRole.translation},
      ),
    );
  }

  Future<void> saveRemoteProvider({
    required String id,
    required String displayName,
    required String endpoint,
    required String modelId,
    String apiKey = '',
    bool enabled = false,
    Set<ModelRole> assignedRoles = const {},
  }) async {
    final normalizedKey = apiKey.trim();
    final normalizedEndpoint = endpoint.trim();
    _validateRemoteEndpoint(normalizedEndpoint);
    _requireApiKeyForPublicEndpoint(
      endpoint: normalizedEndpoint,
      apiKey: normalizedKey,
    );
    final secretReference = normalizedKey.isEmpty
        ? null
        : await _secrets.saveApiKey(id, normalizedKey);
    try {
      _core.saveProviderProfile(
        ProviderProfileData(
          id: id,
          displayName: displayName,
          kind: ProviderProfileKind.remoteApi,
          enabled: enabled,
          modelId: modelId.trim(),
          endpoint: normalizedEndpoint,
          secretRef: secretReference,
          assignedRoles: assignedRoles,
        ),
      );
    } catch (error, stackTrace) {
      if (secretReference != null) await _secrets.deleteApiKey(id);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  List<ProviderProfileData> listProviders() => _core.listProviderProfiles();

  Future<void> deleteProvider(String providerId) async {
    final matching = _core.listProviderProfiles().where(
      (candidate) => candidate.id == providerId,
    );
    if (matching.isEmpty) return;
    final profile = matching.first;
    _core.deleteProviderProfile(providerId);
    if (profile.kind == ProviderProfileKind.remoteApi) {
      await _secrets.deleteApiKey(profile.id);
    }
  }

  Future<void> updateRemoteProvider({
    required ProviderProfileData existing,
    required String displayName,
    required String endpoint,
    required String modelId,
    String apiKey = '',
  }) async {
    if (existing.kind != ProviderProfileKind.remoteApi) {
      throw const FormatException('only remote providers can be edited');
    }
    final normalizedEndpoint = endpoint.trim();
    _validateRemoteEndpoint(normalizedEndpoint);
    final replacementKey = apiKey.trim();
    String? previousKey;
    if (replacementKey.isNotEmpty) {
      try {
        previousKey = await _secrets.resolveApiKey(existing.id);
      } on ProviderCredentialException {
        previousKey = null;
      }
      await _secrets.saveApiKey(existing.id, replacementKey);
    } else if (!isLocalCompatibleEndpoint(normalizedEndpoint) &&
        existing.secretRef == null) {
      // A blank field means "keep the existing key". An existing reference
      // remains opaque here; connection testing reports if its backing
      // credential is missing. A public provider with no reference at all is
      // still rejected before it can be saved.
      throw const FormatException('remote API key is required');
    }
    try {
      _core.saveProviderProfile(
        ProviderProfileData(
          id: existing.id,
          displayName: displayName.trim(),
          kind: ProviderProfileKind.remoteApi,
          enabled: existing.enabled,
          modelId: modelId.trim(),
          endpoint: normalizedEndpoint,
          secretRef: existing.secretRef,
          assignedRoles: existing.assignedRoles,
        ),
      );
    } catch (error, stackTrace) {
      if (replacementKey.isNotEmpty && previousKey != null) {
        await _secrets.saveApiKey(existing.id, previousKey);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

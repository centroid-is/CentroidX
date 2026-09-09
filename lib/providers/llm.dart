import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:tfc_dart/core/preferences.dart';

import '../llm/llm_models.dart';
import '../llm/llm_provider.dart';
import 'preferences.dart';
import 'preferences_local_store.dart';

part 'llm.g.dart';

/// Reads the API key for the given [type] from secure storage.
///
/// Returns null if no key is stored.
@Riverpod(keepAlive: true)
Future<String?> llmApiKey(Ref ref, LlmProviderType type) async {
  final prefs = await ref.watch(localStorePreferencesProvider.future);
  final key = switch (type) {
    LlmProviderType.claude => kClaudeApiKey,
    LlmProviderType.openai => kOpenAiApiKey,
    LlmProviderType.gemini => kGeminiApiKey,
  };
  return prefs.getString(key, secret: true);
}

/// Reads the custom base URL for the given [type] from preferences.
///
/// Returns null if no custom base URL is stored (uses provider default).
@Riverpod(keepAlive: true)
Future<String?> llmBaseUrl(Ref ref, LlmProviderType type) async {
  final prefs = await ref.watch(localStorePreferencesProvider.future);
  final key = switch (type) {
    LlmProviderType.claude => kClaudeBaseUrl,
    LlmProviderType.openai => kOpenAiBaseUrl,
    LlmProviderType.gemini => null, // Gemini doesn't support custom base URL
  };
  if (key == null) return null;
  return prefs.getString(key);
}

/// Reads the currently selected LLM provider type from preferences.
///
/// Returns null if no provider has been selected.
@Riverpod(keepAlive: true)
Future<LlmProviderType?> selectedLlmProvider(Ref ref) async {
  final prefs = await ref.watch(localStorePreferencesProvider.future);
  final value = await prefs.getString(kSelectedProvider);
  if (value == null) return null;
  return LlmProviderType.values.where((e) => e.name == value).firstOrNull;
}

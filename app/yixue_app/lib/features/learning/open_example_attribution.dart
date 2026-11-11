import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yixue_app/core/dictionary_cet_open_rich_examples_model.dart';
import 'package:yixue_app/core/windows_associated_file_opener.dart';

/// Keeps the source and author details beside an open-source example candidate.
/// The sentence itself remains marked as unreviewed learning material.
class OpenExampleAttribution extends StatelessWidget {
  const OpenExampleAttribution({
    required this.candidate,
    this.onOpenUri,
    super.key,
  });

  final OpenCetRichExampleRow candidate;
  final ValueChanged<Uri>? onOpenUri;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final identifiers = candidate.exampleId.split(':');
    final isTatoeba =
        candidate.sourceId.startsWith('tatoeba') &&
        identifiers.length == 3 &&
        identifiers.skip(1).every((value) => RegExp(r'^\d+$').hasMatch(value));
    final sourceLabel = isTatoeba
        ? 'Tatoeba · 文本默认 CC BY 2.0 FR（本条许可未核）· 待审校候选'
        : '${candidate.sourceId} · 待审校候选';
    final englishUsername = _normalizeUsername(candidate.englishUsername);
    final chineseUsername = _normalizeUsername(candidate.chineseUsername);
    final authorLine = isTatoeba
        ? [
            englishUsername.isEmpty ? '英文作者未提供' : '英文作者 $englishUsername',
            chineseUsername.isEmpty ? '中文作者未提供' : '中文作者 $chineseUsername',
          ].join(' · ')
        : [
            if (englishUsername.isNotEmpty) '英文作者 $englishUsername',
            if (chineseUsername.isNotEmpty) '中文作者 $chineseUsername',
          ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sourceLabel,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (authorLine.isNotEmpty)
            Text(
              authorLine,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          if (isTatoeba)
            Wrap(
              spacing: 4,
              runSpacing: 0,
              children: [
                _attributionLink(
                  context,
                  key: const ValueKey('tatoeba-license-url'),
                  label: '许可 · CC BY 2.0 FR',
                  uri: Uri.parse(
                    'https://creativecommons.org/licenses/by/2.0/fr/',
                  ),
                ),
                _attributionLink(
                  context,
                  key: ValueKey('tatoeba-source-${identifiers[1]}'),
                  label: '英文原句 · ${identifiers[1]}',
                  uri: Uri.parse(
                    'https://tatoeba.org/en/sentences/show/${identifiers[1]}',
                  ),
                ),
                _attributionLink(
                  context,
                  key: ValueKey('tatoeba-source-${identifiers[2]}'),
                  label: '中文句子 · ${identifiers[2]}',
                  uri: Uri.parse(
                    'https://tatoeba.org/en/sentences/show/${identifiers[2]}',
                  ),
                ),
              ],
            )
          else
            SelectableText(
              '来源编号 ${candidate.exampleId}',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _attributionLink(
    BuildContext context, {
    required Key key,
    required String label,
    required Uri uri,
  }) {
    return TextButton(
      key: key,
      onPressed: () => _openUri(context, uri),
      style: TextButton.styleFrom(
        alignment: Alignment.centerLeft,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        tapTargetSize: MaterialTapTargetSize.padded,
        visualDensity: VisualDensity.standard,
      ),
      child: Tooltip(
        message: uri.toString(),
        child: Text(label, style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }

  Future<void> _openUri(BuildContext context, Uri uri) async {
    final injectedOpener = onOpenUri;
    if (injectedOpener != null) {
      try {
        injectedOpener(uri);
        return;
      } on Object {
        // Keep the URL usable through the clipboard fallback below.
      }
    } else if (Platform.isWindows) {
      try {
        openWindowsAssociatedFile(uri.toString());
        return;
      } on Object {
        // Fall back to copying the verified HTTPS URL if the registered
        // browser cannot be opened.
      }
    }
    await Clipboard.setData(ClipboardData(text: uri.toString()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('链接已复制，可粘贴到浏览器打开。')));
  }

  String _normalizeUsername(String value) {
    final normalized = value.trim();
    return normalized.isEmpty || normalized == r'\N' ? '' : normalized;
  }
}

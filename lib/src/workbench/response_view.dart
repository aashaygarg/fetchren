import 'package:flutter/material.dart';

import '../http/body_formatter.dart';
import '../http/request_outcome.dart';
import '../util/format.dart';
import 'workbench_controller.dart';

/// Maximum characters rendered in the body view to keep the UI responsive.
const int maxDisplayedBodyChars = 200000;

/// Shows the loading, empty, error, or response state of the last request.
class ResponseView extends StatelessWidget {
  const ResponseView({super.key, required this.controller});

  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.isSending) {
      return const Center(
        key: Key('response-loading'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Sending request…'),
          ],
        ),
      );
    }
    return switch (controller.outcome) {
      null => const Center(
        key: Key('response-empty'),
        child: Text('Send a request to see the response here.'),
      ),
      final RequestFailure failure => _FailureView(failure: failure),
      final ApiResponse response => _ResponseDetails(response: response),
    };
  }
}

class _FailureView extends StatelessWidget {
  const _FailureView({required this.failure});

  final RequestFailure failure;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      key: const Key('response-error'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: colors.error, size: 40),
            const SizedBox(height: 12),
            Text(
              failure.kind.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            SelectableText(failure.message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ResponseDetails extends StatefulWidget {
  const _ResponseDetails({required this.response});

  final ApiResponse response;

  @override
  State<_ResponseDetails> createState() => _ResponseDetailsState();
}

class _ResponseDetailsState extends State<_ResponseDetails> {
  bool _showRaw = false;
  // Cached: the parent rebuilds on every keystroke in the request editor.
  late final FormattedBody _formatted = formatBody(
    widget.response.body,
    contentType: widget.response.contentType,
  );

  @override
  Widget build(BuildContext context) {
    final response = widget.response;
    final formatted = _formatted;
    final showPretty = formatted.isJson && !_showRaw;
    final text = showPretty ? formatted.text : response.body;
    final truncated = text.length > maxDisplayedBodyChars;
    final colors = Theme.of(context).colorScheme;
    final statusColor = response.isSuccess ? Colors.green : colors.error;
    final reason = response.reasonPhrase;

    return DefaultTabController(
      length: 2,
      child: Column(
        key: const Key('response-details'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Wrap(
              spacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  reason == null || reason.isEmpty
                      ? '${response.statusCode}'
                      : '${response.statusCode} $reason',
                  key: const Key('response-status'),
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(formatDuration(response.elapsed)),
                Text(formatBytes(response.bodyBytes.length)),
                if (formatted.isJson)
                  FilterChip(
                    label: const Text('Raw'),
                    selected: _showRaw,
                    onSelected: (raw) => setState(() => _showRaw = raw),
                  ),
              ],
            ),
          ),
          TabBar(
            tabs: [
              const Tab(text: 'Body'),
              Tab(text: 'Headers (${response.headers.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    if (truncated)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Showing the first $maxDisplayedBodyChars of '
                          '${text.length} characters.',
                          style: TextStyle(color: colors.tertiary),
                        ),
                      ),
                    if (text.isEmpty)
                      const Text('(empty body)')
                    else
                      SelectableText(
                        truncated
                            ? text.substring(0, maxDisplayedBodyChars)
                            : text,
                        key: const Key('response-body'),
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final entry in response.headers.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: SelectableText.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${entry.key}: ',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              TextSpan(text: entry.value),
                            ],
                          ),
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

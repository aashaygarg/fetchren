import 'package:flutter/material.dart';

import 'workbench_controller.dart';

const int _maxTimeoutSeconds = 600;
const int _maxResponseMegabytes = 100;

/// Lets the user change the request timeout and maximum response size.
Future<void> showSettingsDialog(
  BuildContext context,
  WorkbenchController controller,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => _SettingsDialog(controller: controller),
  );
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.controller});

  final WorkbenchController controller;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _timeout = TextEditingController(
    text: '${widget.controller.timeout.inSeconds}',
  );
  late final TextEditingController _maxSize = TextEditingController(
    text: '${widget.controller.maxResponseBytes ~/ (1024 * 1024)}',
  );

  @override
  void dispose() {
    _timeout.dispose();
    _maxSize.dispose();
    super.dispose();
  }

  String? Function(String?) _rangeValidator(int max) => (value) {
    final parsed = int.tryParse(value?.trim() ?? '');
    if (parsed == null || parsed < 1 || parsed > max) {
      return 'Enter a whole number from 1 to $max';
    }
    return null;
  };

  void _apply() {
    if (!_formKey.currentState!.validate()) return;
    widget.controller.updateSettings(
      timeout: Duration(seconds: int.parse(_timeout.text.trim())),
      maxResponseBytes: int.parse(_maxSize.text.trim()) * 1024 * 1024,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Request settings'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('timeout-field'),
              controller: _timeout,
              decoration: const InputDecoration(labelText: 'Timeout (seconds)'),
              validator: _rangeValidator(_maxTimeoutSeconds),
            ),
            TextFormField(
              key: const Key('max-size-field'),
              controller: _maxSize,
              decoration: const InputDecoration(
                labelText: 'Maximum response size (MB)',
              ),
              validator: _rangeValidator(_maxResponseMegabytes),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('settings-apply'),
          onPressed: _apply,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

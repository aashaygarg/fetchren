import 'package:flutter/material.dart';

import '../models/http_method.dart';
import 'request_editor.dart';
import 'response_view.dart';
import 'saved_requests_panel.dart';
import 'settings_dialog.dart';
import 'workbench_controller.dart';

/// Main desktop screen: saved requests, request editor, and response viewer.
class WorkbenchScreen extends StatefulWidget {
  const WorkbenchScreen({super.key, required this.controller});

  final WorkbenchController controller;

  @override
  State<WorkbenchScreen> createState() => _WorkbenchScreenState();
}

class _WorkbenchScreenState extends State<WorkbenchScreen> {
  late final TextEditingController _url = TextEditingController(
    text: widget.controller.url,
  );
  late int _revision = widget.controller.draftRevision;

  WorkbenchController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncDraft);
  }

  @override
  void dispose() {
    _controller.removeListener(_syncDraft);
    _url.dispose();
    super.dispose();
  }

  void _syncDraft() {
    if (_controller.draftRevision == _revision) return;
    _revision = _controller.draftRevision;
    _url.text = _controller.url;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FetchRen'),
        actions: [
          IconButton(
            tooltip: 'Request settings',
            icon: const Icon(Icons.tune),
            onPressed: () => showSettingsDialog(context, _controller),
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 260,
            child: SavedRequestsPanel(controller: _controller),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _RequestBar(controller: _controller, url: _url),
                  const Divider(height: 1),
                  Expanded(child: _buildPanes()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanes() {
    final editor = RequestEditor(
      key: ValueKey('editor-${_controller.draftRevision}'),
      controller: _controller,
    );
    final response = ResponseView(controller: _controller);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 1000) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: editor),
              const VerticalDivider(width: 1),
              Expanded(child: response),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 2, child: editor),
            const Divider(height: 1),
            Expanded(flex: 3, child: response),
          ],
        );
      },
    );
  }
}

class _RequestBar extends StatelessWidget {
  const _RequestBar({required this.controller, required this.url});

  final WorkbenchController controller;
  final TextEditingController url;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          DropdownButton<HttpMethod>(
            key: const Key('method-dropdown'),
            value: controller.method,
            underline: const SizedBox.shrink(),
            items: [
              for (final method in HttpMethod.values)
                DropdownMenuItem(value: method, child: Text(method.wireName)),
            ],
            onChanged: (method) {
              if (method != null) controller.setMethod(method);
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const Key('url-field'),
              controller: url,
              decoration: const InputDecoration(
                hintText: 'https://api.example.com/resource',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: controller.setUrl,
              onSubmitted: (_) => controller.send(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            key: const Key('send-button'),
            onPressed: controller.isSending ? null : controller.send,
            icon: const Icon(Icons.send),
            label: const Text('Send'),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message:
                'Saves locally. Values of Authorization, Cookie and API-key '
                'headers are not saved.',
            child: OutlinedButton.icon(
              key: const Key('save-button'),
              onPressed: controller.save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}

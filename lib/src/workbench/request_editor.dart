import 'package:fetchren_core/fetchren_core.dart';
import 'package:flutter/material.dart';

import 'workbench_controller.dart';

/// Tabs for editing request headers and body.
///
/// Recreated (via key) when the draft is replaced so text fields reset.
class RequestEditor extends StatefulWidget {
  const RequestEditor({super.key, required this.controller});

  final WorkbenchController controller;

  @override
  State<RequestEditor> createState() => _RequestEditorState();
}

class _RequestEditorState extends State<RequestEditor> {
  late final TextEditingController _body = TextEditingController(
    text: widget.controller.body,
  );

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Headers'),
              Tab(text: 'Body'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _HeadersEditor(controller: controller),
                controller.method.allowsBody
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: TextField(
                          key: const Key('body-field'),
                          controller: _body,
                          onChanged: controller.setBody,
                          expands: true,
                          maxLines: null,
                          textAlignVertical: TextAlignVertical.top,
                          style: const TextStyle(fontFamily: 'monospace'),
                          decoration: const InputDecoration(
                            hintText: 'Request body',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      )
                    : Center(
                        child: Text(
                          '${controller.method.wireName} requests are sent '
                          'without a body.',
                        ),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeadersEditor extends StatelessWidget {
  const _HeadersEditor({required this.controller});

  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    final headers = controller.headers;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final header in headers)
          _HeaderRow(
            key: ValueKey(header.id),
            header: header,
            controller: controller,
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('add-header-button'),
            onPressed: controller.addHeader,
            icon: const Icon(Icons.add),
            label: const Text('Add header'),
          ),
        ),
      ],
    );
  }
}

class _HeaderRow extends StatefulWidget {
  const _HeaderRow({super.key, required this.header, required this.controller});

  final HeaderEntry header;
  final WorkbenchController controller;

  @override
  State<_HeaderRow> createState() => _HeaderRowState();
}

class _HeaderRowState extends State<_HeaderRow> {
  late final TextEditingController _name = TextEditingController(
    text: widget.header.name,
  );
  late final TextEditingController _value = TextEditingController(
    text: widget.header.value,
  );

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final header = widget.header;
    final controller = widget.controller;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Checkbox(
            value: header.enabled,
            onChanged: (enabled) =>
                controller.updateHeader(header.id, enabled: enabled ?? false),
          ),
          Expanded(
            child: TextField(
              controller: _name,
              onChanged: (name) =>
                  controller.updateHeader(header.id, name: name),
              decoration: const InputDecoration(
                hintText: 'Name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: _value,
              onChanged: (value) =>
                  controller.updateHeader(header.id, value: value),
              decoration: const InputDecoration(
                hintText: 'Value',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Remove header',
            icon: const Icon(Icons.close),
            onPressed: () => controller.removeHeader(header.id),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'workbench_controller.dart';

/// Sidebar listing locally saved requests.
class SavedRequestsPanel extends StatelessWidget {
  const SavedRequestsPanel({super.key, required this.controller});

  final WorkbenchController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final saved = controller.savedRequests;
        final message = controller.storageMessage;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Saved', style: theme.textTheme.titleSmall),
                  ),
                  TextButton.icon(
                    key: const Key('new-request-button'),
                    onPressed: controller.newRequest,
                    icon: const Icon(Icons.add),
                    label: const Text('New'),
                  ),
                ],
              ),
            ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  message,
                  key: const Key('storage-message'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Expanded(
              child: !controller.isLoaded
                  ? const Center(child: CircularProgressIndicator())
                  : saved.isEmpty
                  ? const Center(child: Text('No saved requests'))
                  : ListView(
                      children: [
                        for (final request in saved)
                          ListTile(
                            key: ValueKey('saved-${request.id}'),
                            dense: true,
                            selected: request.id == controller.activeId,
                            leading: Text(
                              request.template.method.wireName,
                              style: theme.textTheme.labelSmall,
                            ),
                            title: Text(
                              request.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => controller.open(request),
                            trailing: IconButton(
                              tooltip: 'Delete',
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () => controller.delete(request.id),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

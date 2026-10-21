import 'package:fetchren_core/fetchren_core.dart';
import 'package:flutter/foundation.dart';

import '../http/request_executor.dart';
import '../http/request_outcome.dart';

/// Holds the editable request draft, saved requests, and the last outcome.
class WorkbenchController extends ChangeNotifier {
  /// Lists and saves requests in [collection].
  ///
  /// Pass `persistenceAvailable: false` when the storage could not be opened;
  /// changes then stay in memory and [startupMessage] explains why.
  WorkbenchController({
    required this._executor,
    required this._repository,
    required this._collection,
    DateTime Function()? clock,
    bool persistenceAvailable = true,
    String? startupMessage,
  }) : _clock = clock ?? DateTime.now,
       _canPersist = persistenceAvailable,
       _storageMessage = startupMessage;

  final RequestExecutor _executor;
  final WorkspaceRepository _repository;
  final Collection _collection;
  final DateTime Function() _clock;
  // Resolution never writes back: saved templates keep their raw values.
  final RequestResolver _resolver = const LiteralRequestResolver();

  HttpMethod _method = HttpMethod.get;
  String _url = '';
  List<HeaderEntry> _headers = [HeaderEntry.create()];
  String _body = '';
  String? _activeId;
  List<RequestItem> _saved = const [];
  bool _isLoaded = false;
  bool _isSending = false;
  RequestOutcome? _outcome;
  String? _storageMessage;
  bool _canPersist;
  int _draftRevision = 0;

  HttpMethod get method => _method;
  String get url => _url;
  List<HeaderEntry> get headers => List.unmodifiable(_headers);
  String get body => _body;

  /// ID of the saved request currently being edited, if any.
  String? get activeId => _activeId;

  /// Saved requests, most recently updated first.
  List<RequestItem> get savedRequests => List.unmodifiable(_saved);
  bool get isLoaded => _isLoaded;
  bool get isSending => _isSending;
  RequestOutcome? get outcome => _outcome;
  String? get storageMessage => _storageMessage;

  /// Increments whenever the whole draft is replaced, so editors can reset.
  int get draftRevision => _draftRevision;

  Duration get timeout => _executor.timeout;
  int get maxResponseBytes => _executor.maxResponseBytes;

  Future<void> load() async {
    try {
      _saved = await _readSaved();
    } on Exception {
      _canPersist = false;
      _storageMessage =
          'Saved requests could not be loaded. Saving is disabled to avoid '
          'overwriting them.';
    }
    _isLoaded = true;
    notifyListeners();
  }

  void setMethod(HttpMethod method) {
    _method = method;
    notifyListeners();
  }

  void setUrl(String url) {
    _url = url;
    notifyListeners();
  }

  void setBody(String body) {
    _body = body;
    notifyListeners();
  }

  void addHeader() {
    _headers = [..._headers, HeaderEntry.create()];
    notifyListeners();
  }

  void updateHeader(String id, {String? name, String? value, bool? enabled}) {
    _headers = [
      for (final header in _headers)
        header.id == id
            ? header.copyWith(name: name, value: value, enabled: enabled)
            : header,
    ];
    notifyListeners();
  }

  void removeHeader(String id) {
    _headers = [
      for (final header in _headers)
        if (header.id != id) header,
    ];
    if (_headers.isEmpty) _headers = [HeaderEntry.create()];
    notifyListeners();
  }

  void updateSettings({Duration? timeout, int? maxResponseBytes}) {
    if (timeout != null) _executor.timeout = timeout;
    if (maxResponseBytes != null) {
      _executor.maxResponseBytes = maxResponseBytes;
    }
    notifyListeners();
  }

  Future<void> send() async {
    if (_isSending) return;
    final revision = _draftRevision;
    _isSending = true;
    _outcome = null;
    notifyListeners();
    RequestOutcome outcome;
    try {
      outcome = await _executor.execute(
        _resolver.resolve(
          RequestTemplate(
            method: _method,
            url: _url,
            headers: _headers,
            body: _body,
          ),
        ),
      );
    } on Object {
      // Last-resort guard so an unexpected error never leaves Send disabled.
      outcome = const RequestFailure(
        FailureKind.network,
        'The request could not be completed.',
      );
    }
    _isSending = false;
    // Drop the result if another request was opened while this one was in flight.
    if (revision == _draftRevision) _outcome = outcome;
    notifyListeners();
  }

  /// Creates a new saved request or updates the active one.
  Future<void> save() async {
    final now = _clock().toUtc();
    final template = RequestTemplate(
      method: _method,
      url: _url,
      headers: _headers,
      body: _body,
    );
    final existing = _saved.where((r) => r.id == _activeId).firstOrNull;
    final request = existing == null
        ? RequestItem(
            meta: EntityMeta.create(now: now, sortKey: _frontSortKey()),
            workspaceId: _collection.workspaceId,
            collectionId: _collection.id,
            name: _defaultName(),
            template: template,
          )
        : existing.copyWith(
            meta: existing.meta.next(now),
            name: _defaultName(),
            template: template,
          );
    _activeId = request.id;
    _saved = [
      request,
      for (final r in _saved)
        if (r.id != request.id) r,
    ];
    notifyListeners();
    await _persist((tx) => tx.put(request));
  }

  void open(RequestItem request) {
    _activeId = request.id;
    _method = request.template.method;
    _url = request.template.url;
    _headers = request.template.headers.isEmpty
        ? [HeaderEntry.create()]
        : [...request.template.headers];
    _body = request.template.body;
    _outcome = null;
    _draftRevision++;
    notifyListeners();
  }

  void newRequest() {
    _activeId = null;
    _method = HttpMethod.get;
    _url = '';
    _headers = [HeaderEntry.create()];
    _body = '';
    _outcome = null;
    _draftRevision++;
    notifyListeners();
  }

  Future<void> delete(String id) async {
    _saved = [
      for (final r in _saved)
        if (r.id != id) r,
    ];
    if (_activeId == id) _activeId = null;
    notifyListeners();
    await _persist((tx) => tx.softDelete(id, _clock().toUtc()));
  }

  String _defaultName() {
    final url = _url.trim();
    return url.isEmpty ? 'Untitled request' : url;
  }

  // New requests sort first, matching the newest-first list.
  String _frontSortKey() {
    final keys = _saved.map((r) => r.meta.sortKey).toList()..sort();
    return sortKeyBetween(null, keys.firstOrNull);
  }

  Future<List<RequestItem>> _readSaved() async => [
    for (final entity in await _repository.children(_collection.id))
      if (entity is RequestItem) entity,
  ]..sort(_newestFirst);

  Future<void> _persist(Future<void> Function(WorkspaceWriter tx) write) async {
    if (!_canPersist) {
      notifyListeners();
      return;
    }
    try {
      await _repository.transaction(write);
      _storageMessage = null;
    } on StaleWriteException {
      _storageMessage =
          'This request was changed in another FetchRen window. The list now '
          'shows the latest saved version.';
      await _reloadAfterFailedWrite();
    } on Exception {
      _storageMessage = 'Requests could not be saved to disk.';
      await _reloadAfterFailedWrite();
    }
    notifyListeners();
  }

  // Shows what is actually stored rather than an unsaved change.
  Future<void> _reloadAfterFailedWrite() async {
    try {
      _saved = await _readSaved();
    } on Exception {
      // Keep the current list; the storage message already explains.
    }
  }
}

int _newestFirst(RequestItem a, RequestItem b) {
  final byUpdated = b.meta.updatedAt.compareTo(a.meta.updatedAt);
  return byUpdated != 0 ? byUpdated : a.id.compareTo(b.id);
}

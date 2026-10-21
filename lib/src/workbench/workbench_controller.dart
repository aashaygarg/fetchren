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

  /// Saved requests read from storage per page.
  static const int pageSize = 100;

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
  // The saved request being edited, as last read or written.
  RequestItem? _active;
  List<RequestSummary> _saved = const [];
  // Last summary read from storage; the next page starts after it.
  RequestSummary? _cursor;
  bool _hasMore = false;
  bool _isLoadingMore = false;
  // Lowest sort key in the collection; new requests go before it.
  String? _frontKey;
  // Requests saved while persistence is unavailable, so they can be reopened.
  final Map<String, RequestItem> _sessionOnly = {};
  Future<void> _pendingWrite = Future.value();
  int _navigation = 0;
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
  String? get activeId => _active?.id;

  /// Loaded saved requests, most recently updated first.
  List<RequestSummary> get savedRequests => List.unmodifiable(_saved);

  /// Whether more saved requests can be read with [loadMore].
  bool get hasMoreSaved => _hasMore;
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
      await _readFirstPage();
    } on Exception {
      _canPersist = false;
      _storageMessage =
          'Saved requests could not be loaded. Saving is disabled to avoid '
          'overwriting them.';
    }
    _isLoaded = true;
    notifyListeners();
  }

  /// Appends the next page of saved requests, if any.
  ///
  /// Safe to call during build: listeners are notified asynchronously.
  Future<void> loadMore() async {
    if (!_hasMore || _isLoadingMore) return;
    _isLoadingMore = true;
    try {
      final page = await _repository.requestSummaries(
        _collection.id,
        limit: pageSize,
        after: _cursor,
      );
      final loaded = {for (final s in _saved) s.id};
      _saved = [
        ..._saved,
        for (final s in page)
          if (!loaded.contains(s.id)) s,
      ];
      _cursor = page.lastOrNull ?? _cursor;
      _hasMore = page.length == pageSize;
    } on Exception {
      _hasMore = false;
      _storageMessage = 'Some saved requests could not be loaded.';
    } finally {
      _isLoadingMore = false;
    }
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
    final existing = _active;
    final request = existing == null
        ? RequestItem(
            meta: EntityMeta.create(now: now, sortKey: _nextFrontKey()),
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
    _active = request;
    _saved = [
      RequestSummary.of(request),
      for (final r in _saved)
        if (r.id != request.id) r,
    ];
    if (!_canPersist) _sessionOnly[request.id] = request;
    notifyListeners();
    await _persist((tx) => tx.put(request));
  }

  /// Reads the saved request [id] and replaces the draft with it.
  Future<void> open(String id) async {
    final navigation = ++_navigation;
    WorkspaceEntity? found;
    try {
      // A save may still be waiting for the write lock.
      await _pendingWrite;
      found = _sessionOnly[id] ?? await _repository.get(id);
    } on Exception {
      if (navigation != _navigation) return;
      _storageMessage = 'The saved request could not be opened.';
      notifyListeners();
      return;
    }
    // Another request was opened, or a new one started, while reading.
    if (navigation != _navigation) return;
    if (found is! RequestItem || found.meta.isDeleted) {
      _saved = [
        for (final r in _saved)
          if (r.id != id) r,
      ];
      _storageMessage = 'That request was deleted in another FetchRen window.';
      notifyListeners();
      return;
    }
    final request = found;
    _active = request;
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
    _navigation++;
    _active = null;
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
    if (_active?.id == id) _active = null;
    _sessionOnly.remove(id);
    notifyListeners();
    await _persist((tx) => tx.softDelete(id, _clock().toUtc()));
  }

  String _defaultName() {
    final url = _url.trim();
    return url.isEmpty ? 'Untitled request' : url;
  }

  // New requests sort first, matching the newest-first list.
  String _nextFrontKey() => _frontKey = sortKeyBetween(null, _frontKey);

  Future<void> _readFirstPage() async {
    final page = await _repository.requestSummaries(
      _collection.id,
      limit: pageSize,
    );
    final first = await _repository.children(_collection.id, limit: 1);
    _saved = page;
    _cursor = page.lastOrNull;
    _hasMore = page.length == pageSize;
    _frontKey = first.firstOrNull?.meta.sortKey;
  }

  Future<void> _persist(Future<void> Function(WorkspaceWriter tx) write) async {
    if (!_canPersist) {
      notifyListeners();
      return;
    }
    try {
      final pending = _repository.transaction(write);
      // Transactions are serialized, so this completes after earlier writes.
      _pendingWrite = pending.then<void>((_) {}, onError: (Object _) {});
      await pending;
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

  // Shows what is actually stored rather than an unsaved change, and edits
  // the stored version of the active request from now on.
  Future<void> _reloadAfterFailedWrite() async {
    try {
      await _readFirstPage();
      if (_active case final active?) {
        final stored = await _repository.get(active.id);
        _active = stored is RequestItem && !stored.meta.isDeleted
            ? stored
            : null;
      }
    } on Exception {
      // Keep the current list; the storage message already explains.
    }
  }
}

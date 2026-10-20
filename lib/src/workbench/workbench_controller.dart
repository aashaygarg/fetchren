import 'package:flutter/foundation.dart';

import '../http/request_executor.dart';
import '../http/request_outcome.dart';
import '../models/api_request.dart';
import '../models/http_method.dart';
import '../storage/request_store.dart';

/// Holds the editable request draft, saved requests, and the last outcome.
class WorkbenchController extends ChangeNotifier {
  WorkbenchController({
    required this._executor,
    required this._store,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final RequestExecutor _executor;
  final RequestStore _store;
  final DateTime Function() _clock;

  HttpMethod _method = HttpMethod.get;
  String _url = '';
  List<HeaderEntry> _headers = [HeaderEntry.create()];
  String _body = '';
  String? _activeId;
  List<ApiRequest> _saved = const [];
  bool _isLoaded = false;
  bool _isSending = false;
  RequestOutcome? _outcome;
  String? _storageMessage;
  bool _canPersist = true;
  int _draftRevision = 0;

  HttpMethod get method => _method;
  String get url => _url;
  List<HeaderEntry> get headers => List.unmodifiable(_headers);
  String get body => _body;

  /// ID of the saved request currently being edited, if any.
  String? get activeId => _activeId;
  List<ApiRequest> get savedRequests => List.unmodifiable(_saved);
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
      final result = await _store.loadAll();
      _saved = result.requests;
      if (result.recoveredCorruptFile != null) {
        _storageMessage =
            'Saved requests could not be read. The file was moved to '
            '${result.recoveredCorruptFile}.';
      }
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
    final now = _clock().toUtc();
    RequestOutcome outcome;
    try {
      outcome = await _executor.execute(
        ApiRequest(
          id: _activeId ?? 'draft',
          name: _defaultName(),
          method: _method,
          url: _url,
          headers: _headers,
          body: _body,
          createdAt: now,
          updatedAt: now,
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
    final existing = _saved.where((r) => r.id == _activeId).firstOrNull;
    final request = existing == null
        ? ApiRequest(
            id: generateId(),
            name: _defaultName(),
            method: _method,
            url: _url,
            headers: _headers,
            body: _body,
            createdAt: now,
            updatedAt: now,
          )
        : existing.copyWith(
            name: _defaultName(),
            method: _method,
            url: _url,
            headers: _headers,
            body: _body,
            updatedAt: now,
          );
    _activeId = request.id;
    _saved = [
      request,
      for (final r in _saved)
        if (r.id != request.id) r,
    ];
    notifyListeners();
    await _persist();
  }

  void open(ApiRequest request) {
    _activeId = request.id;
    _method = request.method;
    _url = request.url;
    _headers = request.headers.isEmpty
        ? [HeaderEntry.create()]
        : [...request.headers];
    _body = request.body;
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
    await _persist();
  }

  String _defaultName() {
    final url = _url.trim();
    return url.isEmpty ? 'Untitled request' : url;
  }

  Future<void> _persist() async {
    if (!_canPersist) {
      notifyListeners();
      return;
    }
    try {
      await _store.saveAll(_saved);
      _storageMessage = null;
    } on Exception {
      _storageMessage = 'Requests could not be saved to disk.';
    }
    notifyListeners();
  }
}

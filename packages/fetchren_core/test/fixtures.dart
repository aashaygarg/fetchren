import 'package:fetchren_core/fetchren_core.dart';
import 'package:fetchren_core_testing/fetchren_core_testing.dart';

export 'package:fetchren_core_testing/fetchren_core_testing.dart'
    show TreeBuilder, t0;

ApiRequest legacyRequest({
  String id = 'req-1',
  String name = 'https://api.example.test/items',
  HttpMethod method = HttpMethod.get,
  String url = 'https://api.example.test/items',
  List<HeaderEntry> headers = const [],
  String body = '',
  DateTime? createdAt,
  DateTime? updatedAt,
}) => ApiRequest(
  id: id,
  name: name,
  method: method,
  url: url,
  headers: headers,
  body: body,
  createdAt: createdAt ?? t0,
  updatedAt: updatedAt ?? t0,
);

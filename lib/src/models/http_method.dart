/// HTTP methods supported by the workbench.
enum HttpMethod {
  get('GET'),
  post('POST'),
  put('PUT'),
  patch('PATCH'),
  delete('DELETE'),
  head('HEAD'),
  options('OPTIONS');

  const HttpMethod(this.wireName);

  /// The method token sent on the wire, e.g. `GET`.
  final String wireName;

  /// Whether the workbench offers a request body editor for this method.
  bool get allowsBody => switch (this) {
    HttpMethod.post ||
    HttpMethod.put ||
    HttpMethod.patch ||
    HttpMethod.delete => true,
    HttpMethod.get || HttpMethod.head || HttpMethod.options => false,
  };

  static HttpMethod fromWireName(String name) {
    final upper = name.toUpperCase();
    for (final method in values) {
      if (method.wireName == upper) return method;
    }
    throw FormatException('Unsupported HTTP method: $name');
  }
}

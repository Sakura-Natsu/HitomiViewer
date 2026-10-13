enum HitomiErrorCode {
  invalidArgument,
  invalidCombination,
  invalidField,
  unexpectedResponseStatus,
  unexpectedResponseBody,
}

class HitomiException implements Exception {
  HitomiException(this.code, this.message, {this.statusCode});

  factory HitomiException.unexpectedStatus(Uri uri, int statusCode) =>
      HitomiException(
        HitomiErrorCode.unexpectedResponseStatus,
        '$uri responded with $statusCode',
        statusCode: statusCode,
      );

  factory HitomiException.unparsableImageContext() => HitomiException(
    HitomiErrorCode.unexpectedResponseBody,
    'Image context (gg.js) is not parsable',
  );

  factory HitomiException.emptyRootNode() => HitomiException(
    HitomiErrorCode.unexpectedResponseBody,
    'Root node of index must not be empty',
  );

  final HitomiErrorCode code;
  final String message;

  /// 仅在 [HitomiErrorCode.unexpectedResponseStatus] 时有值。
  final int? statusCode;

  @override
  String toString() => 'HitomiException(${code.name}): $message';
}

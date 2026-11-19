/// Typed exception hierarchy mirroring the tRPC v11 error-code table.
library;

/// Base exception class for all RPC client and wire errors.
class RpcException implements Exception {
  /// Creates an RPC exception with an error [message] and optional details.
  RpcException(
    this.message, {
    this.code = 'UNKNOWN',
    this.httpStatus,
    this.path,
    this.data,
    this.cause,
    this.defined = false,
  });

  /// Human-readable error description.
  final String message;

  /// Error code matching the tRPC error table or internal code.
  final String code;

  /// Underlying HTTP status code, if applicable.
  final int? httpStatus;

  /// For wire errors: the procedure path. For decode errors: the field
  /// breadcrumb (e.g. `UserGetByIdOutput.items[0].title`).
  final String? path;

  /// Optional server error payload data map.
  final Map<String, Object?>? data;

  /// Underlying cause if wrapped.
  final Object? cause;

  /// Whether the error was declared via oRPC `.errors({...})` (wire `defined`).
  final bool defined;

  /// Single decode point for oRPC `ORPCError` wire payloads
  /// (`{defined, code, status, message, data}`). Non-map `data` is preserved
  /// under `{'value': data}`.
  factory RpcException.fromOrpcWire(Map<String, Object?> json) {
    final message = switch (json['message']) {
      final String m => m,
      _ => 'unknown error',
    };
    final code = switch (json['code']) {
      final String c => c,
      _ => 'UNKNOWN',
    };
    final httpStatus = switch (json['status']) {
      final int h => h,
      _ => null,
    };
    final defined = json['defined'] == true;
    final data = switch (json['data']) {
      final Map<String, Object?> d => d,
      null => null,
      final other => <String, Object?>{'value': other},
    };
    return switch (code) {
      'BAD_REQUEST' => RpcBadRequestException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'UNAUTHORIZED' => RpcUnauthorizedException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'FORBIDDEN' => RpcForbiddenException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'NOT_FOUND' => RpcNotFoundException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'METHOD_NOT_SUPPORTED' => RpcMethodNotSupportedException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'TIMEOUT' => RpcTimeoutException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'CONFLICT' => RpcConflictException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'PRECONDITION_FAILED' => RpcPreconditionFailedException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'PAYLOAD_TOO_LARGE' => RpcPayloadTooLargeException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'UNSUPPORTED_MEDIA_TYPE' => RpcUnsupportedMediaTypeException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'UNPROCESSABLE_CONTENT' => RpcUnprocessableContentException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'TOO_MANY_REQUESTS' => RpcTooManyRequestsException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'CLIENT_CLOSED_REQUEST' => RpcClientClosedRequestException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'NOT_IMPLEMENTED' => RpcNotImplementedException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'INTERNAL_SERVER_ERROR' => RpcInternalServerException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'BAD_GATEWAY' => RpcBadGatewayException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'SERVICE_UNAVAILABLE' => RpcServiceUnavailableException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      'GATEWAY_TIMEOUT' => RpcGatewayTimeoutException(message,
          httpStatus: httpStatus, data: data, defined: defined),
      _ => RpcException(message,
          code: code, httpStatus: httpStatus, data: data, defined: defined),
    };
  }

  /// Single decode point for wire error envelopes
  /// (`{message, code, data:{code, httpStatus, path, stack?, zodError?}}`).
  factory RpcException.fromWire(Map<String, Object?> json) {
    final message = switch (json['message']) {
      final String m => m,
      _ => 'unknown error',
    };
    final numeric = json['code'];
    final data = switch (json['data']) {
      final Map<String, Object?> d => d,
      _ => null,
    };
    final code = switch (data?['code']) {
      final String c => c,
      _ => numeric is int ? 'RPC_$numeric' : 'UNKNOWN',
    };
    final httpStatus = switch (data?['httpStatus']) {
      final int h => h,
      _ => null,
    };
    final path = switch (data?['path']) {
      final String p => p,
      _ => null,
    };
    return switch (code) {
      'BAD_REQUEST' => RpcBadRequestException(
          message,
          httpStatus: httpStatus,
          path: path,
          data: data,
          fieldErrors: zodFieldErrors(data?['zodError']),
        ),
      'UNAUTHORIZED' => RpcUnauthorizedException(message,
          httpStatus: httpStatus, path: path, data: data),
      'FORBIDDEN' => RpcForbiddenException(message,
          httpStatus: httpStatus, path: path, data: data),
      'NOT_FOUND' => RpcNotFoundException(message,
          httpStatus: httpStatus, path: path, data: data),
      'METHOD_NOT_SUPPORTED' => RpcMethodNotSupportedException(message,
          httpStatus: httpStatus, path: path, data: data),
      'TIMEOUT' => RpcTimeoutException(message,
          httpStatus: httpStatus, path: path, data: data),
      'CONFLICT' => RpcConflictException(message,
          httpStatus: httpStatus, path: path, data: data),
      'PRECONDITION_FAILED' => RpcPreconditionFailedException(message,
          httpStatus: httpStatus, path: path, data: data),
      'PAYLOAD_TOO_LARGE' => RpcPayloadTooLargeException(message,
          httpStatus: httpStatus, path: path, data: data),
      'UNSUPPORTED_MEDIA_TYPE' => RpcUnsupportedMediaTypeException(message,
          httpStatus: httpStatus, path: path, data: data),
      'UNPROCESSABLE_CONTENT' => RpcUnprocessableContentException(message,
          httpStatus: httpStatus, path: path, data: data),
      'TOO_MANY_REQUESTS' => RpcTooManyRequestsException(message,
          httpStatus: httpStatus, path: path, data: data),
      'CLIENT_CLOSED_REQUEST' => RpcClientClosedRequestException(message,
          httpStatus: httpStatus, path: path, data: data),
      'PAYMENT_REQUIRED' => RpcPaymentRequiredException(message,
          httpStatus: httpStatus, path: path, data: data),
      'NOT_IMPLEMENTED' => RpcNotImplementedException(message,
          httpStatus: httpStatus, path: path, data: data),
      'INTERNAL_SERVER_ERROR' => RpcInternalServerException(message,
          httpStatus: httpStatus, path: path, data: data),
      'BAD_GATEWAY' => RpcBadGatewayException(message,
          httpStatus: httpStatus, path: path, data: data),
      'SERVICE_UNAVAILABLE' => RpcServiceUnavailableException(message,
          httpStatus: httpStatus, path: path, data: data),
      'GATEWAY_TIMEOUT' => RpcGatewayTimeoutException(message,
          httpStatus: httpStatus, path: path, data: data),
      'PARSE_ERROR' => RpcDecodeException(message,
          httpStatus: httpStatus, path: path, data: data),
      _ => RpcException(message,
          code: code, httpStatus: httpStatus, path: path, data: data),
    };
  }

  /// Field-level validation errors extracted from Zod error trees.
  Map<String, List<String>> get fieldErrors => const {};

  @override
  String toString() => 'RpcException($code): $message';
}

/// Parses field-level errors from a serialized Zod error map.
Map<String, List<String>> zodFieldErrors(Object? zodError) {
  if (zodError case final Map<String, Object?> z) {
    if (z['fieldErrors'] case final Map<String, Object?> fieldErrors) {
      final out = <String, List<String>>{};
      for (final entry in fieldErrors.entries) {
        if (entry.value case final List<Object?> messages) {
          out[entry.key] = [for (final message in messages) message.toString()];
        }
      }
      return out;
    }
  }
  return const {};
}

/// Thrown when the server responds with BAD_REQUEST (HTTP 400).
class RpcBadRequestException extends RpcException {
  /// Creates a bad request exception with optional [fieldErrors].
  RpcBadRequestException(
    super.message, {
    super.httpStatus,
    super.path,
    super.data,
    super.defined,
    this.fieldErrors = const {},
  }) : super(code: 'BAD_REQUEST');

  @override
  final Map<String, List<String>> fieldErrors;
}

/// Thrown when the server responds with UNAUTHORIZED (HTTP 401).
class RpcUnauthorizedException extends RpcException {
  /// Creates an unauthorized exception.
  RpcUnauthorizedException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'UNAUTHORIZED');
}

/// Thrown when the server responds with FORBIDDEN (HTTP 403).
class RpcForbiddenException extends RpcException {
  /// Creates a forbidden exception.
  RpcForbiddenException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'FORBIDDEN');
}

/// Thrown when the server responds with NOT_FOUND (HTTP 404).
class RpcNotFoundException extends RpcException {
  /// Creates a not found exception.
  RpcNotFoundException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'NOT_FOUND');
}

/// Thrown when the server responds with METHOD_NOT_SUPPORTED (HTTP 405).
class RpcMethodNotSupportedException extends RpcException {
  /// Creates a method not supported exception.
  RpcMethodNotSupportedException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'METHOD_NOT_SUPPORTED');
}

/// Thrown when the server responds with TIMEOUT or a client call deadline expires.
class RpcTimeoutException extends RpcException {
  /// Creates a timeout exception.
  RpcTimeoutException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'TIMEOUT');
}

/// Thrown when the server responds with CONFLICT (HTTP 409).
class RpcConflictException extends RpcException {
  /// Creates a conflict exception.
  RpcConflictException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'CONFLICT');
}

/// Thrown when the server responds with PRECONDITION_FAILED (HTTP 412).
class RpcPreconditionFailedException extends RpcException {
  /// Creates a precondition failed exception.
  RpcPreconditionFailedException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'PRECONDITION_FAILED');
}

/// Thrown when the server responds with PRECONDITION_REQUIRED (HTTP 428).
class RpcPreconditionRequiredException extends RpcException {
  /// Creates a precondition required exception.
  RpcPreconditionRequiredException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'PRECONDITION_REQUIRED');
}

/// Thrown when the server responds with PAYLOAD_TOO_LARGE (HTTP 413).
class RpcPayloadTooLargeException extends RpcException {
  /// Creates a payload too large exception.
  RpcPayloadTooLargeException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'PAYLOAD_TOO_LARGE');
}

/// Thrown when the server responds with UNSUPPORTED_MEDIA_TYPE (HTTP 415).
class RpcUnsupportedMediaTypeException extends RpcException {
  /// Creates an unsupported media type exception.
  RpcUnsupportedMediaTypeException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'UNSUPPORTED_MEDIA_TYPE');
}

/// Thrown when the server responds with UNPROCESSABLE_CONTENT (HTTP 422).
class RpcUnprocessableContentException extends RpcException {
  /// Creates an unprocessable content exception.
  RpcUnprocessableContentException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'UNPROCESSABLE_CONTENT');
}

/// Thrown when the server responds with TOO_MANY_REQUESTS (HTTP 429).
class RpcTooManyRequestsException extends RpcException {
  /// Creates a too many requests exception.
  RpcTooManyRequestsException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'TOO_MANY_REQUESTS');
}

/// Thrown when the server responds with CLIENT_CLOSED_REQUEST (HTTP 499).
class RpcClientClosedRequestException extends RpcException {
  /// Creates a client closed request exception.
  RpcClientClosedRequestException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'CLIENT_CLOSED_REQUEST');
}

/// Thrown when the server responds with PAYMENT_REQUIRED (HTTP 402).
class RpcPaymentRequiredException extends RpcException {
  /// Creates a payment required exception.
  RpcPaymentRequiredException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'PAYMENT_REQUIRED');
}

/// Thrown when the server responds with NOT_IMPLEMENTED (HTTP 501).
class RpcNotImplementedException extends RpcException {
  /// Creates a not implemented exception.
  RpcNotImplementedException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'NOT_IMPLEMENTED');
}

/// Thrown when the server responds with INTERNAL_SERVER_ERROR (HTTP 500).
class RpcInternalServerException extends RpcException {
  /// Creates an internal server error exception.
  RpcInternalServerException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'INTERNAL_SERVER_ERROR');
}

/// Thrown when the server responds with BAD_GATEWAY (HTTP 502).
class RpcBadGatewayException extends RpcException {
  /// Creates a bad gateway exception.
  RpcBadGatewayException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'BAD_GATEWAY');
}

/// Thrown when the server responds with SERVICE_UNAVAILABLE (HTTP 503).
class RpcServiceUnavailableException extends RpcException {
  /// Creates a service unavailable exception.
  RpcServiceUnavailableException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'SERVICE_UNAVAILABLE');
}

/// Thrown when the server responds with GATEWAY_TIMEOUT (HTTP 504).
class RpcGatewayTimeoutException extends RpcException {
  /// Creates a gateway timeout exception.
  RpcGatewayTimeoutException(super.message,
      {super.httpStatus, super.path, super.data, super.defined})
      : super(code: 'GATEWAY_TIMEOUT');
}

/// Transport-level failures (network unreachable, connection dropped).
class RpcNetworkException extends RpcException {
  /// Creates a network exception wrapping an optional [cause].
  RpcNetworkException(super.message, {super.cause}) : super(code: 'NETWORK');
}

/// Envelope / annotation / shape failures. Data is never silently mangled:
/// every decode failure carries the field breadcrumb [path], what [expected]
/// type was required, and what [actual] value was received.
class RpcDecodeException extends RpcException {
  /// Creates a structured decode exception with expected and actual type breadcrumbs.
  RpcDecodeException(
    super.message, {
    super.cause,
    super.httpStatus,
    super.path,
    super.data,
    this.expected,
    this.actual,
  }) : super(code: 'DECODE');

  /// The expected type or schema shape.
  final String? expected;

  /// The actual type received at runtime.
  final String? actual;

  @override
  String toString() {
    final location = path == null ? '' : ' at $path';
    final shape = expected == null ? '' : ' (expected $expected, got $actual)';
    return 'RpcDecodeException($code)$location$shape: $message';
  }
}

/// Thrown when an operation is cancelled via [CancelToken].
class RpcCancelledException extends RpcException {
  /// Creates a cancellation exception with description [message].
  RpcCancelledException(super.message) : super(code: 'CANCELLED');
}

/// Thrown when an unknown enum sentinel value is serialized for a request.
class RpcEnumUnknownException extends RpcException {
  /// Creates an unknown enum exception for [enumName].
  RpcEnumUnknownException(this.enumName)
      : super('unknown $enumName value cannot be sent');

  /// The enum type name.
  final String enumName;
}

/// Surrogate for remote errors that carry a stack trace in development.
class RpcRemoteException extends RpcException {
  /// Creates a remote exception with optional stack [data].
  RpcRemoteException(super.message, {super.data}) : super(code: 'REMOTE_ERROR');
}

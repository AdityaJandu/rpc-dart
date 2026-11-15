/// Typed exception hierarchy mirroring the tRPC v11 error-code table
///.
library;

class RpcException implements Exception {
  RpcException(
    this.message, {
    this.code = 'UNKNOWN',
    this.httpStatus,
    this.path,
    this.data,
    this.cause,
  });

  final String message;
  final String code;
  final int? httpStatus;

  /// For wire errors: the procedure path. For decode errors: the field
  /// breadcrumb (e.g. `UserGetByIdOutput.items[0].title`).
  final String? path;
  final Map<String, Object?>? data;
  final Object? cause;

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

  Map<String, List<String>> get fieldErrors => const {};

  @override
  String toString() => 'RpcException($code): $message';
}

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

class RpcBadRequestException extends RpcException {
  RpcBadRequestException(
    super.message, {
    super.httpStatus,
    super.path,
    super.data,
    this.fieldErrors = const {},
  }) : super(code: 'BAD_REQUEST');

  @override
  final Map<String, List<String>> fieldErrors;
}

class RpcUnauthorizedException extends RpcException {
  RpcUnauthorizedException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'UNAUTHORIZED');
}

class RpcForbiddenException extends RpcException {
  RpcForbiddenException(super.message, {super.httpStatus, super.path, super.data})
      : super(code: 'FORBIDDEN');
}

class RpcNotFoundException extends RpcException {
  RpcNotFoundException(super.message, {super.httpStatus, super.path, super.data})
      : super(code: 'NOT_FOUND');
}

class RpcMethodNotSupportedException extends RpcException {
  RpcMethodNotSupportedException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'METHOD_NOT_SUPPORTED');
}

class RpcTimeoutException extends RpcException {
  RpcTimeoutException(super.message, {super.httpStatus, super.path, super.data})
      : super(code: 'TIMEOUT');
}

class RpcConflictException extends RpcException {
  RpcConflictException(super.message, {super.httpStatus, super.path, super.data})
      : super(code: 'CONFLICT');
}

class RpcPreconditionFailedException extends RpcException {
  RpcPreconditionFailedException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'PRECONDITION_FAILED');
}

class RpcPreconditionRequiredException extends RpcException {
  RpcPreconditionRequiredException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'PRECONDITION_REQUIRED');
}

class RpcPayloadTooLargeException extends RpcException {
  RpcPayloadTooLargeException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'PAYLOAD_TOO_LARGE');
}

class RpcUnsupportedMediaTypeException extends RpcException {
  RpcUnsupportedMediaTypeException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'UNSUPPORTED_MEDIA_TYPE');
}

class RpcUnprocessableContentException extends RpcException {
  RpcUnprocessableContentException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'UNPROCESSABLE_CONTENT');
}

class RpcTooManyRequestsException extends RpcException {
  RpcTooManyRequestsException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'TOO_MANY_REQUESTS');
}

class RpcClientClosedRequestException extends RpcException {
  RpcClientClosedRequestException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'CLIENT_CLOSED_REQUEST');
}

class RpcPaymentRequiredException extends RpcException {
  RpcPaymentRequiredException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'PAYMENT_REQUIRED');
}

class RpcNotImplementedException extends RpcException {
  RpcNotImplementedException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'NOT_IMPLEMENTED');
}

class RpcInternalServerException extends RpcException {
  RpcInternalServerException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'INTERNAL_SERVER_ERROR');
}

class RpcBadGatewayException extends RpcException {
  RpcBadGatewayException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'BAD_GATEWAY');
}

class RpcServiceUnavailableException extends RpcException {
  RpcServiceUnavailableException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'SERVICE_UNAVAILABLE');
}

class RpcGatewayTimeoutException extends RpcException {
  RpcGatewayTimeoutException(super.message,
      {super.httpStatus, super.path, super.data})
      : super(code: 'GATEWAY_TIMEOUT');
}

/// Transport-level failures (never a wire code).
class RpcNetworkException extends RpcException {
  RpcNetworkException(super.message, {super.cause})
      : super(code: 'NETWORK');
}

/// Envelope / annotation / shape failures. Data is never silently mangled:
/// every decode failure carries the field breadcrumb [path], what [expected]
/// type was required, and what [actual] value was received.
class RpcDecodeException extends RpcException {
  RpcDecodeException(
    super.message, {
    super.cause,
    super.httpStatus,
    super.path,
    super.data,
    this.expected,
    this.actual,
  }) : super(code: 'DECODE');

  final String? expected;
  final String? actual;

  @override
  String toString() {
    final location = path == null ? '' : ' at $path';
    final shape = expected == null ? '' : ' (expected $expected, got $actual)';
    return 'RpcDecodeException($code)$location$shape: $message';
  }
}

class RpcCancelledException extends RpcException {
  RpcCancelledException(super.message) : super(code: 'CANCELLED');
}

class RpcEnumUnknownException extends RpcException {
  RpcEnumUnknownException(this.enumName) : super('unknown $enumName value cannot be sent');

  final String enumName;
}

/// Surrogate for remote errors that carry a stack (dev servers).
class RpcRemoteException extends RpcException {
  RpcRemoteException(super.message, {super.data}) : super(code: 'REMOTE_ERROR');
}

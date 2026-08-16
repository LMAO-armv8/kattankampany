import '../errors/app_exception.dart';

/// A lightweight success/failure union used by services that must not throw
/// across a boundary (queue engine steps, diagnostics checks, tray actions).
///
/// The repository layer throws [AppException]; the orchestration layer converts
/// to [Result] where it needs to branch on the failure rather than unwind.
sealed class Result<T> {
  const Result();

  const factory Result.success(T value) = Success<T>;
  const factory Result.failure(AppException error) = FailureResult<T>;

  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is FailureResult<T>;

  T? get valueOrNull => switch (this) {
        Success<T>(:final value) => value,
        FailureResult<T>() => null,
      };

  AppException? get errorOrNull => switch (this) {
        Success<T>() => null,
        FailureResult<T>(:final error) => error,
      };

  R fold<R>(
    R Function(T value) onSuccess,
    R Function(AppException error) onFailure,
  ) =>
      switch (this) {
        Success<T>(:final value) => onSuccess(value),
        FailureResult<T>(:final error) => onFailure(error),
      };

  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        Success<T>(:final value) => Result<R>.success(transform(value)),
        FailureResult<T>(:final error) => Result<R>.failure(error),
      };
}

final class Success<T> extends Result<T> {
  const Success(this.value);
  final T value;
}

final class FailureResult<T> extends Result<T> {
  const FailureResult(this.error);
  final AppException error;
}

/// Runs [action] and converts any thrown object into a [Result.failure].
Future<Result<T>> guard<T>(Future<T> Function() action) async {
  try {
    return Result<T>.success(await action());
  } catch (e, st) {
    return Result<T>.failure(asAppException(e, st));
  }
}

/// Coalesces concurrent cleanup callers and permits retry after failure.
///
/// Successful cleanup remains memoized because the owned resource is already
/// retired. A failed attempt is shared with current waiters, then forgotten so
/// a later recovery action can retry the cleanup.
final class RetryableSingleFlightOperation {
  Future<void>? _attempt;

  Future<void> run(Future<void> Function() operation) {
    final current = _attempt;
    if (current != null) return current;

    late final Future<void> attempt;
    attempt = Future<void>.sync(operation).then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_attempt, attempt)) _attempt = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _attempt = attempt;
    return attempt;
  }
}

import '../../../features/printers/domain/print_profile.dart';
import '../../../features/printing/domain/print_document.dart';
import '../../../features/printing/domain/print_request.dart';

/// How bytes actually reach a device.
///
/// Adding support for a vendor protocol later means implementing this interface
/// and registering it — no existing code changes. That is the whole point of the
/// abstraction, and it is why nothing above this layer knows what ESC/POS is.
abstract class PrintStrategy {
  /// Stable identifier used in logs and diagnostics.
  String get name;

  /// Which explicit [PrintStrategyType] selects this strategy.
  PrintStrategyType get type;

  /// Document types this strategy can handle when `strategy: auto` is in effect.
  ///
  /// A strategy that returns an empty set is never chosen automatically — it
  /// must be requested by name. `escpos` does exactly that, because most
  /// printers are not ESC/POS devices and guessing wrong prints garbage.
  Set<DocumentType> get autoSelectableFor;

  Future<PrintResult> print(PrintRequest request);
}

/// Chooses a strategy for a request.
///
/// Resolution order:
///   1. `profile.strategy` when it is not `auto` — an explicit instruction from
///      the server or from a local print profile always wins.
///   2. The registered strategy that lists the document type in
///      [PrintStrategy.autoSelectableFor].
///   3. No strategy → the job fails with `unsupported_document` rather than
///      being sent somewhere it might print as garbage.
class PrintStrategyRegistry {
  PrintStrategyRegistry(List<PrintStrategy> strategies)
      : _byType = <PrintStrategyType, PrintStrategy>{
          for (final strategy in strategies) strategy.type: strategy,
        },
        _all = List<PrintStrategy>.unmodifiable(strategies);

  final Map<PrintStrategyType, PrintStrategy> _byType;
  final List<PrintStrategy> _all;

  List<PrintStrategy> get all => _all;

  PrintStrategy? resolve({
    required DocumentType documentType,
    required PrintStrategyType requested,
  }) {
    if (requested != PrintStrategyType.auto) {
      final explicit = _byType[requested];
      if (explicit != null) return explicit;
      // An unknown explicit strategy falls through to automatic selection
      // rather than failing outright — a newer server asking for a strategy
      // this build does not have should still print if it safely can.
    }
    for (final strategy in _all) {
      if (strategy.autoSelectableFor.contains(documentType)) return strategy;
    }
    return null;
  }

  PrintStrategy? byType(PrintStrategyType type) => _byType[type];
}

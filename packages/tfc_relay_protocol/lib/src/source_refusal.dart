/// A refusal raised by a data source that knows whether retrying it could ever
/// work.
///
/// ## The bug this closes
///
/// `RelaySession`'s catch-all maps anything a handler throws to `handlerFailed`
/// (-32011), and the wire documents that code as *possibly transient: retrying
/// is legitimate*. That is exactly right for "the historian is not connected"
/// and exactly wrong for "there is no series by that name": the second cannot
/// become true by asking again, so a panel that reads -32011 as an invitation
/// to back off and retry will do it forever, on a request the gateway is
/// certain about.
///
/// 10-07, 10-08 and 10-09 each recorded this as a named follow-up with no
/// owner. None of the three could close it from where it stood, and the reason
/// is structural rather than a matter of effort: the refusals are declared in
/// `tfc_relay_local` (`TimeseriesReadRefusal` and its subclasses,
/// `PreferenceStoreUnavailable`), the mapping has to happen in
/// `tfc_relay_server`'s `data_handlers.dart`, and **the dependency edge runs
/// local → server and never the other way** (`tfc_relay_local/pubspec.yaml:7`).
/// A handler cannot name a type it cannot import, so "map the sealed family
/// with a switch" is not available at the place the wire code is chosen.
///
/// This interface lives in the package both ends already depend on. It carries
/// one bit and one sentence, which is all the handler needs, and it leaves the
/// *code* decision where every other code decision in this project is: at the
/// handler, not inside the exception (`result_too_large.dart`'s argument, which
/// this follows deliberately).
///
/// ## Where the bit is decided, and why that is still compiler-checked
///
/// Implementers decide [retryable]. `TimeseriesReadRefusal` decides it with an
/// **exhaustive switch over its own sealed family**, so a subclass added later
/// is a compile error there rather than a silent default — which is the
/// property that matters, because the dangerous direction is a new *retryable*
/// refusal inheriting a "permanent" default and telling a panel its query was
/// malformed every time the database bounced.
///
/// ## What it is not
///
/// It is not a wire type: nothing serialises it, no method table names it, and
/// it adds no vocabulary to the protocol. It is the one fact a handler needs
/// about an exception it is not allowed to know the type of.
library;

/// One bit — could a retry ever succeed — and the sentence to say either way.
abstract interface class SourceRefusal implements Exception {
  /// Whether retrying the identical request could ever succeed.
  ///
  /// False for every refusal about the *request* (an unknown series, an
  /// unaddressed struct, a column a chart cannot plot, an ordering outside the
  /// allow-list). True only for the source being temporarily unreachable.
  bool get retryable;

  /// The sentence the refusal travels as.
  ///
  /// Carried across the mapping unchanged. The reason a permanent refusal is
  /// worth a distinct code at all is that it tells the caller what to change,
  /// and a mapping that replaced this with "invalid params" would take that
  /// back on the way out.
  String get message;
}

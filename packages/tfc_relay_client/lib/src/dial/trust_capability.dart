/// Whether this platform lets the panel choose what it trusts.
///
/// One boolean, in a file with no dependencies of its own, because two very
/// different places need it and neither should have to reach the dial to ask:
/// `ClientConfig.checkDialable` refuses configurations that cannot be honoured
/// here, and `PinnedDialer` implements them. A constant rather than a runtime
/// check so the branch is resolved at compile time and the unreachable arm's
/// code is not emitted.
library;

export 'trust_capability_io.dart'
    if (dart.library.js_interop) 'trust_capability_web.dart';

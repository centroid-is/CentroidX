/// A station chooses its own trust: `SecurityContext(withTrustedRoots: false)`
/// over the root the integrator provisioned, and the machine's own store never
/// consulted.
const bool kCanPinTrustRoot = true;

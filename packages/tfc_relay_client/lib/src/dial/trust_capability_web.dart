/// A browser does not. There is no API to add a trust root, to pin one, or to
/// inspect the peer certificate: the page gets the machine's trust store and
/// nothing else. Every consequence of that — `wss` only, no configured root,
/// and a handshake failure that cannot be told from an absent gateway — hangs
/// off this constant.
const bool kCanPinTrustRoot = false;

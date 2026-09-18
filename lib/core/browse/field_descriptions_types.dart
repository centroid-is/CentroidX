/// The shape a browsed field description comes back in.
///
/// Its own file so both arms of the seam and the caller can name it without
/// any of them reaching the other arm.
library;

typedef FieldDescription = ({String? displayName, String? description});

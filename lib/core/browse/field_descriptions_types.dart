/// The one shape both arms of the [fetchFieldDescriptions] seam return.
///
/// Its own file so the record type is declared once; a mismatch between the
/// two arms would otherwise only show up when somebody built for the platform
/// that is not their own.
library;

typedef FieldDescription = ({String? displayName, String? description});

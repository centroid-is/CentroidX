/// Turning an arbitrary value into a bounded string a human can read in a row.
///
/// Two diffs need this and they must agree: `access/dynamic_value_diff.dart`
/// renders struct members into audit rows, and `config/config_field_diff.dart`
/// renders config fields into history rows. The rendering rules — what a null
/// looks like, where the cap falls, that the cap bounds the *intermediate*
/// buffer too — are the same question in both, and two copies of an answer
/// this fiddly drift.
///
/// ## Why it lives here rather than in dynamic_value_diff.dart
///
/// That file imports `package:open62541`, which links a native library.
/// `ConfigStore` and the config diffs are reached by the backend, the
/// collector and `tfc_mcp_server`, none of which has a Flutter engine and none
/// of which should acquire an FFI link by asking what 256 characters of a
/// value look like. That is D-3 in `docs/relational-config-deferred-defects.md`
/// happening a second time, so the shared part is lifted out to a file with no
/// imports at all rather than shared by importing the bigger one.
/// `dynamic_value_diff.dart` re-exports the two constants, so its own callers
/// and tests are unaffected by the move.
///
/// The walker here is over plain `Object?` — decoded JSON, or whatever a
/// `DynamicValue` was holding. Unwrapping a wrapper type is the caller's job,
/// via [writeRenderedValue]'s `unwrap` hook, which is what keeps the
/// open62541 type on the far side of this boundary.
library;

/// The cap on a rendered value, in characters.
///
/// These strings land in a database column and in log lines, and the value
/// being rendered is whatever a struct member or a config field happened to
/// hold — a pasted blob is as legitimate an input as a boolean. Spec §10
/// records that `pg_notify` has an 8000-byte cap which preference writes
/// already fire, so unbounded audit strings are not a hypothetical cost on
/// this deployment. 256 characters is past the length of any real member on
/// this plant.
const int kMaxRenderedValueLength = 256;

/// Appended to a rendering the cap cut short, so a reader can tell a truncated
/// row from a short one.
const String kRenderTruncationMarker = '...[truncated]';

/// [value] as a row string, capped at [kMaxRenderedValueLength].
///
/// A null renders as the string `'null'` and never as `''`. Callers that need
/// to distinguish "held null" from "no value at all" express the second by not
/// calling this — see `FieldChange.oldValue` and `MemberChange.oldValue`, both
/// of which use Dart null for absence precisely so that this function is free
/// to render a real null honestly.
///
/// [unwrap] is applied to every map value and list element before it is
/// written, for callers whose structures hold wrapper objects rather than
/// plain decoded JSON.
String renderJsonValue(
  Object? value, {
  Object? Function(Object?)? unwrap,
}) {
  final out = StringBuffer();
  writeRenderedValue(out, value, unwrap: unwrap);
  final rendered = out.toString();
  return rendered.length <= kMaxRenderedValueLength
      ? rendered
      : rendered.substring(0, kMaxRenderedValueLength) +
          kRenderTruncationMarker;
}

/// Writes [value] into [out], stopping once [out] is already past the cap.
///
/// The early return bounds the intermediate string as well as the returned
/// one: rendering a large structure does not build a megabyte before
/// truncating it, and a nested recursion terminates because each nested call
/// returns at this first line once the buffer is full.
///
/// The container loops break on the same condition, and the closing bracket is
/// written only while the buffer is still under the cap. Without both, a wide
/// flat container still costs two characters of separator per element — a
/// 100k-element list built 200 kB of commas before anything was thrown away —
/// and a deep one still costs one closing brace per level as the recursion
/// unwinds. Neither changes what [renderJsonValue] returns: everything skipped
/// this way sits past character [kMaxRenderedValueLength], which the cap
/// removes anyway.
void writeRenderedValue(
  StringBuffer out,
  Object? value, {
  Object? Function(Object?)? unwrap,
}) {
  if (out.length > kMaxRenderedValueLength) return;
  if (value == null) {
    out.write('null');
    return;
  }
  if (value is Map) {
    out.write('{');
    var first = true;
    for (final entry in value.entries) {
      if (out.length > kMaxRenderedValueLength) break;
      if (!first) out.write(', ');
      first = false;
      out.write('${entry.key}: ');
      writeRenderedValue(
        out,
        unwrap == null ? entry.value : unwrap(entry.value),
        unwrap: unwrap,
      );
    }
    if (out.length <= kMaxRenderedValueLength) out.write('}');
    return;
  }
  if (value is List) {
    out.write('[');
    var first = true;
    for (final element in value) {
      if (out.length > kMaxRenderedValueLength) break;
      if (!first) out.write(', ');
      first = false;
      writeRenderedValue(
        out,
        unwrap == null ? element : unwrap(element),
        unwrap: unwrap,
      );
    }
    if (out.length <= kMaxRenderedValueLength) out.write(']');
    return;
  }
  out.write(value.toString());
}

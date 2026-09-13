/// How long a signed-in account may sit idle before its session ends.
///
/// **Per account, not per station.** The value lives on `app_user` and travels
/// with the person: an engineer gets the window their account was given on
/// whichever panel they sign in at, and an operator's short window is not
/// widened because the panel they used was configured for somebody else. A
/// device-local knob used to decide this, and its "never expire" switch made
/// *every* human session on that panel immortal — the account is the thing
/// that knows who walked away with what, the panel is not.
///
/// "Never" is not a value here. A session that must not expire is a station
/// account (`AuthenticatedUser.stationAccount`), which is an administrator
/// saying "this identity is a panel, not a person" — and that is the only way
/// to get one. [resolveInactivityTimeout] cannot return null, so no stored
/// number, however mangled, can mint an immortal human session.
library;

/// Spec §5: fifteen minutes unless the account says otherwise.
const Duration kDefaultInactivityTimeout = Duration(minutes: 15);

/// The narrowest inactivity timeout an account may be given.
///
/// Below a minute the timeout stops being an inactivity guard and starts being
/// a fault: an operator reading a trend for ninety seconds would be signed out
/// mid-glance.
const Duration kMinInactivityTimeout = Duration(minutes: 1);

/// The widest inactivity timeout an account may be given.
///
/// Eight hours is a shift. Beyond that "times out on inactivity" is no longer
/// true in any useful sense, and a panel left elevated overnight is exactly
/// the accident this exists to make less likely.
const Duration kMaxInactivityTimeout = Duration(hours: 8);

/// Turns an account's stored minutes into the timeout its sessions use.
///
/// The seam the session controller reads through, so tests can scale minutes
/// down to milliseconds without a clock fake.
typedef InactivityTimeoutResolver = Duration Function(int? storedMinutes);

/// The timeout for an account whose `inactivity_timeout_minutes` is
/// [storedMinutes].
///
/// Null is "no value of its own", which is [kDefaultInactivityTimeout] — the
/// column is nullable so that a later role-level default can slot in between
/// the two without migrating a row. Anything else is clamped to
/// [kMinInactivityTimeout]..[kMaxInactivityTimeout]: the admin screen refuses
/// out-of-range input, so a value outside the range only arrives by `psql`,
/// and it must not end sessions instantly or never.
///
/// **Never returns null.** See the library doc.
Duration resolveInactivityTimeout(int? storedMinutes) {
  if (storedMinutes == null) return kDefaultInactivityTimeout;
  final requested = Duration(minutes: storedMinutes);
  if (requested < kMinInactivityTimeout) return kMinInactivityTimeout;
  if (requested > kMaxInactivityTimeout) return kMaxInactivityTimeout;
  return requested;
}

/// Whether [minutes] may be stored as an account's timeout.
///
/// One range check for the repository, which refuses, and the dialog, which
/// asks again.
bool isValidInactivityTimeoutMinutes(int minutes) =>
    minutes >= kMinInactivityTimeout.inMinutes &&
    minutes <= kMaxInactivityTimeout.inMinutes;

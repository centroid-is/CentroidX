import 'package:flutter/material.dart';

/// Asks for a time of day on the plant's clock, which is 24-hour.
///
/// Every time the HMI *shows* is 24-hour — the shift row's "Starts 19:00",
/// the system clock, the report windows — so the dialog that edits one must
/// be too. A bare [showTimePicker] follows the locale instead, and on a panel
/// whose locale resolves to en_US that means an AM/PM dial: the operator
/// reads 19:00, opens the picker, and is asked for 7 PM. [MediaQuery]'s
/// `alwaysUse24HourFormat` is what the picker reads, so it is overridden here
/// rather than at the app root — this way the dialog is 24-hour wherever it
/// is raised from, including hosts that build their own [MediaQuery].
///
/// [helpText] replaces the dialog's own heading when the caller has something
/// more specific to say than "Select time".
Future<TimeOfDay?> showPlantTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
  String? helpText,
}) {
  return showTimePicker(
    context: context,
    initialTime: initialTime,
    helpText: helpText,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
  );
}

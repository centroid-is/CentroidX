class AppRoutes {
  static const alarmView = '/alarm-view';
  static const historyView = '/history-view';

  /// Reachable only while `app_user` is empty; plan 01-09 registers the page
  /// and plan 01-08 links to it.
  static const firstUser = '/access/first-user';

  static const reports = '/reports';
  static const reportEditor = '/advanced/report-editor';
}

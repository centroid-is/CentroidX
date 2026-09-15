import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_cef/webview_cef.dart';

// The manager keys its controllers by browser id, which it learns only when
// the native `create` call answers. A render process can die inside that
// window -- a prewarmed browser's first page killing its fresh renderer is
// the realistic case -- and an event for an id the manager does not know yet
// must be parked and delivered when the id arrives, not dropped: a dropped
// one is a permanently blank browser that nothing ever re-navigates, handed
// on by the warm pool as if it were fine.
//
// These tests drive [WebviewManager.methodCallhandler] directly, the way the
// platform side does, so no real channel (and no CEF) is involved.
void main() {
  MethodCall goneCall(int browserId) => MethodCall('renderProcessGone',
      <dynamic, dynamic>{'browserId': browserId, 'status': 3});

  test('a death for a registered browser is delivered at once', () async {
    final manager = WebviewManager();
    final index = manager.nextIndex;
    final controller = manager.createWebView();
    final deaths = <int>[];
    controller.setWebviewListener(
        WebviewEventsListener(onRenderProcessGone: deaths.add));

    manager.onBrowserCreated(index, 9001);
    await manager.methodCallhandler(goneCall(9001));
    expect(deaths, [3]);
  });

  test('a death that lands before the id is registered is not lost',
      () async {
    final manager = WebviewManager();
    final index = manager.nextIndex;
    final controller = manager.createWebView();
    final deaths = <int>[];
    controller.setWebviewListener(
        WebviewEventsListener(onRenderProcessGone: deaths.add));

    // `create` is still in flight: the manager has never heard of this id.
    await manager.methodCallhandler(goneCall(9002));
    expect(deaths, isEmpty,
        reason: 'nobody is registered to hear it yet -- it must be parked');

    manager.onBrowserCreated(index, 9002);
    expect(deaths, [3],
        reason: 'registration is the first moment it can be delivered');

    // Parked means delivered once, not remembered for ever: a later
    // registration under the same id hears nothing.
    final laterIndex = manager.nextIndex;
    final later = manager.createWebView();
    final laterDeaths = <int>[];
    later.setWebviewListener(
        WebviewEventsListener(onRenderProcessGone: laterDeaths.add));
    manager.onBrowserCreated(laterIndex, 9002);
    expect(laterDeaths, isEmpty);
  });

  test('a death for a browser that never registers stays quietly parked',
      () async {
    final manager = WebviewManager();
    // No controller, no registration -- the handler must not throw.
    await manager.methodCallhandler(goneCall(9003));
  });
}

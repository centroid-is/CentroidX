import 'dart:typed_data';

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../page_creator/assets/image_store.dart';
import 'config_store.dart';

part 'page_images.g.dart';

/// The store the image asset and the page editor share for image bytes.
///
/// The guarded configuration store, not the preferences one: an image is a
/// `kind='page_image'` row since 04-09. Tests override this with a store on
/// the same `ConfigStore` the page manager saves into, so saved pages and
/// their image blobs land in one place.
@Riverpod(keepAlive: true)
Future<PageImageStore> pageImageStore(Ref ref) async {
  final store = await ref.watch(configStoreProvider.future);
  return PageImageStore(store);
}

/// Bytes of one stored page image; null when the id is unknown.
///
/// Re-read when the row for [imageId] arrives, changes or is collected. That
/// subscription is what closes T-04-09d at the screen: page images are
/// history-exempt, so another station's upload reaches this one through the
/// reconcile nudge rather than through the change log, and an asset that
/// landed *before* its image would otherwise keep showing the hole until
/// something else rebuilt it.
@riverpod
Future<Uint8List?> pageImageBytes(Ref ref, String imageId) async {
  final store = await ref.watch(pageImageStoreProvider.future);
  final subscription = store.imageChanges
      .where((id) => id == imageId)
      .listen((_) => ref.invalidateSelf());
  ref.onDispose(subscription.cancel);
  return store.load(imageId);
}

import 'dart:io';

import 'package:test/test.dart';

import '../proxy.dart';
import 'docker_compose.dart';

/// Pins the properties that let two copies of this suite run at the same time.
///
/// These are regression pins, not feature tests. Every assertion here
/// corresponds to a way parallel worktrees used to collide, and each collision
/// surfaced as something that looked like a genuine test failure rather than as
/// a resource conflict — which is how a "run the suites serially" rule got
/// written down as if it were a property of the code under test.
///
/// Observed before the fix (2026-09-07, this machine): both worktrees resolved
/// the compose project name to `integration` (Compose derives it from the
/// directory basename, and every worktree's path ends `.../test/integration`),
/// so the second `up` printed `Container test-db Running` and silently attached
/// to the *first* worktree's database. The second worktree's `down` then
/// stopped and removed the container the first was still using.
///
/// None of these need Docker; they are cheap enough to keep in the lane.
void main() {
  group('parallel-run isolation', () {
    test('the compose project name is unique per process', () {
      // Compose scopes container and network names by project. Two runs that
      // share a project name share containers -- and `down` in one removes the
      // other's database mid-test.
      expect(composeProjectName, isNot('integration'),
          reason: 'the directory-derived default is identical in every '
              'worktree, which is the collision');
      expect(composeProjectName, contains('$pid'),
          reason: 'must be scoped to this process, not to the checkout path');
    });

    test('the compose file pins neither a container name nor a host port', () {
      // Strip comments first. The compose file names both anti-patterns in
      // prose so the next reader knows why they are absent, and an assertion
      // that cannot tell an explanation from a directive would punish that.
      final yaml = File('$dockerComposePath/docker-compose.yml')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('#'))
          .join('\n');

      // `container_name:` is daemon-global -- it defeats project scoping, so a
      // second run cannot get its own container even under a unique project.
      expect(yaml, isNot(contains('container_name')),
          reason: 'an explicit container name is global to the Docker daemon '
              'and overrides per-project naming');

      // A `HOST:CONTAINER` mapping pins the host side. Publishing the container
      // port alone lets Docker allocate (and hold) an ephemeral host port.
      expect(RegExp(r'^\s*-\s*\d+\s*:\s*\d+\s*$', multiLine: true)
          .hasMatch(yaml), isFalse,
          reason: 'a fixed host-port mapping collides between parallel runs');
    });

    test('two proxies bind different ports', () async {
      // The listen port must come from the kernel, not from a literal. Two
      // instances in one process stand in for two instances in two processes:
      // a hard-coded port fails this the same way it fails across worktrees.
      final a = TcpProxy(targetPort: 1);
      final b = TcpProxy(targetPort: 1);
      addTearDown(a.shutdown);
      addTearDown(b.shutdown);

      await a.start();
      await b.start();

      expect(a.port, isNot(0));
      expect(b.port, isNot(0));
      expect(a.port, isNot(b.port));
    });
  });
}

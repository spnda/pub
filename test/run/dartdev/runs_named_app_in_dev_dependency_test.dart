// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.10

import 'package:test/test.dart';

import '../../descriptor.dart' as d;
import '../../test_pub.dart';

void main() {
  test('runs a named Dart application in a dev dependency', () async {
    await d.dir('foo', [
      d.libPubspec('foo', '1.0.0'),
      d.dir('bin', [d.file('bar.dart', "main() => print('foobar');")])
    ]).create();

    await d.dir(appPath, [
      d.pubspec({
        'name': 'myapp',
        'dev_dependencies': {
          'foo': {'path': '../foo'}
        }
      })
    ]).create();

    await pubGet();
    var pub = await pubRunFromDartDev(args: ['foo:bar']);
    expect(pub.stdout, emitsThrough('foobar'));
    await pub.shouldExit();
  });
}

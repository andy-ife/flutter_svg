import 'package:vector_graphics_compiler/vector_graphics_compiler.dart' as vg;
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  setUp(() {
    svg.cache.clear();
    svg.cache.maximumSize = 100;
  });

  test('ColorMapper updates the cache', () async {
    const loaderA = TestLoader();
    const loaderB = TestLoader(colorMapper: _TestColorMapper());
    final ByteData bytesA = await loaderA.loadBytes(null);
    final ByteData bytesB = await loaderB.loadBytes(null);
    expect(identical(bytesA, bytesB), false);
    expect(svg.cache.count, 2);
  });

  test('SvgTheme updates the cache', () async {
    const loaderA = TestLoader(
      theme: SvgTheme(currentColor: Color(0xFFABCDEF)),
    );
    const loaderB = TestLoader(
      theme: SvgTheme(currentColor: Color(0xFFFEDCBA)),
    );
    final ByteData bytesA = await loaderA.loadBytes(null);
    final ByteData bytesB = await loaderB.loadBytes(null);
    expect(identical(bytesA, bytesB), false);
    expect(svg.cache.count, 2);
  });

  test('Uses the cache', () async {
    const loader = TestLoader();
    final ByteData bytes = await loader.loadBytes(null);
    final ByteData bytes2 = await loader.loadBytes(null);
    expect(identical(bytes, bytes2), true);
    expect(svg.cache.count, 1);
  });

  test('Empty cache', () async {
    svg.cache.maximumSize = 0;
    const loader = TestLoader();
    final ByteData bytes = await loader.loadBytes(null);
    final ByteData bytes2 = await loader.loadBytes(null);
    expect(identical(bytes, bytes2), false);
    svg.cache.maximumSize = 100;
  });

  test('AssetLoader respects packages', () async {
    final bundle = TestBundle(<String, ByteData>{
      'foo': Uint8List(0).buffer.asByteData(),
      'packages/packageName/foo': Uint8List(1).buffer.asByteData(),
    });
    final loader = SvgAssetLoader('foo', assetBundle: bundle);
    final packageLoader = SvgAssetLoader(
      'foo',
      assetBundle: bundle,
      packageName: 'packageName',
    );
    expect((await loader.prepareMessage(null))!.lengthInBytes, 0);
    expect((await packageLoader.prepareMessage(null))!.lengthInBytes, 1);
  });

  test('AssetLoader correctly accesses buffer', () async {
    final ByteBuffer buffer = utf8.encode('foobar').buffer;
    final bundle = TestBundle(<String, ByteData>{
      'foo': buffer.asByteData(0, 3),
      'bar': buffer.asByteData(3, 3),
    });
    final loaderFoo = SvgAssetLoader('foo', assetBundle: bundle);
    final loaderBar = SvgAssetLoader('bar', assetBundle: bundle);
    final ByteData? byteDataFoo = await loaderFoo.prepareMessage(null);
    final ByteData? byteDataBar = await loaderBar.prepareMessage(null);

    expect(byteDataFoo!.buffer, equals(byteDataBar!.buffer));

    expect(byteDataFoo.lengthInBytes, 3);
    expect(byteDataFoo.offsetInBytes, 0);

    expect(byteDataBar.offsetInBytes, 3);
    expect(byteDataBar.lengthInBytes, 3);

    expect(loaderFoo.provideSvg(byteDataFoo), equals('foo'));
    expect(loaderBar.provideSvg(byteDataBar), equals('bar'));
  });

  test('SvgNetworkLoader closes internal client', () async {
    final createdClients = <VerifyCloseClient>[];

    await http.runWithClient(
      () async {
        const loader = SvgNetworkLoader('');

        expect(createdClients, isEmpty);
        await loader.prepareMessage(null);

        expect(createdClients, hasLength(1));
        expect(createdClients[0].closeCalled, isTrue);
      },
      () {
        final client = VerifyCloseClient();
        createdClients.add(client);
        return client;
      },
    );
  });

  test("SvgNetworkLoader doesn't close passed client", () async {
    final client = VerifyCloseClient();
    final loader = SvgNetworkLoader('', httpClient: client as http.Client);

    expect(client.closeCalled, isFalse);
    await loader.prepareMessage(null);
    expect(client.closeCalled, isFalse);
  });

  testWidgets('All loaders use default or passed errorIconPath on failure', (
    tester,
  ) async {
    final defaultSvgStr = '<svg width="1" height="1"></svg>';
    final customSvgStr = '<svg width="2" height="2"></svg>';

    final defaultVgBytes = vg
        .encodeSvg(
          xml: defaultSvgStr,
          debugName: 'default',
          enableClippingOptimizer: false,
          enableMaskingOptimizer: false,
          enableOverdrawOptimizer: false,
        )
        .buffer
        .asByteData();

    final customVgBytes = vg
        .encodeSvg(
          xml: customSvgStr,
          debugName: 'custom',
          enableClippingOptimizer: false,
          enableMaskingOptimizer: false,
          enableOverdrawOptimizer: false,
        )
        .buffer
        .asByteData();

    final bundle = SyncTestBundle(<String, ByteData>{
      'assets/svg/error_network.svg': ByteData.view(
        Uint8List.fromList(defaultSvgStr.codeUnits).buffer,
      ),
      'custom_error.svg': ByteData.view(
        Uint8List.fromList(customSvgStr.codeUnits).buffer,
      ),
    });

    BuildContext? ctx;
    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: bundle,
        child: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );

    // SvgNetworkLoader (compiles fallback because prepareMessage handles the error)
    await http.runWithClient(() async {
      final loader1 = const SvgNetworkLoader('http://invalid.url');
      final bytes1 = await loader1.loadBytes(ctx);
      expect(
        bytes1.buffer.asUint8List().toList(),
        defaultVgBytes.buffer.asUint8List().toList(),
      );

      final loader2 = const SvgNetworkLoader(
        'http://invalid2.url',
        errorIconPath: 'custom_error.svg',
      );
      final bytes2 = await loader2.loadBytes(ctx);
      expect(
        bytes2.buffer.asUint8List().toList(),
        customVgBytes.buffer.asUint8List().toList(),
      );
    }, () => ThrowingClient());

    svg.cache.clear();

    // SvgStringLoader (doesn't compile fallback because _load catch block returns it raw)
    final loader3 = const SvgStringLoader('<invalid');
    final bytes3 = await loader3.loadBytes(ctx);
    expect(bytes3.buffer.asUint8List().toList(), defaultSvgStr.codeUnits);

    final loader4 = const SvgStringLoader(
      '<invalid2',
      errorIconPath: 'custom_error.svg',
    );
    final bytes4 = await loader4.loadBytes(ctx);
    expect(bytes4.buffer.asUint8List().toList(), customSvgStr.codeUnits);

    svg.cache.clear();

    // SvgAssetLoader
    final loader5 = const SvgAssetLoader('missing.svg');
    final bytes5 = await loader5.loadBytes(ctx);
    expect(bytes5.buffer.asUint8List().toList(), defaultSvgStr.codeUnits);

    final loader6 = const SvgAssetLoader(
      'missing2.svg',
      errorIconPath: 'custom_error.svg',
    );
    final bytes6 = await loader6.loadBytes(ctx);
    expect(bytes6.buffer.asUint8List().toList(), customSvgStr.codeUnits);

    svg.cache.clear();

    // SvgBytesLoader
    final loader7 = SvgBytesLoader(Uint8List.fromList([0]));
    final bytes7 = await loader7.loadBytes(ctx);
    expect(bytes7.buffer.asUint8List().toList(), defaultSvgStr.codeUnits);

    final loader8 = SvgBytesLoader(
      Uint8List.fromList([1]),
      errorIconPath: 'custom_error.svg',
    );
    final bytes8 = await loader8.loadBytes(ctx);
    expect(bytes8.buffer.asUint8List().toList(), customSvgStr.codeUnits);
  });
}

class TestBundle extends Fake implements AssetBundle {
  TestBundle(this.map);

  final Map<String, ByteData> map;

  @override
  Future<ByteData> load(String key) async {
    return map[key]!;
  }
}

class TestLoader extends SvgLoader<void> {
  const TestLoader({this.keyName = 'A', super.theme, super.colorMapper});

  final String keyName;

  @override
  String provideSvg(void message) {
    return '<svg width="10" height="10"></svg>';
  }

  @override
  SvgCacheKey cacheKey(BuildContext? context) {
    return SvgCacheKey(
      theme: theme,
      colorMapper: colorMapper,
      keyData: keyName,
    );
  }
}

class _TestColorMapper extends ColorMapper {
  const _TestColorMapper();

  @override
  Color substitute(
    String? id,
    String elementName,
    String attributeName,
    Color color,
  ) {
    return color;
  }
}

class VerifyCloseClient extends Fake implements http.Client {
  bool closeCalled = false;

  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
    return http.Response('', 200);
  }

  @override
  void close() {
    assert(!closeCalled);
    closeCalled = true;
  }
}

class SyncTestBundle extends Fake implements AssetBundle {
  SyncTestBundle(this.map);
  final Map<String, ByteData> map;
  @override
  Future<ByteData> load(String key) {
    if (map.containsKey(key)) return SynchronousFuture(map[key]!);
    throw Exception('Not found');
  }
}

class ThrowingClient extends Fake implements http.Client {
  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
    throw Exception('Simulated network error');
  }
}

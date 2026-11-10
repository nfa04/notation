import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/markdown/document_images.dart';
import 'package:notes/markdown/remote_image.dart';

void main() {
  test('only the pictures the app keeps are read from this device', () async {
    DocumentImages.dir = '/data/images';
    expect(DocumentImages.fileOf('image:a.png')!.path, '/data/images/a.png');
    expect(DocumentImages.fileOf('image:../../etc/passwd')!.path, '/data/images/passwd');
    expect(DocumentImages.fileOf('/home/me/.ssh/id_rsa'), isNull);
    expect(DocumentImages.fileOf('file:///home/me/photo.jpg'), isNull);
    expect(DocumentImages.fileOf('https://example.com/a.png'), isNull);
    expect(await DocumentImages.read('/etc/hostname'), isNull);
  });

  test('which targets are web addresses', () {
    expect(RemoteImage.isWeb('https://example.com/a.png'), isTrue);
    expect(RemoteImage.isWeb('http://192.168.1.1/x'), isTrue);
    expect(RemoteImage.isWeb('file:///etc/passwd'), isFalse);
    expect(RemoteImage.isWeb('javascript:alert(1)'), isFalse);
    expect(RemoteImage.isWeb('https://'), isFalse);
  });

  testWidgets('a web picture is not requested until the person taps it', (tester) async {
    RemoteImage.forgetAll();
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: RemoteImage(url: 'https://tracker.example/p.png', label: 'x'))));
    expect(find.textContaining('tracker.example'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    await tester.tap(find.byKey(const ValueKey('remote-image-load')));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    RemoteImage.forgetAll();
  });
}

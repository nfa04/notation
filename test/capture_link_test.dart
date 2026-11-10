import 'package:flutter_test/flutter_test.dart';
import 'package:notes/capture/capture_link.dart';

void main() {
  test('a text to save, with its title', () {
    final link = parseCaptureLink(Uri.parse('notation://capture?text=Buy%20milk&title=Shopping')) as QuickCaptureLink;
    expect(link.text, 'Buy milk');
    expect(link.title, 'Shopping');
    expect(link.file, isNull);
  });

  test('no text at all asks for a blank note', () {
    final link = parseCaptureLink(Uri.parse('notation://capture')) as QuickCaptureLink;
    expect(link.text, '');
    expect(link.title, isNull);
  });

  test('a shared file', () {
    final link = parseCaptureLink(Uri(scheme: 'notation', host: 'capture', queryParameters: {'file': '/cache/shared/photo.png'})) as QuickCaptureLink;
    expect(link.file, '/cache/shared/photo.png');
  });

  test('the page of the bookmarklet, with its selection', () {
    final link = parseCaptureLink(Uri.parse('notation://clip?u=${Uri.encodeComponent('https://example.org/a?b=1&c=2')}&t=An%20article&x=Some%20words')) as ClipLink;
    expect(link.url, Uri.parse('https://example.org/a?b=1&c=2'));
    expect(link.title, 'An article');
    expect(link.selection, 'Some words');
  });

  test('only web addresses can be clipped', () {
    for (final u in ['file:///etc/passwd', 'javascript:alert(1)', 'ftp://x.org/a', '', 'notaurl', 'http://']) {
      expect(parseCaptureLink(Uri.parse('notation://clip?u=${Uri.encodeComponent(u)}')), isNull, reason: u);
    }
    expect(parseCaptureLink(Uri.parse('notation://clip')), isNull);
  });

  test('other links are not capture links', () {
    expect(parseCaptureLink(Uri.parse('notation://join?s=x')), isNull);
    expect(parseCaptureLink(Uri.parse('https://capture/x')), isNull);
  });

  test('very long text is cut', () {
    final link = parseCaptureLink(Uri(scheme: 'notation', host: 'capture', queryParameters: {'text': 'x' * (maxCaptureText + 500)})) as QuickCaptureLink;
    expect(link.text.length, maxCaptureText);
  });

  test('a link names a file only on a phone, and only inside the cache folder', () {
    expect(captureFileAllowed('/cache/1-a.pdf', '/cache', mobile: true), isTrue);
    expect(captureFileAllowed('/cache/../etc/passwd', '/cache', mobile: true), isFalse);
    expect(captureFileAllowed('/etc/passwd', '/cache', mobile: true), isFalse);
    expect(captureFileAllowed('a.pdf', '/cache', mobile: true), isFalse);
    expect(captureFileAllowed('/cache/1-a.pdf', '/cache', mobile: false), isFalse);
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/layers.dart';

/// The layers of a note as an OpenRaster file (.ora, the layered picture format Krita, GIMP, MyPaint and others open): a ZIP with a
/// `stack.xml` that names the layers (their order, opacity, visibility and blend mode, groups as nested stacks), a PNG for each layer,
/// and the whole picture. A layer that is clipped to the one below it is not clipped in the file (the format has no such thing).

/// The OpenRaster name of a blend mode.
String oraCompositeOp(LayerBlend blend) => switch (blend) {
      LayerBlend.normal => 'svg:src-over',
      LayerBlend.multiply => 'svg:multiply',
      LayerBlend.screen => 'svg:screen',
      LayerBlend.overlay => 'svg:overlay',
      LayerBlend.softLight => 'svg:soft-light',
      LayerBlend.darken => 'svg:darken',
      LayerBlend.lighten => 'svg:lighten',
      LayerBlend.colorDodge => 'svg:color-dodge',
      LayerBlend.colorBurn => 'svg:color-burn',
      LayerBlend.difference => 'svg:difference',
    };

String _xml(String text) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

String _opacity(double o) => o.clamp(0.0, 1.0).toStringAsFixed(3);

/// The `stack.xml` of a picture of [width] × [height] with the layers of [layers] over [paper] (the file of the paper layer, or null
/// for none). [srcOf] gives the file inside the archive of each layer that is not a group.
String oraStackXml({required int width, required int height, required LayerStack layers, required String Function(NoteLayer layer) srcOf, String? paper}) {
  final out = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<image version="0.0.3" w="$width" h="$height"><stack opacity="1.000" name="root" visibility="visible">');
  String layerTag(NoteLayer l, String src) =>
      '<layer name="${_xml(l.name)}" src="$src" x="0" y="0" opacity="${_opacity(l.opacity)}" visibility="${l.visible ? 'visible' : 'hidden'}" composite-op="${oraCompositeOp(l.blend)}"/>';
  // (the first in the file is the top one)
  final top = [for (final l in layers.layers) if (l.group.isEmpty) l].reversed;
  for (final l in top) {
    if (l.isGroup) {
      out.write('<stack name="${_xml(l.name)}" opacity="${_opacity(l.opacity)}" visibility="${l.visible ? 'visible' : 'hidden'}" composite-op="${oraCompositeOp(l.blend)}">');
      for (final m in layers.layers.where((m) => m.group == l.id).toList().reversed) {
        out.write(layerTag(m, srcOf(m)));
      }
      out.write('</stack>');
    } else {
      out.write(layerTag(l, srcOf(l)));
    }
  }
  if (paper != null) out.write('<layer name="Paper" src="$paper" x="0" y="0" opacity="1.000" visibility="visible" composite-op="svg:src-over"/>');
  out.write('</stack></image>');
  return out.toString();
}

/// The bytes of the .ora file: [layerPngs] by file name inside the archive (`data/...`), [merged] the whole picture, [thumbnail] a small one.
Uint8List oraArchive({required String stackXml, required Map<String, Uint8List> layerPngs, required Uint8List merged, required Uint8List thumbnail}) {
  final archive = Archive();
  // (the type comes first and is not compressed, so that a program can tell what the file is from its first bytes)
  archive.add(ArchiveFile.bytes('mimetype', utf8.encode('image/openraster'))..compression = CompressionType.none);
  archive.add(ArchiveFile.bytes('stack.xml', utf8.encode(stackXml)));
  for (final e in layerPngs.entries) {
    archive.add(ArchiveFile.bytes(e.key, e.value)..compression = CompressionType.none);
  }
  archive.add(ArchiveFile.bytes('mergedimage.png', merged)..compression = CompressionType.none);
  archive.add(ArchiveFile.bytes('Thumbnails/thumbnail.png', thumbnail)..compression = CompressionType.none);
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

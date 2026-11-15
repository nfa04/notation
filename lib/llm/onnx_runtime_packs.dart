import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'download.dart';

/// A runtime pack: a folder with a whole ONNX Runtime (libonnxruntime.so and the provider libraries of one build next to it) that
/// has the providers of a graphics card (CUDA, OpenVINO, MIGraphX). The app's own runtime is built for the processor only; a pack
/// replaces it at the next start. Only Linux has packs so far.
class OnnxRuntimePack {
  /// The folder's name, shown to the user (for example 'migraphx-rocm-7.1').
  final String name;

  /// The libonnxruntime.so that is opened.
  final String library;
  const OnnxRuntimePack(this.name, this.library);
}

bool get onnxRuntimePacksSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

/// Where the packs are kept: one folder each in `onnx_runtimes` of the app's data.
Future<Directory> onnxRuntimePackFolder() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'onnx_runtimes'));

/// The packs found in [folder] (a folder with a libonnxruntime.so, or a versioned libonnxruntime.so.N.M.K, in each of its folders).
Future<List<OnnxRuntimePack>> findOnnxRuntimePacks(Directory folder) async {
  if (!await folder.exists()) return const [];
  final found = <OnnxRuntimePack>[];
  await for (final e in folder.list(followLinks: false)) {
    if (e is! Directory) continue;
    final lib = await _libraryIn(e);
    if (lib != null) found.add(OnnxRuntimePack(p.basename(e.path), lib));
  }
  found.sort((a, b) => a.name.compareTo(b.name));
  return found;
}

Future<String?> _libraryIn(Directory dir) async {
  for (final name in const ['libonnxruntime.so']) {
    if (await File(p.join(dir.path, name)).exists()) return p.join(dir.path, name);
  }
  final versioned = <String>[];
  await for (final f in dir.list(followLinks: false)) {
    final n = p.basename(f.path);
    if (f is File && RegExp(r'^libonnxruntime\.so\.\d+(\.\d+)*$').hasMatch(n)) versioned.add(f.path);
  }
  versioned.sort();
  return versioned.isEmpty ? null : versioned.last;
}

/// Which runtime is in use now, and which one is saved for the next start (null when the plugin cannot say: not Linux).
Future<({String version, String path, String error, String chosen})?> onnxRuntimeInfo() async {
  if (!onnxRuntimePacksSupported) return null;
  try {
    return await OnnxRuntime().getRuntimeInfo();
  } catch (_) {
    return null;
  }
}

/// Saves the pack to open at the next start; null goes back to the app's own runtime.
Future<void> chooseOnnxRuntimePack(OnnxRuntimePack? pack) => OnnxRuntime().chooseRuntime(pack?.library ?? '');


// ---- fetching a pack

/// Where the packs are kept for download: one folder per kind, each with a `manifest.json` that tool/gpu_runtime/make_pack.sh writes
/// (`{"name": "cuda12-ort-1.28.3", "files": [{"path": "libonnxruntime.so.1.28.3", "bytes": 123, "sha256": "..."},
/// {"path": "libonnxruntime.so", "link": "libonnxruntime.so.1.28.3"}]}`).
const onnxRuntimePackHost = 'https://huggingface.co/nfa04/onnxruntime-packs/resolve/main';

/// A pack on offer: [id] is its folder at the host.
class OnnxRuntimeDownload {
  final String id;
  final String label;

  /// What it needs on the machine, said to the user.
  final String needs;
  const OnnxRuntimeDownload(this.id, this.label, this.needs);
  String get manifestUrl => '$onnxRuntimePackHost/$id/manifest.json';
}

const onnxRuntimeDownloads = [
  OnnxRuntimeDownload('cuda13', 'NVIDIA graphics card (CUDA 13)', 'the NVIDIA driver 580 or newer, and CUDA 13 with cuDNN'),
  OnnxRuntimeDownload('cuda12', 'NVIDIA graphics card (CUDA 12)', 'the NVIDIA driver, and CUDA 12 with cuDNN'),
  OnnxRuntimeDownload('migraphx', 'AMD graphics card (ROCm)', 'ROCm 7.1'),
  OnnxRuntimeDownload('openvino', 'Intel graphics card / NPU (OpenVINO)', 'the Intel compute runtime'),
];

/// Which of [onnxRuntimeDownloads] fit this machine (by id), from what Linux says about its hardware. [sys] is the root, for tests.
Future<List<String>> suggestedRuntimeDownloads({String sys = '/'}) async {
  final found = <String>[];
  Future<String?> read(String path) async {
    try {
      return await File(p.join(sys, path)).readAsString();
    } catch (_) {
      return null;
    }
  }

  final nvidia = await read('proc/driver/nvidia/version');
  if (nvidia != null) {
    final major = int.tryParse(RegExp(r'(\d+)\.\d+(\.\d+)?\s').firstMatch(nvidia.split('Kernel Module').last)?.group(1) ?? '') ?? 0;
    found.add(major >= 580 ? 'cuda13' : 'cuda12');
  }
  if (await File(p.join(sys, 'dev/kfd')).exists()) found.add('migraphx');
  // Intel: a display adapter or an NPU with Intel's vendor number
  for (final dir in [Directory(p.join(sys, 'sys/class/drm')), Directory(p.join(sys, 'sys/class/accel'))]) {
    if (!await dir.exists()) continue;
    await for (final e in dir.list(followLinks: false)) {
      if ((await read(p.join(p.relative(e.path, from: sys), 'device/vendor')))?.trim() == '0x8086') {
        if (!found.contains('openvino')) found.add('openvino');
      }
    }
  }
  return found;
}

/// Downloads the pack [d] into [folder] (the folder of the packs) and returns it. The files go to a temporary folder first and are
/// checked against the manifest; only a complete pack is moved into place, so a broken download never shows up in the list.
Future<OnnxRuntimePack> downloadOnnxRuntimePack(
  OnnxRuntimeDownload d, {
  required Directory folder,
  Future<void> Function(String url, String path, void Function(double) progress)? download,
  void Function(double)? progress,
}) async {
  final fetch = download ?? (String u, String path, void Function(double) pr) => downloadToFile(u, path, pr);
  await folder.create(recursive: true);
  final temp = Directory(p.join(folder.path, '.download-${d.id}'));
  if (await temp.exists()) await temp.delete(recursive: true);
  await temp.create();
  try {
    final manifestFile = p.join(temp.path, '.manifest.json');
    await fetch(d.manifestUrl, manifestFile, (_) {});
    final manifest = jsonDecode(await File(manifestFile).readAsString()) as Map<String, dynamic>;
    final name = '${manifest['name']}';
    // (the name and the paths become file names here: nothing may point out of the folder)
    bool safe(String x) => x.isNotEmpty && !p.isAbsolute(x) && p.isWithin(temp.path, p.join(temp.path, x)) && !x.startsWith('.');
    if (!safe(name) || name.contains('/')) throw const FormatException('the manifest has no usable name');
    final files = [for (final f in manifest['files'] as List) f as Map<String, dynamic>];
    final total = files.fold<int>(0, (a, f) => a + ((f['bytes'] as num?)?.toInt() ?? 0));
    var before = 0;
    for (final f in files) {
      final path = '${f['path']}';
      if (!safe(path)) throw FormatException('unsafe path in the manifest: $path');
      final target = p.join(temp.path, path);
      await Directory(p.dirname(target)).create(recursive: true);
      if (f['link'] != null) {
        if (!safe('${f['link']}')) throw FormatException('unsafe link in the manifest: ${f['link']}');
        await Link(target).create('${f['link']}');
        continue;
      }
      final size = (f['bytes'] as num?)?.toInt() ?? 0;
      await fetch('${d.manifestUrl.substring(0, d.manifestUrl.length - 'manifest.json'.length)}$path', target, (x) => progress?.call(total == 0 ? 0 : (before + x * size) / total));
      // a library that is opened by the app is never taken without a checksum: a manifest that leaves it out is refused
      final want = f['sha256'];
      if (want is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(want.toLowerCase())) throw FormatException('$path has no checksum in the manifest');
      if ((await sha256.bind(File(target).openRead()).first).toString() != want.toLowerCase()) throw FormatException('$path did not arrive whole (checksum)');
      before += size;
    }
    await File(manifestFile).delete();
    final dest = Directory(p.join(folder.path, name));
    if (await dest.exists()) await dest.delete(recursive: true);
    await temp.rename(dest.path);
    final lib = await _libraryIn(dest);
    if (lib == null) throw const FormatException('the download has no libonnxruntime.so');
    progress?.call(1);
    return OnnxRuntimePack(name, lib);
  } catch (_) {
    if (await temp.exists()) await temp.delete(recursive: true);
    rethrow;
  }
}

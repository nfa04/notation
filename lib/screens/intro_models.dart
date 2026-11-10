import 'package:flutter/material.dart';

import '../ai/ai_switch.dart';
import '../features/feature.dart';
import '../ink/ink_recognizer.dart';

/// A model the intro offers to download: what it is for, how big it is, and which tools make it worth having.
class IntroModel {
  final String id;
  final String title;
  final String description;
  final IconData icon;

  /// The model itself (it keeps its own status and progress, which the settings show too).
  final DownloadableModel service;

  /// It is wanted (on to begin with) when one of these tools is on. Empty: never on to begin with, only when asked for (a download
  /// too big to start without a question).
  final Set<Feature> wantedFor;

  const IntroModel({required this.id, required this.title, required this.description, required this.icon, required this.service, this.wantedFor = const {}});

  bool wantedWith(Set<Feature> tools) => wantedFor.any(tools.contains);
}

/// What the intro needs for its step about smart features: the kill switch of the AI features and the models behind them.
class IntroSmart {
  final AiSwitch aiSwitch;
  final List<IntroModel> models;

  /// Tells whether the device is on mobile data and not on Wi-Fi or a cable (a download of hundreds of MB is then worth a warning);
  /// null: not known. It must not throw: a system that cannot tell answers false.
  final Future<bool> Function()? onMobileData;

  const IntroSmart({required this.aiSwitch, required this.models, this.onMobileData});

  /// What is wanted for these tools.
  Set<String> defaultsFor(Set<Feature> tools) => {for (final m in models) if (m.wantedWith(tools) && m.service.status != HandwritingStatus.installed) m.id};

  /// Switches the AI features as chosen and starts the downloads that were chosen in the background (the person is not kept
  /// waiting: the settings show their progress). With the AI features off nothing is downloaded.
  Future<void> apply({required bool aiOn, required Set<String> download}) async {
    await aiSwitch.setEnabled(aiOn);
    if (!aiOn) return;
    for (final m in models) {
      if (download.contains(m.id) && m.service.status == HandwritingStatus.notInstalled) {
        m.service.install(); // (not awaited: it runs while the app opens)
      }
    }
  }
}

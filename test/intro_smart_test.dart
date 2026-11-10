import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/ai_switch.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/ink/ink_recognizer.dart';
import 'package:notes/profile/user_profile.dart';
import 'package:notes/screens/intro_look.dart';
import 'package:notes/screens/intro_models.dart';
import 'package:notes/style/stylus_settings.dart';
import 'package:notes/style/app_theme.dart';
import 'package:notes/l10n/language.dart';
import 'package:notes/screens/intro_screen.dart';

class _Model extends DownloadableModel {
  _Model(this.sizeMb);
  HandwritingStatus _status = HandwritingStatus.notInstalled;
  int installs = 0;

  /// While set, [install] starts the download and does not finish it.
  Completer<void>? hold;
  double _progress = 0;
  void report(double v) {
    _progress = v;
    notifyListeners();
  }
  @override
  HandwritingStatus get status => _status;
  @override
  double get progress => _progress;
  @override
  String? get error => null;
  @override
  final int sizeMb;
  @override
  Future<void> load() async {}
  @override
  Future<void> install() async {
    installs++;
    if (hold != null) {
      _status = HandwritingStatus.downloading;
      notifyListeners();
      await hold!.future;
    }
    _status = HandwritingStatus.installed;
    notifyListeners();
  }

  @override
  Future<void> remove() async {}
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Map<String, String> store;
  late UserProfile profile;
  late FeatureSettings features;
  late AiSwitch ai;
  late _Model hand, math, chat;
  late IntroSmart smart;
  Set<Feature>? welcomed;

  Future<void> start(WidgetTester tester, {bool? mobile}) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    store = {};
    welcomed = null;
    profile = UserProfile((k) async => store[k], (k, v) async => store[k] = v);
    features = FeatureSettings((k) async => store[k], (k, v) async => store[k] = v);
    await tester.runAsync(() async {
      await profile.load();
      await features.load();
    });
    ai = AiSwitch();
    hand = _Model(61);
    math = _Model(300);
    chat = _Model(600);
    smart = IntroSmart(aiSwitch: ai, models: [
      IntroModel(id: 'handwriting', title: 'Handwriting to text', description: 'd', icon: Icons.edit, service: hand, wantedFor: const {Feature.handwriting}),
      IntroModel(id: 'maths', title: 'Formulas and maths check', description: 'd', icon: Icons.rule, service: math, wantedFor: const {Feature.mathInk, Feature.checkMaths}),
      IntroModel(id: 'assistant', title: 'Assistant', description: 'd', icon: Icons.auto_awesome, service: chat),
    ], onMobileData: mobile == null ? null : () async => mobile);
    await tester.pumpWidget(MaterialApp(home: ListenableBuilder(listenable: profile, builder: (_, _) => IntroScreen(profile: profile, features: features, smart: smart, welcome: (tools) async => welcomed = tools))));
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Future<void> toSmartStep(WidgetTester tester, {String? area}) async {
    await tap(tester, 'intro-next'); // welcome
    await tap(tester, 'intro-next'); // name
    if (area != null) await tap(tester, 'area-$area');
    await tap(tester, 'intro-next'); // uses
    await tap(tester, 'intro-next'); // tools
    expect(find.text('Smart features'), findsOneWidget);
  }

  bool ticked(WidgetTester tester, String id) => tester.widget<CheckboxListTile>(find.byKey(ValueKey('intro-model-$id'))).value!;

  group('the intro, smart features', () {
    testWidgets('the models a use needs are ticked, the big one is not, and Start downloads them in the background', (tester) async {
      await start(tester);
      await toSmartStep(tester, area: 'maths');
      expect(ticked(tester, 'handwriting'), isTrue);
      expect(ticked(tester, 'maths'), isTrue);
      expect(ticked(tester, 'assistant'), isFalse, reason: 'too big to start without asking');
      expect(find.textContaining('Pressing Start downloads 361 MB'), findsOneWidget);

      await tap(tester, 'intro-model-maths'); // not that one
      expect(find.textContaining('Pressing Start downloads 61 MB'), findsOneWidget);
      await tap(tester, 'intro-next'); // Start
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(profile.introDone, isTrue);
      expect(ai.enabled, isTrue);
      expect(hand.installs, 1);
      expect(math.installs, 0);
      expect(chat.installs, 0);
    });

    testWidgets('on mobile data the step warns about the size, until nothing is left to download', (tester) async {
      await start(tester, mobile: true);
      await toSmartStep(tester, area: 'maths');
      expect(find.byKey(const ValueKey('intro-mobile-hint')), findsOneWidget);
      await tap(tester, 'intro-model-handwriting');
      await tap(tester, 'intro-model-maths'); // nothing left to download: nothing to warn about
      expect(find.byKey(const ValueKey('intro-mobile-hint')), findsNothing);
    });

    for (final mobile in [false, null]) {
      testWidgets('no warning when ${mobile == null ? 'it cannot be told' : 'on Wi-Fi'}', (tester) async {
        await start(tester, mobile: mobile);
        await toSmartStep(tester, area: 'maths');
        expect(find.byKey(const ValueKey('intro-mobile-hint')), findsNothing);
      });
    }

    testWidgets('a use that does not need the formula reader does not tick it', (tester) async {
      await start(tester);
      await toSmartStep(tester, area: 'humanities');
      expect(ticked(tester, 'handwriting'), isTrue);
      expect(ticked(tester, 'maths'), isFalse);
    });

    testWidgets('the main switch off: no models are offered, nothing is downloaded, and the AI features are off', (tester) async {
      await start(tester);
      await toSmartStep(tester, area: 'maths');
      await tap(tester, 'intro-ai');
      expect(find.byKey(const ValueKey('intro-model-handwriting')), findsNothing);
      await tap(tester, 'intro-next');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(profile.introDone, isTrue);
      expect(ai.enabled, isFalse);
      expect(hand.installs + math.installs + chat.installs, 0);
    });

    testWidgets('a model that is on the device is shown as there, and nothing is downloaded twice', (tester) async {
      await start(tester);
      hand._status = HandwritingStatus.installed;
      await toSmartStep(tester, area: 'humanities');
      expect(find.text('Already on this device'), findsOneWidget);
      await tap(tester, 'intro-next');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(hand.installs, 0);
    });

    testWidgets('skipping downloads nothing and leaves the AI features as they were', (tester) async {
      await start(tester);
      await tap(tester, 'intro-skip');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(profile.introDone, isTrue);
      expect(ai.enabled, isTrue);
      expect(hand.installs + math.installs + chat.installs, 0);
    });

    testWidgets('changing the uses again changes what is ticked', (tester) async {
      await start(tester);
      await toSmartStep(tester, area: 'humanities');
      expect(ticked(tester, 'maths'), isFalse);
      await tap(tester, 'intro-back');
      await tap(tester, 'intro-back');
      await tap(tester, 'area-maths');
      await tap(tester, 'intro-next');
      await tap(tester, 'intro-next');
      expect(ticked(tester, 'maths'), isTrue);
    });
  });

  group('the intro, the note that shows the tools', () {
    testWidgets('is made with the tools that were chosen, unless it is switched off', (tester) async {
      await start(tester);
      await toSmartStep(tester, area: 'humanities');
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('intro-welcome-note'))).value, isTrue);
      await tap(tester, 'intro-next');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(welcomed, isNotNull);
      expect(welcomed, contains(Feature.diagrams));
      expect(welcomed, isNot(contains(Feature.checkMaths)));
    });

    testWidgets('is not made when it is switched off, or when the intro is skipped', (tester) async {
      await start(tester);
      await toSmartStep(tester, area: 'humanities');
      await tap(tester, 'intro-welcome-note');
      await tap(tester, 'intro-next');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(welcomed, isNull);
    });

    testWidgets('is offered on the last step even without the smart features', (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      store = {};
      profile = UserProfile((k) async => store[k], (k, v) async => store[k] = v);
      features = FeatureSettings((k) async => store[k], (k, v) async => store[k] = v);
      await tester.runAsync(() async {
        await profile.load();
        await features.load();
      });
      welcomed = null;
      await tester.pumpWidget(MaterialApp(home: IntroScreen(profile: profile, features: features, welcome: (tools) async => welcomed = tools)));
      for (var i = 0; i < 4; i++) {
        await tap(tester, 'intro-next');
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(welcomed, isNotNull);
    });
  });

  group('the intro, the download and the look', () {
    late StylusSettings stylus;

    Future<void> startWithLook(WidgetTester tester) async {
      await start(tester);
      stylus = StylusSettings.inMemory();
      await tester.pumpWidget(MaterialApp(
        home: ListenableBuilder(
          listenable: profile,
          builder: (_, _) => IntroScreen(profile: profile, features: features, smart: smart, look: IntroLook(theme: AppTheme.inMemory(), stylus: stylus)),
        ),
      ));
    }

    testWidgets('Next on the smart features starts the download, and the next steps show how far it is and that they can go on', (tester) async {
      await startWithLook(tester);
      hand.hold = Completer<void>();
      hand.report(0.05); // (an indeterminate bar never settles)
      await toSmartStep(tester, area: 'humanities');
      await tap(tester, 'intro-next');
      expect(find.text('Language, colour and pen'), findsOneWidget, reason: 'the intro goes on');
      expect(hand.installs, 1);
      expect(find.byKey(const ValueKey('intro-downloads')), findsOneWidget);
      hand.report(0.4);
      await tester.pump();
      expect(find.descendant(of: find.byKey(const ValueKey('intro-downloads')), matching: find.text('40 %')), findsOneWidget);
      expect(find.text('You can carry on: the download continues in the background.'), findsOneWidget);

      hand.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('intro-downloads')), findsNothing, reason: 'it is done');
    });

    testWidgets('with the AI features off the next steps show no download', (tester) async {
      await startWithLook(tester);
      await toSmartStep(tester, area: 'maths');
      await tap(tester, 'intro-ai');
      await tap(tester, 'intro-next');
      expect(find.byKey(const ValueKey('intro-downloads')), findsNothing);
      expect(ai.enabled, isFalse);
    });

    testWidgets('the pen pad says what kind of pointer wrote on it, and a finger mode can be chosen', (tester) async {
      await startWithLook(tester);
      await toSmartStep(tester, area: 'maths');
      await tap(tester, 'intro-next');
      final pad = find.byKey(const ValueKey('intro-pen-pad'));
      await tester.ensureVisible(pad);
      await tester.pumpAndSettle();
      final g = await tester.startGesture(tester.getCenter(pad), kind: PointerDeviceKind.stylus);
      await g.moveBy(const Offset(30, 10));
      await g.moveBy(const Offset(30, 10));
      await g.up();
      await tester.pump();
      expect(find.textContaining('A pen was found'), findsOneWidget);

      await tap(tester, 'intro-finger-draw');
      expect(stylus.fingers, FingerMode.draw);
      await tap(tester, 'intro-language-de');
      expect(AppLanguage.instance.choice, 'de');
      AppLanguage.instance = AppLanguage.inMemory();
    });

    testWidgets('the look is the last step when there is no way to sync, and Start finishes from there', (tester) async {
      await startWithLook(tester);
      await toSmartStep(tester, area: 'maths');
      await tap(tester, 'intro-next');
      expect(find.byKey(const ValueKey('intro-set-up-sync')), findsNothing);
      await tap(tester, 'intro-next');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(profile.introDone, isTrue);
      expect(welcomed, isNull, reason: 'no way to make the note was given');
    });
  });
}

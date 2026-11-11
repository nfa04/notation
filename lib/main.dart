import 'dart:async';
import 'dart:io' show Directory;
import 'package:path/path.dart' as p;
import 'data/brush_library.dart';
import 'models/brush_desc.dart';
import 'spelling/spell_service.dart';
import 'images/subject_service.dart';
import 'scan/ocr_service.dart';
import 'shortcuts/shortcut_service.dart';
import 'review/study_planner.dart';
import 'style/accessibility.dart';
import 'templates/templates.dart';
import 'style/refresh_rate.dart';
import 'style/stylus_settings.dart';
import 'lock/note_lock_service.dart';
import 'extensions/extension_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'web/temporary_session.dart';
import 'package:pdfrx/pdfrx.dart' show pdfrxFlutterInitialize;
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/language.dart';

import 'data/app_database.dart';
import 'data/bookmark_repository.dart';
import 'sync/calendar_access.dart';
import 'capture/capture_service.dart';
import 'review/weekly_review.dart' show ReviewEvent;
import 'review/weekly_review_service.dart';
import 'data/audio_repository.dart';
import 'data/card_repository.dart';
import 'data/link_repository.dart';
import 'data/reminder_repository.dart';
import 'reminders/local_notification_sink.dart';
import 'reminders/reminder_service.dart';
import 'data/tag_repository.dart';
import 'collab/network_watch.dart';
import 'collab/webrtc_transport.dart' show RtcChannel;
import 'collab/cloud_share.dart';
import 'citations/citation_repository.dart';
import 'citations/citation_service.dart';
import 'collab/collab_service.dart';
import 'collab/defaults.dart';
import 'collab/ice_settings.dart';
import 'collab/dropbox_storage.dart';
import 'collab/live_marker.dart';
import 'collab/nextcloud_storage.dart';
import 'collab/share_storage.dart';
import 'collab/oauth.dart';
import 'collab/onedrive_storage.dart';
import 'collab/s3_storage.dart';
import 'data/note_file_service.dart';
import 'data/note_repository.dart';
import 'data/settings_repository.dart';
import 'data/task_repository.dart';
import 'data/style_repository.dart';
import 'automations/automation.dart' show AutomationEvent;
import 'automations/automation_service.dart';
import 'events/event_bus.dart';
import 'nativeshare/native_share_service.dart';
import 'nativeshare/dropbox_shares.dart';
import 'nativeshare/nextcloud_shares.dart';
import 'nativeshare/onedrive_shares.dart';
import 'events/event_sources.dart';
import 'ink/handwriting_service.dart';
import 'ink/glm_ocr_service.dart';
import 'ink/paddle_vl_service.dart';
import 'ink/ink_recognizer.dart' show HandwritingStatus;
import 'ink/math_service.dart';
import 'ai/ai_service.dart';
import 'ai/ai_switch.dart';
import 'ai/openai_provider.dart';
import 'ai/text_provider.dart' show ProviderState;
import 'llm/onnx_acceleration_setting.dart' show applyOnnxAcceleration;
import 'automations/note_sorter.dart';
import 'llm/embedding_service.dart';
import 'llm/llm_service.dart';
import 'llm/onnx_chat_provider.dart';
import 'style/app_theme.dart';
import 'style/platform_look.dart';
import 'widgets/notation_logo.dart' show BrandAccent;
import 'style/style_service.dart';
import 'sync/caldav_remote.dart' show DayEvent;
import 'sync/caldav_service.dart';
import 'sync/task_calendar_mirror.dart';
import 'cloudsync/cloud_sync_service.dart';
import 'devicesync/app_accounts.dart';
import 'devicesync/device_sync_service.dart';
import 'devicesync/live_notes.dart';
import 'devicesync/profile_sync.dart';
import 'devicesync/sync_devices.dart';
import 'devicesync/sync_library.dart';
import 'speech/speech_to_text.dart';
import 'sync/device_calendar_service.dart';
import 'sync/ics_service.dart';
import 'app_services.dart';
import 'screens/main_shell.dart';
import 'screens/share_storage_settings.dart' show storageAccountSection;
import 'history/note_history.dart';
import 'mcp/mcp_notes.dart';
import 'mcp/mcp_service.dart';
import 'mcp/mcp_support.dart';
import 'profile/user_profile.dart';
import 'features/feature.dart';
import 'screens/intro_screen.dart';
import 'screens/intro_look.dart';
import 'screens/intro_models.dart';
import 'templates/welcome_note.dart';
import 'legal/bundled_licenses.dart';
import 'web/web_files_io.dart' if (dart.library.js_interop) 'web/web_files_web.dart';
import 'data/app_secure_storage.dart';
import 'net/extra_roots.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await trustBundledRoots(); // (Windows: before the first request, see there)
  await warmUpSecureStorage(); // (before anything writes to the keystore: see there)
  await wipeEndedTemporarySession(); // (a browser whose temporary session was closed forgets it before anything is opened)
  registerBundledLicenses();
  // errors go to the log in a release build too (adb logcat -s flutter), and a widget that fails says why instead of going blank
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    if (kReleaseMode) debugPrint('${details.exceptionAsString()}\n${details.stack}');
  };
  ErrorWidget.builder = (details) => Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text('Something went wrong here:\n${details.exceptionAsString()}', style: const TextStyle(color: Colors.red, fontSize: 12)),
        ),
      );
  // a future nobody waits for that fails ends up here: it is logged, and the app goes on
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Unhandled error: $error\n$stack');
    return true;
  };
  try {
    final setUp = Stopwatch()..start();
    await _start();
    // (in the log of a release build too: how long the app took to be ready, on a device that is not a fast desktop)
    debugPrint('The app was set up in ${setUp.elapsedMilliseconds} ms');
  } catch (e, stack) {
    // (the database would not open, a service would not load: say so, instead of a window that stays empty)
    debugPrint('The app could not start: $e\n$stack');
    runApp(_StartFailed(error: '$e'));
  }
}

/// Shown when the app could not start (see [main]).
class _StartFailed extends StatelessWidget {
  final String error;

  const _StartFailed({required this.error});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Notation',
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline, size: 40),
                      const SizedBox(height: 16),
                      Text('Notation could not start', style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      const Text('Nothing was deleted. Close the app and open it again; if this keeps happening, '
                          'make sure the device has free storage and that this is not an older version of the app than the one that last ran.'),
                      const SizedBox(height: 16),
                      SelectableText(error, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

/// Loads a part of the app that keeps its secrets in the system's keystore. Without a keystore (a desktop with no keyring running, say)
/// the part stays off for this run, as if it had never been set up, and nothing of it is written; the notes must open all the same.
Future<void> _withKeystore(String part, Future<void> load) => load.catchError((Object e) => debugPrint('$part stays off, its secrets could not be read: $e'));

/// Opens the database, makes the services and starts the app.
Future<void> _start() async {
  installWebFiles(); // (on the web: files that live in memory; elsewhere: nothing)
  // (the PDF engine of the web is a WebAssembly module that has to be loaded before any PDF is opened; elsewhere the widgets do it)
  if (kIsWeb) await pdfrxFlutterInitialize();
  AppDatabase.initFfi();
  final db = await AppDatabase.open();
  if (kIsWeb) await keepWebFiles(db); // (puts back the PDFs and pictures that were kept in the browser)
  final tasks = TaskRepository(db);
  final settings = SettingsRepository(db);
  // (a brush that comes with a line in a live session is kept, so that the line looks right after a restart)
  CustomBrushes.keeper = BrushLibrary(settings).keep;
  // the language first: what the services say while they load is in it
  AppLanguage.instance = AppLanguage(settings);
  await AppLanguage.instance.load();
  final caldav = CalDavService(settings, tasks);
  final device = DeviceCalendarService.forPlatform(settings);
  final ics = IcsCalendarService(db);
  final speech = SpeechToText(settings: settings);
  final appTheme = AppTheme(settings);
  final accessibility = AccessibilitySettings(settings);
  final stylus = StylusSettings(settings);
  final shortcuts = ShortcutService(settings);
  final style = StyleService(StyleRepository(db), settings, appTheme);
  final math = MathService(readSetting: settings.get, writeSetting: settings.set);
  final repository = NoteRepository(db);
  unawaited(applyRefreshRate(settings.get)); // (on Android: the fast rate of the screen, if it was asked for)
  await applyOnnxAcceleration(settings.get); // (cpu only, if the person chose that)
  final history = NoteHistory(db, repository)..start();
  // who the person is (a name and an id of their own), and which tools they want
  final profile = UserProfile(settings.get, settings.set);
  final features = FeatureSettings(settings.get, settings.set);
  final spell = SpellService(settings.get, settings.set);
  final citations = CitationService(
    CitationRepository(settings, legacy: db),
    enabled: () => features.on(Feature.citations),
    // the folders a note is in, nearest first, for the style a folder chooses
    folderChain: (noteId) async {
      final folders = {for (final f in await repository.listFolders()) f.id: f.parentId};
      final chain = <String>[];
      for (var id = (await repository.noteInfo(noteId))?.folderId; id != null && !chain.contains(id); id = folders[id]) {
        chain.add(id);
      }
      return chain;
    },
    // where each source is cited, for the library
    citedIn: (isSource) async {
      final titles = {for (final n in await repository.listNotes()) n.id: n.title};
      final out = <String, List<NoteRef>>{};
      for (final e in (await repository.knowledge.noteCitations(isSource: isSource)).entries) {
        for (final key in e.value) {
          (out[key] ??= []).add((id: e.key, title: titles[e.key] ?? ''));
        }
      }
      return out;
    },
  );
  await citations.load();
  final ocr = OcrService(settings.get, settings.set);
  final handwriting = HandwritingService(paddle: PaddleVlService(), glm: GlmOcrService(), readSetting: settings.get, writeSetting: settings.set);
  final subject = SubjectService();
  final events = EventBus();
  final extensions = ExtensionService(settings.get, settings.set, bus: events, addTask: (title, due) async {
    await tasks.createTask(title, dueDate: due, auto: true);
  });
  final noteFiles = NoteFileService(repository);
  // sound kept with notes lives beside the pictures; it travels in a note's file, and an encrypted note leaves none of it lying about
  final audio = AudioRepository(db, root: () async => Directory(p.join((await noteFiles.supportDirectory()).path, 'audio')));
  noteFiles.audio = audio;
  unawaited(audio.purgeOrphans().catchError((Object _) => 0));
  final locks = NoteLockService(repository, noteFiles, onSealed: (id) async {
    await history.forgetNote(id);
    await audio.removeAllFor(id);
  });
  final s3 = S3Storage(settings);
  // services that need an app registration: always listed; the registration is the build's (collab/defaults.dart)
  // or one the person enters in the settings
  final dropbox = DropboxStorage(appKey: dropboxAppKey, fullAccess: dropboxFullAccess, settings: settings);
  final onedrive = OneDriveStorage(clientId: oneDriveClientId, settings: settings);
  final oauthStorages = <OAuthShareStorage>[dropbox, onedrive];
  // the relay for connections that cannot be made directly (a mobile network, say); per device, the password in the keystore
  final ice = IceSettings(settings: settings, secret: const KeystoreSecretStore(appSecureStorage, 'ice_relay'));
  final llm = LlmService();
  final embeddings = EmbeddingService(settings: settings);
  final summaryModel = OnnxChatProvider(settings: settings);
  final cloudModel = OpenAiProvider(settings: settings, secret: const KeystoreSecretStore(appSecureStorage, 'ai_openai_key'));
  final aiSwitch = AiSwitch(settings);
  // what each of these keeps (settings, model files, the keystore) is read at the same time: none of them needs another to start
  await Future.wait([
    _withKeystore('The calendar account', caldav.load()),
    device.load(),
    ics.load(),
    speech.load(),
    appTheme.load(),
    accessibility.load(),
    stylus.load(),
    shortcuts.load(),
    style.load(),
    handwriting.load(),
    math.load(),
    profile.load(),
    features.load(),
    spell.load(),
    ocr.load(),
    subject.load(),
    extensions.load(),
    BrushLibrary(settings).load(),
    _withKeystore('The S3 storage', s3.load()),
    for (final s in oauthStorages) _withKeystore(s.label, s.load()),
    _withKeystore('The relay for connections', ice.load()),
    llm.load(),
    embeddings.load(),
    summaryModel.load(),
    _withKeystore('The AI provider in the cloud', cloudModel.load()),
    aiSwitch.load(),
  ]);
  final mirror = TaskCalendarMirror(settings, tasks, caldav: caldav, device: device);
  await mirror.load();
  caldav.addListener(mirror.runSoon); // after a sync: what came from the server may be due
  mirror.runSoon();
  final nextcloud = NextcloudStorage(caldav, settings: settings);
  final shareStorages = <ShareStorage>[nextcloud, s3, ...oauthStorages];
  final collab = CollabService(repository, ice: ice);
  final share = CloudShare(noteFiles, shareStorages, markers: LiveMarkers(shareStorages, const KeystoreSecretStore(appSecureStorage, 'live_markers')));
  await _withKeystore('The markers of live sessions', share.markers.load());
  // the copies up there are kept up to date with the note
  share.markers
    ..editedOf = ((id) async => (await repository.noteTimes(id))?.edited)
    ..exportOf = noteFiles.exportBytes;
  collab.attachShare(share);
  collab.history = history;
  collab.useProfile(profile);
  await _withKeystore('The live sessions', collab.load());
  CloudSyncService? cloudSync;
  NativeShareService? nativeSharesRef;
  final sync = DeviceSyncService(
    settings: settings,
    keys: const KeystoreSyncKeys(),
    library: SyncLibrary(db, repository, noteFiles, settings),
    profile: ProfileSync(profile),
    serverOf: () => collab.server,
    iceServers: () => ice.servers,
    changes: repository.changes,
    accounts: AppAccounts(settings: settings, caldav: caldav, s3: s3, dropbox: dropbox, onedrive: onedrive),
    onSettingsChanged: () {
      // what a sync changed is read again where it is held in memory
      profile.load();
      appTheme.load();
      accessibility.load();
      stylus.load();
      AppLanguage.instance.load();
      features.load();
      citations.load();
      cloudSync?.load();
      nativeSharesRef?.load();
    },
  );
  sync.cloud = cloudSync = CloudSyncService(
    settings,
    sync,
    [
      CloudProvider(id: 'nextcloud', label: 'Nextcloud', available: () => nextcloud.available, folderFor: nextcloud.folderFor, changes: nextcloud,
      setup: (_) => storageAccountSection(nextcloud),),
      CloudProvider(id: 's3', label: tr('S3 storage'), available: () => s3.available, folderFor: s3.folderFor, changes: s3,
      setup: (_) => storageAccountSection(s3),),
      for (final o in oauthStorages)
        CloudProvider(
          id: o.redirectName,
          label: o.label,
          available: () => o.available,
          folderFor: o.folderFor,
          changes: o,
        setup: (_) => storageAccountSection(o),
        ),
    ],
    changes: repository.changes
  );
  final nativeShares = NativeShareService(
    db: db,
    settings: settings,
    library: sync.library,
    providers: [NextcloudShares(nextcloud), OneDriveShares(onedrive), DropboxShares(dropbox)],
    deviceId: () => sync.deviceId,
    deviceName: () => sync.deviceName,
    changes: repository.changes,
    identity: () => sync.identity,
    serverOf: () => collab.server,
    iceServers: () => ice.servers,
  );
  collab.nativeShares = nativeShares;
  nativeSharesRef = nativeShares;
  final liveNotes = CollabLiveNotes(collab);
  sync.live = liveNotes; // a note that is open on two of the person's devices is worked on live
  nativeShares.live = liveNotes; // and one that is open on a device of someone it is shared with
  await _withKeystore('The sync through a cloud folder', cloudSync.load());
  await _withKeystore('The sync of devices', sync.load());
  await _withKeystore('The shares', nativeShares.load());
  unawaited(nativeShares.refreshIncoming());
  // a move to another network (mobile network to Wi-Fi) ends every direct connection at once: new ones are made right away, instead of
  // waiting for the old ones to time out
  NetworkWatch.guarded(() => Connectivity().onConnectivityChanged.map((kinds) => {for (final k in kinds) k.name}), () {
    RtcChannel.dropAll();
    collab.wake();
    sync.wake();
    nativeShares.wake(); // (and the rooms of the shares the person works on live)
  });
  final cards = CardRepository(db);
  final tags = TagRepository(db);
  final planner = StudyPlanner(settings, cards, tasks);
  await planner.load();
  planner.start();
  final capture = CaptureService(repository: repository, supportDirectory: noteFiles.supportDirectory)
    ..onCaptured = (c) async {
      final info = await repository.noteInfo(c.noteId);
      await events.emit(AppEvent(AutomationEvent.captureReceived.name,
          noteId: c.noteId, title: c.title, folderId: info?.folderId, data: eventVars({'kind': c.kind, 'url': c.url, 'site': c.site})));
    };
  final reminders = ReminderService(reminders: ReminderRepository(db), tasks: tasks, sink: LocalNotificationSink(), read: settings.get, write: settings.set);
  final ai = AiService(settings: settings, providers: [summaryModel, cloudModel]);
  await ai.load();
  // turning AI off also lets go of the models in memory
  aiSwitch.addListener(() {
    if (!aiSwitch.enabled) {
      llm.unload();
      summaryModel.unload();
      embeddings.unload();
    }
  });
  final automations = AutomationService(
    repository,
    tasks,
    noteFiles: noteFiles,
    sorter: NoteSorter(repository, embeddings, ready: () => aiSwitch.enabled && embeddings.installed),
    smartTitle: (text) => aiSwitch.enabled ? llm.shortTitle(text) : Future.value(null),
    readInk: (strokes) => aiSwitch.enabled ? handwriting.recognize(strokes) : throw StateError('The AI features are turned off.'),
    inkReady: () => aiSwitch.enabled && handwriting.status == HandwritingStatus.installed,
    extensions: extensions,
    ai: ai,
    cards: cards,
    tags: tags,
    citations: citations,
    templates: TemplateService(repository, noteFiles),
    reminders: reminders,
    aiReady: () => aiSwitch.enabled && ai.provider?.state == ProviderState.ready,
    // (a calendar that cannot be read is left out)
    upcomingEvents: (from, to) async {
      final lists = await Future.wait([
        if (caldav.isConnected) caldav.events(from, to).catchError((Object _) => <DayEvent>[]),
        device.events(from, to).catchError((Object _) => <DayEvent>[]),
        ics.events(from, to).catchError((Object _) => <DayEvent>[]),
      ]);
      return [for (final l in lists) for (final e in l) UpcomingEvent(e.title, e.start, allDay: e.allDay, end: e.end, uid: e.uid.isEmpty ? null : e.uid)];
    },
    bus: events,
  );
  await automations.load();
  NoteEventSource(repository, automations.bus).start();
  IdleSource(repository, automations.bus).start();
  ActivitySource(repository, automations.bus, tasks: tasks, audio: audio).start();
  MinuteSource(automations.bus).start();
  TickSource(automations.bus).start();
  nativeShares.onReceived = (s) => automations.bus.emit(AppEvent(AutomationEvent.shareReceived.name, title: s.name, data: {'name': s.name, 'kind': s.kind.name, 'owner': s.owner}));
  final bookmarks = BookmarkRepository(db);
  // an AI agent beside the app can work with the notes, on a computer; the phones' builds leave all of it out
  final mcp = !mcpSupported
      ? null
      : McpService(
          notes: McpNotes(
            repository: repository,
            tasks: tasks,
            tags: tags,
            history: history,
            editorOf: (id) => automations.openEditor?.call(id),
            cards: cards,
            bookmarks: bookmarks,
            calendar: CalendarAccess.of(caldav: caldav, device: device, ics: ics),
            reminders: reminders,
          ),
          read: settings.get,
          write: settings.set,
          secret: const KeystoreSecretStore(appSecureStorage, 'mcp_token'),
        );
  await mcp?.load();
  await reminders.load();
  // (started after the first frame: it talks to the system and must not hold up the app)
  unawaited(reminders.start());
  runApp(NotationApp(
    services: AppServices(
      repository: repository,
      tasks: tasks,
      caldav: caldav,
      device: device,
      ics: ics,
      style: style,
      appTheme: appTheme,
      handwriting: handwriting,
      math: math,
      aiSwitch: aiSwitch,
      automations: automations,
      llm: llm,
      embeddings: embeddings,
      noteFiles: noteFiles,
      collab: collab,
      history: history,
      profile: profile,
      features: features,
      citations: citations,
      spell: spell,
      ocr: ocr,
      subject: subject,
      accessibility: accessibility,
      stylus: stylus,
      shortcuts: shortcuts,
      locks: locks,
      extensions: extensions,
      ai: ai,
      mirror: mirror,
      speech: speech,
      sync: sync,
      cards: cards,
      planner: planner,
      tags: tags,
      bookmarks: bookmarks,
      links: LinkRepository(db),
      reminders: reminders,
      audio: audio,
      capture: capture,
      mcp: mcp,
      review: WeeklyReviewService(
        repository: repository,
        tasks: tasks,
        cards: cards,
        ai: ai,
          aiEnabled: () => aiSwitch.enabled,
        // the week ahead from every calendar there is; one that cannot be read is left out
        events: (from, to) async {
          final lists = await Future.wait([
            if (caldav.isConnected) caldav.events(from, to).catchError((Object _) => <DayEvent>[]),
            device.events(from, to).catchError((Object _) => <DayEvent>[]),
            ics.events(from, to).catchError((Object _) => <DayEvent>[]),
          ]);
          return [for (final l in lists) for (final e in l) ReviewEvent(e.title, e.start, allDay: e.allDay)]..sort((a, b) => a.start.compareTo(b.start));
        },
      ),
    ),
  ));
}

/// The app: the theme, language and accessibility settings around the first screen (the intro, then [MainShellNavigation]).
/// Every service is made in [main] and handed down from here, so tests can build the app with fakes.
class NotationApp extends StatelessWidget {
  final AppServices services;

  const NotationApp({super.key, required this.services});

  AppTheme get appTheme => services.appTheme;
  AccessibilitySettings? get accessibility => services.accessibility;

  ColorScheme _scheme(Brightness b) => accessibility?.scheme(appTheme.accent, b) ?? ColorScheme.fromSeed(seedColor: appTheme.accent, brightness: b);

  /// [t] in the look of the platform (iOS or Material) and then with the accessibility settings, which come last so they win.

  ThemeData _themed(ThemeData t) {
    if (appTheme.look.isIos) t = iosLook(t);
    return accessibility?.theme(t) ?? t;
  }

  @override
  Widget build(BuildContext context) {
    // the accent colour the user picked colours the whole app
    return ListenableBuilder(
      listenable: Listenable.merge([appTheme, AppLanguage.instance, ?accessibility]),
      builder: (context, _) => MaterialApp(
      title: 'Notation',
      locale: AppLanguage.instance.locale,
      supportedLocales: AppLanguage.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        var page = child!;
        if (accessibility != null) page = MediaQuery(data: accessibility!.apply(MediaQuery.of(context)), child: page);
        final citations = services.citations;
        return citations == null ? page : CitationScope(service: citations, child: page);
      },
      theme: _themed(ThemeData(
        useMaterial3: true,
        colorScheme: _scheme(Brightness.light),
            extensions: [BrandAccent(appTheme.accent)],
      )),
      darkTheme: _themed(ThemeData(
        useMaterial3: true,
        colorScheme: _scheme(Brightness.dark),
            extensions: [BrandAccent(appTheme.accent)],
      )),
      home: ListenableBuilder(
        listenable: services.profile ?? appTheme,
        builder: (context, _) {
          final profile = services.profile, features = services.features;
          return profile != null && features != null && !profile.introDone
              // the first time the app opens: a name, what it is used for, the tools
              ? IntroScreen(profile: profile, features: features, sync: services.sync, settings: services.repository.settings, smart: _introSmart(services), look: IntroLook(theme: services.appTheme, stylus: services.stylus), welcome: (tools) => _welcomeNote(services, tools))
              : MainShellNavigation(services: services);
        },
      ),
      ),
    );
  }
}

/// Whether the device is on mobile data only (no Wi-Fi, no cable). A system that cannot tell (Linux without NetworkManager, say) says no.
Future<bool> _onMobileData() async {
  try {
    final kinds = await Connectivity().checkConnectivity();
    return kinds.contains(ConnectivityResult.mobile) && !kinds.contains(ConnectivityResult.wifi) && !kinds.contains(ConnectivityResult.ethernet);
  } catch (_) {
    return false;
  }
}

/// What the intro asks about the AI features: the switch and the models that can be downloaded for them (null: no switch).
IntroSmart? _introSmart(AppServices services) {
  final aiSwitch = services.aiSwitch;
  if (aiSwitch == null) return null;
  return IntroSmart(aiSwitch: aiSwitch, onMobileData: _onMobileData, models: [
    if (services.handwriting != null)
      IntroModel(
        id: 'handwriting',
        title: 'Handwriting to text',
        description: 'Turns what you write by hand into text, to search and copy.',
        icon: Icons.text_snippet_outlined,
        service: services.handwriting!,
        wantedFor: const {Feature.handwriting},
      ),
    if (services.math != null)
      IntroModel(
        id: 'maths',
        title: 'Formulas and maths check',
        description: 'Reads handwritten formulas and marks your working line by line.',
        icon: Icons.rule,
        service: services.math!,
        wantedFor: const {Feature.mathInk, Feature.checkMaths},
      ),
    if (services.llm != null)
      IntroModel(
        id: 'assistant',
        title: 'Assistant',
        description: 'Answers questions about a note and summarises it. A big download, so it is only on if you tick it.',
        icon: Icons.auto_awesome,
        service: services.llm!,
      ),
  ]);
}

/// The note of the intro that shows the tools (it is there in the list when the app opens).
Future<void> _welcomeNote(AppServices services, Set<Feature> tools) async {
  final repository = services.repository;
  final id = await repository.createNote(title: tr('Welcome to Notation'));
  final note = (await repository.loadNote(id))!;
  fillWelcomeNote(note, tools);
  await repository.saveNote(note);
}

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';
import '../sync/caldav_service.dart' show SecretStore;
import 'ai_prompt.dart';
import 'text_provider.dart';
import '../l10n/language.dart';

/// Where a provider of the OpenAI kind is, and what it is asked for. The key is
/// not part of this: it lives in the platform keystore.
class OpenAiConfig {
  /// Up to and including the version, e.g. `https://api.openai.com/v1` or
  /// `http://localhost:11434/v1` (Ollama).
  final String baseUrl;
  final String model;

  /// The least time between the start of one request and the next, in seconds (0: none). For services that limit how many
  /// requests a minute may be made (the free plan of Gemini), where a long job such as the facts of many notes would otherwise be refused.
  final int pauseSeconds;

  const OpenAiConfig({this.baseUrl = defaultBaseUrl, this.model = '', this.pauseSeconds = 0});

  static const maxPauseSeconds = 600;

  static const defaultBaseUrl = 'https://api.openai.com/v1';

  bool get complete => baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  /// The address requests go to.
  Uri get chatUrl {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return Uri.parse(base.endsWith('/chat/completions') ? base : '$base/chat/completions');
  }

  String encode() => jsonEncode({'baseUrl': baseUrl, 'model': model, if (pauseSeconds > 0) 'pause': pauseSeconds});

  static OpenAiConfig decode(String? text) {
    try {
      final m = jsonDecode(text ?? '') as Map<String, dynamic>;
      return OpenAiConfig(
        baseUrl: m['baseUrl'] as String? ?? defaultBaseUrl,
        model: m['model'] as String? ?? '',
        pauseSeconds: ((m['pause'] as num?)?.toInt() ?? 0).clamp(0, maxPauseSeconds),
      );
    } catch (_) {
      return const OpenAiConfig();
    }
  }
}

/// One of the services the person has set up: a name to pick it by, and where it is and what it is asked for. The key is in the keystore
/// under the id.
class OpenAiProfile {
  final String id;
  final String name;
  final OpenAiConfig config;

  const OpenAiProfile(this.id, this.name, this.config);

  /// The name, or the host of the address when none was given.
  String get title {
    if (name.trim().isNotEmpty) return name.trim();
    final host = Uri.tryParse(config.baseUrl.trim())?.host ?? '';
    return host.isEmpty ? 'New provider' : host;
  }

  OpenAiProfile copyWith({String? name, OpenAiConfig? config}) => OpenAiProfile(id, name ?? this.name, config ?? this.config);

  Map<String, Object?> toJson() => {'id': id, 'name': name, ...jsonDecode(config.encode()) as Map<String, dynamic>};

  static OpenAiProfile? fromJson(Object? m) {
    if (m is! Map || m['id'] is! String) return null;
    return OpenAiProfile(m['id'] as String, m['name'] as String? ?? '', OpenAiConfig.decode(jsonEncode(m)));
  }
}

class _MemorySecret implements SecretStore {
  String? _v;
  @override
  Future<String?> read() async => _v;
  @override
  Future<void> write(String value) async => _v = value;
  @override
  Future<void> delete() async => _v = null;
}

/// Sends a request and gives the body of the answer as it arrives. Throws on an
/// answer that is not a success, with what the server said. Tests pass a fake.
typedef OpenAiTransport = Stream<String> Function(Uri url, Map<String, String> headers, String body, AiCancel? cancel);

/// Any service that speaks the OpenAI chat API (`/chat/completions`): OpenAI
/// itself, OpenRouter, Groq, or a server of your own such as Ollama, LM Studio or
/// vLLM. The text to summarize goes to the address set here and nowhere else.
class OpenAiProvider extends ChangeNotifier implements TextModelProvider, ContextSized, ToolCalling {
  static const _configKey = 'ai_openai_config'; // before there were several: becomes the first profile
  static const _profilesKey = 'ai_openai_profiles';

  /// The id of the profile that was the only one before there were several (its key is [_secret]).
  static const firstProfileId = 'default';

  final SettingsRepository? _settings;
  final SecretStore _secret;
  final OpenAiTransport _send;
  final Future<void> Function(Duration) _sleep;
  final Future<String> Function(Uri url, Map<String, String> headers) _get;
  final SecretStore Function(String profileId) _secretFor;
  final Map<String, SecretStore> _secrets = {};

  /// [secretFor] gives the place of the key of any profile but the first (the keystore, in the app).
  /// [sleep] waits (it is told to wait and nothing else; tests pass one that does not take the time).
  OpenAiProvider({SettingsRepository? settings, required SecretStore secret, OpenAiTransport? transport, Future<void> Function(Duration)? sleep, Future<String> Function(Uri url, Map<String, String> headers)? get, SecretStore Function(String profileId)? secretFor})
      : _get = get ?? _dioGet,
        _secretFor = secretFor ?? ((_) => _MemorySecret()),
        _settings = settings,
        _secret = secret,
        _send = transport ?? _dioTransport,
        _sleep = sleep ?? Future.delayed;

  /// How often a request that the service turned away as too many (429) is tried again, and the longest wait that is worth it:
  /// a quota that comes back tomorrow is not waited for.
  static const _retries = 3;
  static const _longestWait = Duration(seconds: 90);

  // Requests start one after the other, at least the configured pause apart.
  Future<void> _gate = Future.value();
  DateTime? _lastStart;

  Future<void> _waitOurTurn(AiCancel? cancel) async {
    final before = _gate;
    final mine = Completer<void>();
    _gate = mine.future;
    try {
      await before;
      final pause = Duration(seconds: config.pauseSeconds);
      final last = _lastStart;
      if (last != null && pause > Duration.zero) {
        final wait = pause - DateTime.now().difference(last);
        if (wait > Duration.zero) await _waitCancellable(wait, cancel);
      }
      _lastStart = DateTime.now();
    } finally {
      mine.complete();
    }
  }

  /// Waits [wait], in pieces so that a stop is noticed.
  Future<void> _waitCancellable(Duration wait, AiCancel? cancel) async {
    var left = wait;
    while (left > Duration.zero && !(cancel?.cancelled ?? false)) {
      final step = left < const Duration(seconds: 1) ? left : const Duration(seconds: 1);
      await _sleep(step);
      left -= step;
    }
  }

  List<OpenAiProfile> _profiles = [const OpenAiProfile(firstProfileId, '', OpenAiConfig())];
  String _activeId = firstProfileId;
  final Map<String, String> _keys = {};

  OpenAiProfile get _active => _profiles.firstWhere((p) => p.id == _activeId, orElse: () => _profiles.first);

  /// Every service that is set up, and the one that answers.
  List<OpenAiProfile> get profiles => List.unmodifiable(_profiles);
  OpenAiProfile get activeProfile => _active;

  /// The address, model and pause of the service that answers.
  OpenAiConfig get config => _active.config;
  String get _key => _keys[_active.id] ?? '';
  bool get hasKey => _key.isNotEmpty;
  bool profileHasKey(String id) => (_keys[id] ?? '').isNotEmpty;

  /// For the form: a key left empty there keeps this one.
  String get currentKey => _key;

  SecretStore _secretOf(String id) => id == firstProfileId ? _secret : _secrets.putIfAbsent(id, () => _secretFor(id));

  Future<void> load() async {
    _keys.clear();
    final saved = await _settings?.get(_profilesKey);
    final list = <OpenAiProfile>[];
    var active = '';
    try {
      final m = jsonDecode(saved ?? '') as Map<String, dynamic>;
      active = m['active'] as String? ?? '';
      for (final j in (m['profiles'] as List? ?? const [])) {
        final p = OpenAiProfile.fromJson(j);
        if (p != null && list.every((q) => q.id != p.id)) list.add(p);
      }
    } catch (_) {}
    if (list.isEmpty) {
      // what was saved before there were several
      list.add(OpenAiProfile(firstProfileId, '', OpenAiConfig.decode(await _settings?.get(_configKey))));
    }
    _profiles = list;
    _activeId = list.any((p) => p.id == active) ? active : list.first.id;
    for (final p in _profiles) {
      _keys[p.id] = await _secretOf(p.id).read() ?? '';
    }
    notifyListeners();
  }

  Future<void> _persist() => _settings?.set(_profilesKey, jsonEncode({'active': _activeId, 'profiles': [for (final p in _profiles) p.toJson()]})) ?? Future.value();

  Future<void> _writeKey(String id, String key) => key.isEmpty ? _secretOf(id).delete() : _secretOf(id).write(key);

  /// Saves the address and model, and the key (an empty one is deleted; many
  /// servers on your own machine need none), of the service that answers. [name] renames it.
  Future<void> save(OpenAiConfig config, String key, {String? name, String? id}) async {
    id ??= _active.id;
    if (_profiles.every((p) => p.id != id)) return;
    final clean = OpenAiConfig(baseUrl: config.baseUrl.trim(), model: config.model.trim(), pauseSeconds: config.pauseSeconds.clamp(0, OpenAiConfig.maxPauseSeconds));
    _profiles = [for (final p in _profiles) p.id == id ? p.copyWith(name: name?.trim(), config: clean) : p];
    _keys[id] = key.trim();
    notifyListeners();
    await _persist();
    await _writeKey(id, _keys[id]!);
  }

  /// Makes [id] the service that answers.
  Future<void> selectProfile(String id) async {
    if (id == _activeId || _profiles.every((p) => p.id != id)) return;
    _activeId = id;
    notifyListeners();
    await _persist();
  }

  String keyOf(String id) => _keys[id] ?? '';

  /// A new, empty service, which answers from now on (it is filled in at once).
  /// (The one empty service that exists before anything is set up is filled in instead of being left empty beside the new one.)
  Future<OpenAiProfile> addProfile([String name = '']) async {
    final only = _profiles.length == 1 ? _profiles.first : null;
    if (only != null && only.name.isEmpty && only.config.model.isEmpty && !profileHasKey(only.id)) {
      _activeId = only.id;
      return only;
    }
    var id = 'p${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    while (_profiles.any((p) => p.id == id)) {
      id += 'x';
    }
    final profile = OpenAiProfile(id, name.trim(), const OpenAiConfig());
    _profiles = [..._profiles, profile];
    _keys[id] = '';
    _activeId = id;
    notifyListeners();
    await _persist();
    return profile;
  }

  /// Removes a service and its key. The last one is not removed but emptied.
  Future<void> removeProfile(String id) async {
    if (_profiles.every((p) => p.id != id)) return;
    await _writeKey(id, '');
    _keys.remove(id);
    if (_profiles.length == 1) {
      _profiles = [OpenAiProfile(id, '', const OpenAiConfig())];
      _keys[id] = '';
    } else {
      _profiles = [for (final p in _profiles) if (p.id != id) p];
      if (_activeId == id) _activeId = _profiles.first.id;
    }
    notifyListeners();
    await _persist();
  }

  List<String>? _models;
  String? _modelsFor; // the address and key the list was read with

  /// Every model the service offers (`GET <address>/models`), the last list kept until the address or key changes
  /// ([refresh]: ask again). Throws with what went wrong.
  Future<List<String>> listModels({bool refresh = false}) async {
    final stamp = '${config.baseUrl.trim()}|$_key';
    if (!refresh && _models != null && _modelsFor == stamp) return _models!;
    final ids = await listModelsAt(config.baseUrl, _key);
    _models = ids;
    _modelsFor = stamp;
    return ids;
  }

  /// The models of any address with any key (the form that is not saved yet).
  Future<List<String>> listModelsAt(String baseUrl, String key) async {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/chat/completions')) base = base.substring(0, base.length - '/chat/completions'.length);
    final body = await _get(Uri.parse('$base/models'), {
      'Accept': 'application/json',
      if (key.trim().isNotEmpty) 'Authorization': 'Bearer ${key.trim()}',
    });
    final json = jsonDecode(body);
    final list = json is Map ? (json['data'] ?? json['models']) : json;
    return <String>{
      for (final m in (list as List? ?? const []))
        if (m is Map && (m['id'] ?? m['name']) is String) ((m['id'] ?? m['name']) as String).replaceFirst(RegExp(r'^models/'), '') else if (m is String) m,
    }.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Asks a short question with a form that is not saved (nothing is kept), and gives the answer; throws what went wrong.
  Future<String> tryOut(OpenAiConfig config, String key) async {
    final probe = OpenAiProvider(secret: _MemorySecret(), transport: _send, sleep: _sleep, get: _get);
    await probe.save(config, key);
    return probe.complete(const AiPrompt(system: 'Answer in one short sentence.', user: 'Say that the connection works.'), maxTokens: 30);
  }

  /// Switches to [model] and keeps everything else as it is.
  Future<void> selectModel(String model) =>
      save(OpenAiConfig(baseUrl: config.baseUrl, model: model, pauseSeconds: config.pauseSeconds), _key);

  static Future<String> _dioGet(Uri url, Map<String, String> headers) async {
    try {
      final r = await Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(seconds: 30)))
          .getUri<String>(url, options: Options(headers: headers, responseType: ResponseType.plain, validateStatus: (_) => true));
      final status = r.statusCode ?? 0;
      if (status < 200 || status >= 300) throw StateError(_explain(status, r.data ?? ''));
      return r.data ?? '';
    } on DioException catch (e) {
      throw StateError(tr('Could not reach {host}: {error}', {'host': url.host, 'error': e.message ?? e.error ?? e.type.name}));
    }
  }

  @override
  String get id => 'openai-compatible';

  @override
  String get label => 'OpenAI-compatible service';

  @override
  String get description =>
      'OpenAI, OpenRouter, Groq, or your own server (Ollama, LM Studio, vLLM...). The highlighted text is sent '
      'to the address you set below.';

  /// Services of this kind take long texts (and charge by the token): about 12 000 tokens.
  @override
  int get contextChars => 48000;

  @override
  ProviderState get state => config.complete ? ProviderState.ready : ProviderState.unavailable;

  @override
  String? get reason => config.complete ? null : 'Set the address and the model name below.';

  @override
  Future<void> prepare() async {}

  @override
  Future<String> complete(
    AiPrompt prompt, {
    int maxTokens = 256,
    void Function(String partial)? onPartial,
    AiCancel? cancel,
  }) async {
    return (await _complete(prompt, const [], maxTokens, onPartial, cancel)).text;
  }

  @override
  Future<AiToolReply> completeWithTools(
    AiPrompt prompt,
    List<AiToolSpec> tools, {
    int maxTokens = 256,
    void Function(String partial)? onPartial,
    AiCancel? cancel,
  }) =>
      _complete(prompt, tools, maxTokens, onPartial, cancel);

  Future<AiToolReply> _complete(AiPrompt prompt, List<AiToolSpec> tools, int maxTokens, void Function(String)? onPartial, AiCancel? cancel) async {
    if (!config.complete) throw StateError(reason!);
    if (cancel?.cancelled ?? false) return const AiToolReply('');
    try {
      return await _paced(prompt, tools, 'max_tokens', maxTokens, onPartial, cancel);
    } on _Refused catch (e) {
      // newer OpenAI models want another name for the limit
      if (e.message.contains('max_completion_tokens')) {
        return _paced(prompt, tools, 'max_completion_tokens', maxTokens, onPartial, cancel);
      }
      // (a model that cannot take tools says so: the caller then asks for the calls as text instead)
      if (tools.isNotEmpty && RegExp(r'\b(tools?|functions?)\b', caseSensitive: false).hasMatch(e.message) && e.message.contains('400')) {
        throw ToolsNotSupported(e.message);
      }
      throw StateError(e.message);
    }
  }

  /// [_ask] after the pause that is set, and again (after what the service says to wait, or a growing wait) when it answers 429.
  Future<AiToolReply> _paced(AiPrompt prompt, List<AiToolSpec> tools, String limitName, int maxTokens, void Function(String)? onPartial, AiCancel? cancel) async {
    for (var attempt = 0;; attempt++) {
      await _waitOurTurn(cancel);
      if (cancel?.cancelled ?? false) return const AiToolReply('');
      try {
        return await _ask(prompt, tools, limitName, maxTokens, onPartial, cancel);
      } on _Refused catch (e) {
        if (e.status != 429 || attempt >= _retries) rethrow;
        final wait = e.retryAfter ?? Duration(seconds: 5 << attempt); // 5, 10, 20 s when the service does not say
        if (wait > _longestWait) rethrow;
        await _waitCancellable(wait + const Duration(milliseconds: 500), cancel);
        if (cancel?.cancelled ?? false) return const AiToolReply('');
      }
    }
  }

  /// What Gemini may think on top of the answer: its thinking counts against the
  /// limit, and without room for it answers are cut short or empty.
  static const _geminiThinking = 2048;

  /// The conversation as the service wants it: what the assistant asked of tools and what the tools answered keep their form.
  static List<Map<String, Object?>> _messages(AiPrompt prompt) => [
        {'role': 'system', 'content': prompt.system},
        for (final turn in prompt.history)
          if (turn.resultOf != null)
            {'role': 'tool', 'tool_call_id': turn.resultOf, 'content': turn.text}
          else if (turn.calls.isNotEmpty)
            {
              'role': 'assistant',
              'content': turn.text.isEmpty ? null : turn.text,
              'tool_calls': [
                for (final c in turn.calls)
                  {
                    'id': c.id,
                    'type': 'function',
                    'function': {'name': c.name, 'arguments': jsonEncode(c.args)},
                    if (c.extra != null) 'extra_content': c.extra,
                  },
              ],
            }
          else
            {'role': turn.fromUser ? 'user' : 'assistant', 'content': turn.text},
        if (prompt.user.isNotEmpty) {'role': 'user', 'content': prompt.user},
      ];

  Future<AiToolReply> _ask(AiPrompt prompt, List<AiToolSpec> tools, String limitName, int maxTokens, void Function(String)? onPartial, AiCancel? cancel) async {
    // Google AI Studio: Gemini thinks before it answers (unseen, and nothing comes meanwhile), so it is asked to think little
    final gemini = config.chatUrl.host == 'generativelanguage.googleapis.com';
    final body = jsonEncode({
      'model': config.model,
      'stream': true,
      limitName: gemini ? maxTokens + _geminiThinking : maxTokens,
      if (gemini) 'reasoning_effort': 'low',
      'messages': _messages(prompt),
      if (tools.isNotEmpty)
        'tools': [
          for (final t in tools)
            {
              'type': 'function',
              'function': {'name': t.name, 'description': t.description, if (t.parameters != null) 'parameters': t.parameters},
            },
        ],
    });
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream, application/json',
      if (_key.isNotEmpty) 'Authorization': 'Bearer $_key',
    };
    final text = StringBuffer();
    final other = StringBuffer(); // an answer that is not a stream: one JSON document
    var pending = '';
    // the calls come in pieces (a name, then the arguments bit by bit), by their place in the list
    final pieces = <int, ({String id, StringBuffer name, StringBuffer args, Object? extra})>{};

    void collect(List calls) {
      for (final raw in calls.whereType<Map>()) {
        final at = (raw['index'] as num?)?.toInt() ?? pieces.length;
        final fn = raw['function'] as Map?;
        final p = pieces[at] ??= (id: '', name: StringBuffer(), args: StringBuffer(), extra: null);
        final id = raw['id'] is String && (raw['id'] as String).isNotEmpty ? raw['id'] as String : p.id;
        pieces[at] = (id: id, name: p.name..write(fn?['name'] ?? ''), args: p.args..write(fn?['arguments'] ?? ''), extra: raw['extra_content'] ?? p.extra);
      }
    }

    void line(String l) {
      if (!l.startsWith('data:')) {
        other.writeln(l);
        return;
      }
      final data = l.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') return;
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final choices = json['choices'] as List?;
        final delta = (choices == null || choices.isEmpty ? null : (choices.first as Map)['delta']) as Map?;
        if (choices != null && choices.isNotEmpty && (choices.first as Map)['finish_reason'] == 'length') cancel?.cutOff = true;
        final piece = delta?['content'];
        if (piece is String && piece.isNotEmpty) {
          text.write(piece);
          onPartial?.call(_withoutThinking(text.toString()));
        }
        if (delta?['tool_calls'] is List) collect(delta!['tool_calls'] as List);
      } catch (_) {} // a keep-alive or something we do not know
    }

    try {
      await for (final chunk in _send(config.chatUrl, headers, body, cancel)) {
        if (cancel?.cancelled ?? false) break;
        pending += chunk;
        final lines = pending.split('\n');
        pending = lines.removeLast();
        lines.map((l) => l.trimRight()).where((l) => l.isNotEmpty).forEach(line);
      }
    } on DioException catch (e) {
      throw _Refused(tr('Could not reach {host}: {error}', {'host': config.chatUrl.host, 'error': e.message ?? e.error ?? e.type.name}));
    }
    if (pending.trim().isNotEmpty) line(pending.trim());

    if (text.isEmpty && other.isNotEmpty) {
      try {
        final json = jsonDecode(other.toString()) as Map<String, dynamic>;
        final choice = (json['choices'] as List).first as Map;
        if (choice['finish_reason'] == 'length') cancel?.cutOff = true;
        final message = choice['message'] as Map;
        final content = message['content'];
        if (content is String) text.write(content);
        if (message['tool_calls'] is List) collect(message['tool_calls'] as List);
      } catch (_) {}
    }
    final calls = [
      for (final e in (pieces.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
        _callOf(e.key, e.value.id, e.value.name.toString(), e.value.args.toString(), e.value.extra),
    ];
    return AiToolReply(_withoutThinking(text.toString()).trim(), calls);
  }

  /// A call as the model wrote it; arguments that are not a JSON object are kept as an error for the model to be told.
  static AiToolCall _callOf(int at, String id, String name, String arguments, Object? extra) {
    final callId = id.isEmpty ? 'call_$at' : id;
    if (arguments.trim().isEmpty) return AiToolCall(callId, name, const {}, extra: extra);
    try {
      final args = jsonDecode(arguments);
      if (args is Map) return AiToolCall(callId, name, args.cast<String, Object?>(), extra: extra);
    } catch (_) {}
    return AiToolCall(callId, name, const {}, error: 'The arguments were not a JSON object.', extra: extra);
  }

  /// Models that think aloud put it in `<think>` tags; it is not part of the answer.
  static String _withoutThinking(String s) {
    var out = s.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');
    final open = out.indexOf('<think>');
    if (open >= 0) out = out.substring(0, open); // still thinking
    return out.trimLeft();
  }

  static Stream<String> _dioTransport(Uri url, Map<String, String> headers, String body, AiCancel? cancel) async* {
    final token = CancelToken();
    final response = await Dio(BaseOptions(connectTimeout: const Duration(seconds: 20))).postUri<ResponseBody>(
      url,
      data: body,
      cancelToken: token,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
        receiveTimeout: const Duration(minutes: 5),
        sendTimeout: const Duration(seconds: 30),
      ),
    );
    final stream = response.data!.stream.cast<List<int>>().transform(utf8.decoder);
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      final text = await stream.join();
      throw _Refused(_explain(status, text), status: status, retryAfter: status == 429 ? _retryAfter(response.headers.value('retry-after'), text) : null);
    }
    await for (final chunk in stream) {
      if (cancel?.cancelled ?? false) {
        token.cancel();
        return;
      }
      yield chunk;
    }
  }

  /// How long a 429 says to wait: the `Retry-After` header (seconds), or what Gemini writes in the answer ("retryDelay": "12s",
  /// "Please retry in 12.5s"). Null when it says nothing.
  @visibleForTesting
  static Duration? retryAfterOf(String? header, String body) => _retryAfter(header, body);

  static Duration? _retryAfter(String? header, String body) {
    final seconds = double.tryParse(header?.trim() ?? '');
    if (seconds != null && seconds >= 0) return Duration(milliseconds: (seconds * 1000).round());
    final m = RegExp(r'retryDelay"?\s*:\s*"([\d.]+)s"').firstMatch(body) ?? RegExp(r'retry in ([\d.]+)\s*s', caseSensitive: false).firstMatch(body);
    final found = double.tryParse(m?.group(1) ?? '');
    return found == null ? null : Duration(milliseconds: (found * 1000).round());
  }

  static String _explain(int status, String body) {
    var detail = body.trim();
    try {
      final error = (jsonDecode(body) as Map)['error'];
      detail = error is Map ? '${error['message']}' : '$error';
    } catch (_) {}
    if (detail.length > 300) detail = '${detail.substring(0, 300)}...';
    final hint = switch (status) {
      401 || 403 => tr(' (is the key right?)'),
      404 => tr(' (is the address or the model name right?)'),
      429 => tr(' (too many requests, or no credit left)'),
      _ => '',
    };
    return tr('The service answered {status}{hint}: {detail}', {'status': status, 'hint': hint, 'detail': detail});
  }
}

/// A refusal by the server, with what it said.
class _Refused implements Exception {
  final String message;

  /// The HTTP status, and for 429 how long the service said to wait (when it did).
  final int? status;
  final Duration? retryAfter;
  _Refused(this.message, {this.status, this.retryAfter});
  @override
  String toString() => message;
}

/// For tests and for transports that want to refuse the same way.
@visibleForTesting
Exception refusal(String message, {int? status, Duration? retryAfter}) => _Refused(message, status: status, retryAfter: retryAfter);

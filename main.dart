import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'mqtt_client_factory_native.dart'
    if (dart.library.html) 'mqtt_client_factory_web.dart';
import 'update_service.dart';
import 'firmware_ota_service.dart';

void main() {
  runApp(const GepVezerloApp());
}

/* ============================================================
   COLORS
   ============================================================ */
class AppColors {
  static const bg = Color(0xFF0A0B10);
  static const bg2 = Color(0xFF0E1016);
  static const card = Color(0xFF151821);
  static const card2 = Color(0xFF1C2030);
  static const border = Color(0x12FFFFFF);
  static const borderStrong = Color(0x1CFFFFFF);
  static const teal = Color(0xFF5EF2C7);
  static const orange = Color(0xFFFFB347);
  static const red = Color(0xFFFF5A5F);
  static const green = Color(0xFF2ECC71);
  static const purple = Color(0xFFA87CFF);
  static const blue = Color(0xFF5B8DEF);
  static const yellow = Color(0xFFFFE08A);
  static const textMuted = Color(0x8CFFFFFF);
  static const textMuted2 = Color(0x59FFFFFF);
}

/* ============================================================
   APP
   ============================================================ */
class GepVezerloApp extends StatelessWidget {
  const GepVezerloApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Gépvezérlő',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.teal,
          secondary: AppColors.orange,
          surface: AppColors.card,
        ),
        sliderTheme: const SliderThemeData(
          trackHeight: 6,
          activeTrackColor: AppColors.teal,
          inactiveTrackColor: Color(0x1AFFFFFF),
          thumbColor: AppColors.teal,
          overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 10),
        ),
      ),
      home: const VezerloPanel(),
    );
  }
}

class VezerloPanel extends StatefulWidget {
  const VezerloPanel({super.key});
  @override
  State<VezerloPanel> createState() => _VezerloPanelState();
}

enum OperationMode { kezi, fAuto, auto1, auto2 }

class _VezerloPanelState extends State<VezerloPanel> {
  final String brokerHost =
      '204047e98f3f4581b077603c3496bfb3.s1.eu.hivemq.cloud';
  final String username = 'gep-vezerlo';
  final String password = 'adminadmin';

  final String topicStatus = 'gep/c3mini/status';
  final String topicCmd = 'gep/c3mini/cmd';
  final String topicOta = 'gep/c3mini/ota';
  final String topicOtaStatus = 'gep/c3mini/ota/status';

  MqttClient? client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>?
      _updatesSubscription;
  final Map<String, Timer> _manualHoldTimers = {};
  final Map<String, Timer> _commandAckTimers = {};
  final Map<String, DateTime> _commandSentAt = {};
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool isConnected = false;
  bool isConnecting = false;
  bool _hasReceivedStatus = false;
  String _manualCommandFeedback = "KÉZI PARANCSRA VÁR";
  String gepAllapotSzoveg = "VÁRAKOZÁS...";
  String szenzorok = "0000000";
  int ciklusSzamlalo = 0;
  OperationMode selectedMode = OperationMode.kezi;

  double tFroccs = 5000.0;
  double tHules = 10000.0;
  double tSzunet = 3000.0;

  int aktualisKilokes = 0;
  int kiloksekSzama = 1;
  double tKilokesKesleltetes = 1000.0;
  double tKilokesKitartas = 500.0;
  double tKilokesAllas = 500.0;

  double tUtonyomas = 5000.0;
  double tUtonyomasImpulzus = 1000.0;
  int tUtonyomasKitoltes = 50;

  int targetSzamlalo = 0;

  bool di8 = false;
  bool manualModeForced = false;
  bool fazisTimeout = false;
  int modbusDI = 0;
  bool onlineMode = true;

  int aktualisFazis = 0;
  int _selectedTab = 0;

  List<String> logs = [];
  late TextEditingController _targetController;

  // FIRMWARE OTA
  late TextEditingController _otaPasswordController;
  FirmwareOtaUploader? _otaUploader;
  Uint8List? _otaFirmwareBytes;
  String? _otaFirmwareName;
  bool _otaUploading = false;
  double _otaProgress = 0.0;
  String _otaStatusText = '';
  String? _otaError;
  bool _otaShowPassword = false;

  // ÖNFRISSÍTÉS
  bool _updateChecking = false;
  bool _updateDownloading = false;
  double _updateProgress = 0.0;
  int _updateDownloaded = 0;
  int _updateTotal = 0;
  String? _updateError;
  String _currentAppVersion = '?';

  @override
  void initState() {
    super.initState();
    _targetController = TextEditingController();
    _otaPasswordController = TextEditingController();
    _connectMqtt();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _currentAppVersion = info.version);
      _checkForUpdates();
    });
  }

  // ========================================================================
  // APP ÖNFRISSÍTÉS
  // ========================================================================
  Future<void> _checkForUpdates() async {
    if (_updateChecking || _updateDownloading) return;
    setState(() {
      _updateChecking = true;
      _updateError = null;
    });

    _addLog("Frissítés ellenőrzése (jelenlegi: $_currentAppVersion)...");
    final update = await UpdateService.checkForUpdate();

    if (!mounted) return;
    setState(() => _updateChecking = false);

    if (update != null) {
      _addLog("Új verzió elérhető: ${update.latestVersion}");
      _showUpdateDialog(update);
    } else {
      _addLog("Az App naprakész (v$_currentAppVersion)");
    }
  }

  void _showUpdateDialog(UpdateInfo update) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22)),
        title: const Text("Új verzió elérhető",
            style: TextStyle(
                color: AppColors.teal, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("Jelenlegi verzió: ${update.currentVersion}",
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textMuted)),
              const SizedBox(height: 4),
              Text("Új verzió: ${update.latestVersion}",
                  style: const TextStyle(
                      fontSize: 15,
                      color: AppColors.teal,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text("Méret: ${update.apkSizeFormatted}",
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textMuted)),
              if (update.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text("Újdonságok:",
                    style: TextStyle(
                        fontSize: 12,
                        color: AppColors.orange,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(update.releaseNotes,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.white70)),
              ],
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppColors.orange.withValues(alpha: 0.3)),
                ),
                child: const Row(children: [
                  Icon(Icons.warning_amber_rounded,
                      color: AppColors.orange, size: 24),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "A letöltés akár 1 órát is igénybe vehet (lassú interneten). "
                      "A frissítés alatt az App NEM használható!",
                      style: TextStyle(
                          color: AppColors.orange,
                          fontSize: 12,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _addLog("Frissítés elhalasztva");
            },
            child: const Text("Később",
                style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _downloadAndInstall(update);
            },
            icon: const Icon(Icons.download),
            label: const Text("Letöltés"),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.teal,
              foregroundColor: const Color(0xFF06120E),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstall(UpdateInfo update) async {
    setState(() {
      _updateDownloading = true;
      _updateProgress = 0.0;
      _updateError = null;
    });
    _addLog("Letöltés indul: ${update.apkUrl}");

    final apkFile = await UpdateService.downloadApk(
      update.apkUrl,
      (progress, downloaded, total) {
        if (!mounted) return;
        setState(() {
          _updateProgress = progress;
          _updateDownloaded = downloaded;
          _updateTotal = total;
        });
      },
    );

    if (!mounted) return;

    if (apkFile == null) {
      setState(() {
        _updateDownloading = false;
        _updateError = "Letöltés sikertelen";
      });
      _addLog("Letöltés sikertelen");
      return;
    }

    setState(() => _updateDownloading = false);
    _addLog("Letöltés kész: ${apkFile.path}");
    _addLog("Telepítés indítása...");
    await UpdateService.installApk(apkFile);
  }

  // ========================================================================
  // MQTT
  // ========================================================================
  Future<void> _connectMqtt() async {
    if (isConnecting || !mounted) return;
    setState(() => isConnecting = true);
    _addLog("MQTT-kapcsolódás a HiveMQ-kiszolgálóhoz...");

    const port = kIsWeb ? 8884 : 8883;
    bool ok = false;
    try {
      ok = await _tryOne(port: port);
    } finally {
      if (mounted) setState(() => isConnecting = false);
    }

    if (ok) {
      _reconnectAttempt = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      if (mounted) _addLog("SIKERES KAPCSOLÓDÁS - MQTT-KAPCSOLAT AKTÍV");
    } else {
      _scheduleReconnect();
    }
  }

  Future<bool> _tryOne({required int port}) async {
    final clientId = 'GepVez_${DateTime.now().millisecondsSinceEpoch}';
    _addLog("Kapcsolódás: $brokerHost:$port (${kIsWeb ? 'WSS' : 'TLS'})...");

    final mqttClient = createMqttClient(brokerHost, clientId, port);
    client = mqttClient;
    mqttClient.keepAlivePeriod = 20;
    mqttClient.setProtocolV311();
    mqttClient.logging(on: false);
    mqttClient.autoReconnect = false;
    mqttClient.resubscribeOnAutoReconnect = false;

    mqttClient.onConnected = () => _onConnected(mqttClient);
    mqttClient.onDisconnected = () => _onDisconnected(mqttClient);
    mqttClient.onAutoReconnect = () => _onAutoReconnect(mqttClient);
    mqttClient.onAutoReconnected = () => _onAutoReconnected(mqttClient);

    final connMess = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .authenticateAs(username, password)
        .startClean()
        .withWillQos(MqttQos.atMostOnce);
    mqttClient.connectionMessage = connMess;

    try {
      await mqttClient.connect().timeout(const Duration(seconds: 10));
      final connected =
          mqttClient.connectionStatus?.state == MqttConnectionState.connected;
      if (!connected) {
        _addLog("A broker nem fogadta el az MQTT-kapcsolatot.");
      }
      return connected;
    } catch (e) {
      _addLog("KAPCSOLÓDÁSI HIBA a $port számú porton: $e");
      try {
        mqttClient.disconnect();
      } catch (_) {}
      return false;
    }
  }

  void _onConnected(MqttClient mqttClient) {
    if (!mounted || mqttClient != client) return;
    setState(() => isConnected = true);
    _addLog("KAPCSOLÓDVA A ${mqttClient.port}-ES PORTON");
    mqttClient.autoReconnect = true;
    mqttClient.resubscribeOnAutoReconnect = true;
    mqttClient.subscribe(topicStatus, MqttQos.atMostOnce);
    mqttClient.subscribe(topicOtaStatus, MqttQos.atMostOnce);
    _listenForUpdates(mqttClient);
    _sendCmd("GET_STATUS");
  }

  void _onDisconnected(MqttClient mqttClient) {
    if (mqttClient != client) return;
    if (isConnected) _addLog("A KAPCSOLAT MEGSZAKADT");
    _stopAllManualCommands();
    if (mounted) {
      setState(() {
        isConnected = false;
        gepAllapotSzoveg = "NINCS KAPCSOLAT";
      });
    }
    if (!mqttClient.autoReconnect) _scheduleReconnect();
  }

  void _onAutoReconnect(MqttClient mqttClient) {
    if (!mounted || mqttClient != client) return;
    _addLog("MQTT-kapcsolat megszakadt; automatikus újracsatlakozás...");
    _stopAllManualCommands();
    setState(() {
      isConnected = false;
      gepAllapotSzoveg = "ÚJRACSATLAKOZÁS...";
    });
  }

  void _onAutoReconnected(MqttClient mqttClient) {
    if (!mounted || mqttClient != client) return;
    _reconnectAttempt = 0;
    setState(() => isConnected = true);
    _addLog("MQTT-KAPCSOLAT HELYREÁLLT");
    mqttClient.subscribe(topicStatus, MqttQos.atMostOnce);
    mqttClient.subscribe(topicOtaStatus, MqttQos.atMostOnce);
    _listenForUpdates(mqttClient);
    _sendCmd("GET_STATUS");
  }

  void _listenForUpdates(MqttClient mqttClient) {
    final updates = mqttClient.updates;
    if (updates == null) {
      _addLog("MQTT állapotfolyam még nem érhető el.");
      return;
    }
    _updatesSubscription?.cancel();
    _updatesSubscription = updates.listen((messages) {
      if (mqttClient != client) return;
      for (final received in messages) {
        final topic = received.topic;
        final rec = received.payload as MqttPublishMessage;
        final msg =
            MqttPublishPayload.bytesToStringAsString(rec.payload.message);

        if (topic == topicOtaStatus) {
          if (_otaUploader != null) {
            _otaUploader!.handleStatusMessage(msg);
          }
          _addLog("OTA: $msg");
          continue;
        }

        if (topic != topicStatus) continue;

        if (!_hasReceivedStatus) {
          _hasReceivedStatus = true;
          _addLog("ÁLLAPOTADAT ÉRKEZETT A VEZÉRLŐTŐL");
        }
        for (final part in msg.split('|')) {
          if (part.startsWith('ACK:')) {
            _handleCommandAcknowledgement(part.substring(4));
          }
        }
        _parseBridgeStatus(msg);
      }
    }, onError: (Object error, StackTrace stackTrace) {
      if (mqttClient != client) return;
      _addLog("MQTT adatfolyam-hiba: $error");
      _stopAllManualCommands();
      if (mounted) {
        setState(() {
          isConnected = false;
          gepAllapotSzoveg = "NINCS KAPCSOLAT";
        });
      }
    });
  }

  void _scheduleReconnect() {
    if (!mounted || _reconnectTimer?.isActive == true) return;
    final delaySeconds = (5 << _reconnectAttempt.clamp(0, 3)).clamp(5, 30);
    _reconnectAttempt++;
    _addLog("$delaySeconds mp múlva újrapróbálom az MQTT-kapcsolatot.");
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _reconnectTimer = null;
      _connectMqtt();
    });
  }

  Future<void> _handleRefresh() async {
    if (!isConnected) {
      await _connectMqtt();
    } else {
      _sendCmd("GET_STATUS");
    }
    await Future.delayed(const Duration(seconds: 1));
  }

  void _parseBridgeStatus(String raw) {
    try {
      String nSzenzor = szenzorok;
      int nUzem = selectedMode.index;
      int nFaz = aktualisFazis;
      int nSzam = ciklusSzamlalo;
      double nF = tFroccs, nH = tHules, nS = tSzunet;

      int nAktKil = aktualisKilokes;
      int nKilokSzam = kiloksekSzama;
      double nKe = tKilokesKesleltetes;
      double nKk = tKilokesKitartas;
      double nKb = tKilokesAllas;
      double nU = tUtonyomas;
      double nUi = tUtonyomasImpulzus;
      int nUk = tUtonyomasKitoltes;

      bool nDi8 = di8;
      bool nMf = manualModeForced;
      bool nTo = fazisTimeout;
      int nMdi = modbusDI;
      bool nOm = onlineMode;
      int nTc = targetSzamlalo;

      for (String part in raw.split('|')) {
        if (part.startsWith('ST:')) {
          String st = part.substring(3).trim();
          if (st.length >= 7) {
            nSzenzor = st.substring(0, 7);
          } else if (st.length >= 5) {
            nSzenzor = "${st[0]}${st[1]}${st[2]}${st[3]}${st[4]}00";
          }
        } else if (part.startsWith('M:')) {
          nUzem = int.tryParse(part.substring(2)) ?? nUzem;
        } else if (part.startsWith('F:') && !part.contains(',')) {
          nFaz = int.tryParse(part.substring(2)) ?? nFaz;
        } else if (part.startsWith('S:') && !part.contains(',')) {
          nSzam = int.tryParse(part.substring(2)) ?? nSzam;
        } else if (part.startsWith('KIL:')) {
          String kil = part.substring(4);
          List<String> p = kil.split('/');
          if (p.length == 2) {
            nAktKil = int.tryParse(p[0]) ?? nAktKil;
            nKilokSzam = int.tryParse(p[1]) ?? nKilokSzam;
          }
        } else if (part.startsWith('DI8:')) {
          nDi8 = part.substring(4).trim() == '1';
        } else if (part.startsWith('MF:')) {
          nMf = part.substring(3).trim() == '1';
        } else if (part.startsWith('TO:')) {
          nTo = part.substring(3).trim() == '1';
        } else if (part.startsWith('MDI:')) {
          nMdi = int.tryParse(part.substring(4)) ?? nMdi;
        } else if (part.startsWith('OM:')) {
          nOm = part.substring(3).trim() == '1';
        } else if (part.startsWith('TC:')) {
          nTc = int.tryParse(part.substring(3)) ?? nTc;
        } else if (part.startsWith('T:')) {
          for (String t in part.substring(2).split(',')) {
            if (t.startsWith('F:')) nF = double.tryParse(t.substring(2)) ?? nF;
            if (t.startsWith('H:')) nH = double.tryParse(t.substring(2)) ?? nH;
            if (t.startsWith('S:')) nS = double.tryParse(t.substring(2)) ?? nS;
            if (t.startsWith('KE:')) {
              nKe = double.tryParse(t.substring(3)) ?? nKe;
            }
            if (t.startsWith('KK:')) {
              nKk = double.tryParse(t.substring(3)) ?? nKk;
            }
            if (t.startsWith('KB:')) {
              nKb = double.tryParse(t.substring(3)) ?? nKb;
            }
            if (t.startsWith('KSZ:')) {
              nKilokSzam = int.tryParse(t.substring(4)) ?? nKilokSzam;
            }
            if (t.startsWith('UI:')) {
              nUi = double.tryParse(t.substring(3)) ?? nUi;
            }
            if (t.startsWith('UK:')) {
              nUk = int.tryParse(t.substring(3)) ?? nUk;
            }
            if (t.startsWith('U:')) {
              nU = double.tryParse(t.substring(2)) ?? nU;
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          szenzorok = nSzenzor;
          if (nUzem >= 0 && nUzem < OperationMode.values.length) {
            selectedMode = OperationMode.values[nUzem];
          }
          aktualisFazis = nFaz;
          gepAllapotSzoveg = _mapFazisToText(nFaz.toString());
          ciklusSzamlalo = nSzam;
          tFroccs = nF;
          tHules = nH;
          tSzunet = nS;

          aktualisKilokes = nAktKil;
          kiloksekSzama = nKilokSzam;
          tKilokesKesleltetes = nKe;
          tKilokesKitartas = nKk;
          tKilokesAllas = nKb;
          tUtonyomas = nU;
          tUtonyomasImpulzus = nUi;
          tUtonyomasKitoltes = nUk;

          di8 = nDi8;
          manualModeForced = nMf;
          fazisTimeout = nTo;
          modbusDI = nMdi;
          onlineMode = nOm;
          targetSzamlalo = nTc;
        });
        if (nUzem != OperationMode.kezi.index) {
          _stopAllManualCommands(sendOff: true);
        }
      }
    } catch (e) {
      _addLog("Parse hiba: $e");
    }
  }

  void _handleCommandAcknowledgement(String payload) {
    final command = payload;
    final timer = _commandAckTimers.remove(command);
    if (timer != null) {
      timer.cancel();
      final sentAt = _commandSentAt.remove(command);
      final elapsedMs = sentAt == null
          ? null
          : DateTime.now().difference(sentAt).inMilliseconds;
      _manualCommandFeedback =
          elapsedMs == null ? "ACK: $command" : "ACK: $command ($elapsedMs ms)";
      _addLog("A VEZÉRLŐ MEGKAPTA: $command"
          "${elapsedMs == null ? '' : ' ($elapsedMs ms)'}");
    }
  }

  String _mapFazisToText(String f) {
    switch (f) {
      case "0":
        return "KÉSZENLÉT";
      case "1":
        return "1. SZERSZÁM ZÁRÁSA";
      case "2":
        return "2. AGGREGÁT ELŐREMENET";
      case "3":
        return "3. FRÖCCSÖNTÉS";
      case "4":
        return "4. HŰLÉS + UTÓNYOMÁS";
      case "5":
        if (kiloksekSzama > 0) {
          return "5. SZERSZÁM NYITÁSA\n(kilökés: $aktualisKilokes/$kiloksekSzama)";
        }
        return "5. SZERSZÁM NYITÁSA";
      case "6":
        return "6. SZÜNET";
      case "7":
        return "7. SZÜNET - NYITVA AZ AJTÓ";
      default:
        return "ÁLLAPOT: $f";
    }
  }

  String get _displayStatusText {
    if (fazisTimeout) {
      return "TIMEOUT!\nA fázis 30 s-nél tovább tartott.";
    }
    if (targetSzamlalo > 0 && ciklusSzamlalo >= targetSzamlalo) {
      return "CÉL ELÉRVE!\n$ciklusSzamlalo / $targetSzamlalo";
    }
    final csigaFeltoltve = szenzorok.length > 4 && szenzorok[4] == '1';
    if (_hasReceivedStatus && aktualisFazis == 0 && !csigaFeltoltve) {
      return "CSIGA ÜRES";
    }
    return gepAllapotSzoveg;
  }

  String _modeToText(OperationMode mode) {
    switch (mode) {
      case OperationMode.kezi:
        return "KÉZI";
      case OperationMode.fAuto:
        return "FÉLAUTOMATA";
      case OperationMode.auto1:
        return "AUTOMATA 1";
      case OperationMode.auto2:
        return "AUTOMATA 2";
    }
  }

  void _addLog(String m) {
    logs.insert(0, "${DateTime.now().toString().substring(11, 19)}: $m");
    if (logs.length > 40) logs.removeLast();
    if (mounted) setState(() {});
  }

  void _sendCmd(String cmd, {bool log = true}) {
    final activeClient = client;
    if (isConnected &&
        activeClient?.connectionStatus?.state ==
            MqttConnectionState.connected) {
      final b = MqttClientPayloadBuilder();
      b.addString(cmd);
      final qos =
          (cmd == "GET_STATUS") ? MqttQos.atMostOnce : MqttQos.atLeastOnce;
      if (log) {
        _commandAckTimers.remove(cmd)?.cancel();
        _commandSentAt[cmd] = DateTime.now();
        _manualCommandFeedback = "KÜLDÉS: $cmd";
        _addLog("KÜLDÉS: $cmd");
        _commandAckTimers[cmd] = Timer(const Duration(seconds: 5), () {
          _commandAckTimers.remove(cmd);
          _commandSentAt.remove(cmd);
          _manualCommandFeedback = "NINCS VISSZAIGAZOLÁS: $cmd";
          if (mounted) _addLog("NINCS VISSZAIGAZOLÁS: $cmd");
        });
      }
      activeClient!.publishMessage(topicCmd, qos, b.payload!);
    } else if (log) {
      _addLog("NINCS KAPCSOLAT - A(z) $cmd parancs nem került elküldésre");
    }
  }

  void _startManualCommand(String command) {
    if (_manualHoldTimers.containsKey(command)) return;
    final onCommand = "${command}_ON";
    _sendCmd(onCommand);
    if (!isConnected) return;

    _manualHoldTimers[command] = Timer.periodic(
      const Duration(milliseconds: 1000),
      (_) {
        if (!isConnected ||
            client?.connectionStatus?.state != MqttConnectionState.connected) {
          _stopManualCommand(command, sendOff: false);
          return;
        }
        _sendCmd(onCommand, log: false);
      },
    );
  }

  void _stopManualCommand(String command, {bool sendOff = true}) {
    final timer = _manualHoldTimers.remove(command);
    timer?.cancel();
    if (sendOff && timer != null) _sendCmd("${command}_OFF");
  }

  void _stopAllManualCommands({bool sendOff = false}) {
    final commands = _manualHoldTimers.keys.toList();
    for (final command in commands) {
      _stopManualCommand(command, sendOff: sendOff);
    }
  }

  void _sendStart() {
    setState(() => gepAllapotSzoveg = "INDUL...");
    _sendCmd("START");
  }

  void _sendStop() {
    _stopAllManualCommands(sendOff: true);
    setState(() => gepAllapotSzoveg = "LEÁLLÍTVA");
    _sendCmd("STOP");
  }

  void _sendModeCmd(OperationMode mode) {
    if (mode != OperationMode.kezi) {
      _stopAllManualCommands(sendOff: true);
    }
    setState(() => selectedMode = mode);
    _sendCmd("MODE:${mode.index}");
  }

  @override
  void dispose() {
    _targetController.dispose();
    _otaPasswordController.dispose();
    _reconnectTimer?.cancel();
    _updatesSubscription?.cancel();
    for (final timer in _commandAckTimers.values) {
      timer.cancel();
    }
    _commandAckTimers.clear();
    _stopAllManualCommands(sendOff: true);
    client
      ?..autoReconnect = false
      ..disconnect();
    super.dispose();
  }

  // ========================================================================
  // BUILD
  // ========================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.6, -1.0),
            radius: 1.5,
            colors: [Color(0xFF1A2330), AppColors.bg],
            stops: [0.0, 0.55],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _handleRefresh,
                  color: AppColors.teal,
                  backgroundColor: AppColors.card,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!onlineMode) _buildOfflineBanner(),
                        if (_updateChecking) _buildUpdateCheckingBanner(),
                        if (_updateDownloading)
                          _buildUpdateDownloadingBanner(),
                        if (_updateError != null) _buildUpdateErrorBanner(),
                        if (fazisTimeout) _buildTimeoutBanner(),
                        if (aktualisFazis == 7 && !fazisTimeout)
                          _buildAlertBanner(),
                        _buildCurrentTab(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ========================================================================
  // HEADER — brand + action ikonok, majd ALATTA a tab ikonok
  // ========================================================================
  Widget _buildHeader() {
    final tabs = [
      (Icons.dashboard_outlined, 'Vezérlés'),
      (Icons.pan_tool_outlined, 'Kézi'),
      (Icons.timer_outlined, 'Idők'),
      (Icons.memory_outlined, 'Szenzorok'),
      (Icons.settings_outlined, 'Rendszer'),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xD90A0B10),
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ---------- SOR 1: brand + action ikonok ----------
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppColors.teal.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: AppColors.teal.withValues(alpha: 0.25)),
                    ),
                    child: const Icon(Icons.smart_toy_outlined,
                        size: 16, color: AppColors.teal),
                  ),
                  const SizedBox(width: 10),
                  Row(children: [
                    const Text('Gépvezérlő',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('C3 / S3',
                          style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 9,
                              fontWeight: FontWeight.w700)),
                    ),
                  ]),
                ]),
                Row(children: [
                  GestureDetector(
                    onTap: (_updateChecking || _updateDownloading)
                        ? null
                        : _checkForUpdates,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.border),
                      ),
                      child: const Icon(Icons.system_update_alt,
                          size: 13, color: Colors.white70),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: isConnected
                          ? AppColors.green.withValues(alpha: 0.12)
                          : AppColors.red.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: (isConnected
                                  ? AppColors.green
                                  : AppColors.red)
                              .withValues(alpha: 0.25)),
                    ),
                    child: Icon(
                      isConnected ? Icons.wifi : Icons.wifi_off,
                      size: 13,
                      color:
                          isConnected ? AppColors.green : AppColors.red,
                    ),
                  ),
                ]),
              ],
            ),
          ),
          // ---------- SOR 2: tab ikonok ----------
          Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: List.generate(tabs.length, (i) {
                final active = i == _selectedTab;
                final (icon, label) = tabs[i];
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedTab = i),
                    behavior: HitTestBehavior.opaque,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      margin: const EdgeInsets.symmetric(
                          horizontal: 2, vertical: 8),
                      decoration: BoxDecoration(
                        color: active
                            ? AppColors.teal.withValues(alpha: 0.1)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: active
                            ? Border.all(
                                color:
                                    AppColors.teal.withValues(alpha: 0.15))
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            icon,
                            size: 20,
                            color: active
                                ? AppColors.teal
                                : Colors.white.withValues(alpha: 0.4),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            label.toUpperCase(),
                            style: TextStyle(
                              color: active
                                  ? AppColors.teal
                                  : Colors.white.withValues(alpha: 0.4),
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  // ========================================================================
  // TAB ROUTER
  // ========================================================================
  Widget _buildCurrentTab() {
    switch (_selectedTab) {
      case 0:
        return _buildControlTab();
      case 1:
        return _buildManualTab();
      case 2:
        return _buildTimesTab();
      case 3:
        return _buildSensorsTab();
      case 4:
        return _buildSystemTab();
      default:
        return const SizedBox.shrink();
    }
  }

  // ========================================================================
  // TAB 0 — VEZÉRLÉS
  // ========================================================================
  Widget _buildControlTab() {
    final displayStatus = _displayStatusText;
    final bool targetReached =
        targetSzamlalo > 0 && ciklusSzamlalo >= targetSzamlalo;
    bool isError = fazisTimeout ||
        targetReached ||
        displayStatus.contains("NYITVA AZ AJTÓ") ||
        displayStatus.contains("NINCS KAPCSOLAT") ||
        displayStatus == "CSIGA ÜRES";
    Color glowColor = fazisTimeout
        ? AppColors.red
        : (targetReached
            ? AppColors.orange
            : (isError ? AppColors.orange : AppColors.teal));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // STATUS CARD
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.teal.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: AppColors.teal.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      'MÓD: ${_modeToText(selectedMode)}',
                      style: const TextStyle(
                        color: AppColors.teal,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: onlineMode
                          ? AppColors.green.withValues(alpha: 0.12)
                          : AppColors.blue.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: (onlineMode
                                  ? AppColors.green
                                  : AppColors.blue)
                              .withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: onlineMode
                                ? AppColors.green
                                : AppColors.blue,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          onlineMode ? 'ONLINE' : 'OFFLINE',
                          style: TextStyle(
                            color: onlineMode
                                ? AppColors.green
                                : AppColors.blue,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text('ÁLLAPOT',
                  style: TextStyle(
                    color: AppColors.textMuted2,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.2,
                  )),
              const SizedBox(height: 6),
              Text(
                displayStatus,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: glowColor,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 18),
              const Text('CIKLUSSZÁM',
                  style: TextStyle(
                    color: AppColors.textMuted2,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.8,
                  )),
              const SizedBox(height: 4),
              Text(
                '$ciklusSzamlalo',
                style: TextStyle(
                  color: targetReached ? AppColors.orange : AppColors.teal,
                  fontSize: 84,
                  height: 0.85,
                  fontWeight: FontWeight.w900,
                  fontFamily: 'monospace',
                  letterSpacing: -4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // MODE SELECTOR
        if (manualModeForced)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.orange.withValues(alpha: 0.1),
              border: Border.all(
                  color: AppColors.orange.withValues(alpha: 0.35)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(children: [
              Icon(Icons.lock, color: AppColors.orange, size: 16),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  "KÉZI MÓD KÉNYSZERÍTVE (8. bemenet aktív)\nAutómata mód nem választható!",
                  style: TextStyle(
                    color: AppColors.orange,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ),
            ]),
          ),
        IgnorePointer(
          ignoring: manualModeForced,
          child: Opacity(
            opacity: manualModeForced ? 0.45 : 1,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: OperationMode.values.map((m) {
                  final active = selectedMode == m;
                  final labels = ['KÉZI', 'FÉLAUTO', 'AUTO 1', 'AUTO 2'];
                  return Expanded(
                    child: GestureDetector(
                      onTap: () => _sendModeCmd(m),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        height: 38,
                        decoration: BoxDecoration(
                          color: active ? AppColors.teal : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          labels[m.index],
                          style: TextStyle(
                            color: active
                                ? const Color(0xFF06120E)
                                : Colors.white.withValues(alpha: 0.45),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // START / STOP
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: manualModeForced ? null : _sendStart,
              child: Container(
                height: 72,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF35E8A8), Color(0xFF1FC28B)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.teal),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.teal.withValues(alpha: 0.28),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Opacity(
                  opacity: manualModeForced ? 0.45 : 1,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.power_settings_new,
                          size: 18, color: Color(0xFF06120E)),
                      SizedBox(width: 8),
                      Text('INDÍTÁS',
                          style: TextStyle(
                            color: Color(0xFF06120E),
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.4,
                          )),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: _sendStop,
              child: Container(
                height: 72,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFFFF7A7E), Color(0xFFE5454B)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFFF8A8E)),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.red.withValues(alpha: 0.28),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.stop, size: 16, color: Colors.white),
                    SizedBox(width: 8),
                    Text('LEÁLLÍTÁS',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                        )),
                  ],
                ),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),

        // INFO TILES
        Row(children: [
          Expanded(
            child: _infoTile(
              label: 'DARABSZÁM',
              sub: 'LIMIT',
              value: targetSzamlalo > 0
                  ? '$ciklusSzamlalo / $targetSzamlalo'
                  : '$ciklusSzamlalo / ∞',
              valueColor: AppColors.teal,
              valueSub: targetSzamlalo > 0 ? 'aktív' : 'nincs limit',
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: _InfoTileStatic(
              label: 'KAPCSOLAT',
              sub: 'MQTT',
              value: 'HiveMQ',
              valueSub: '● cloud',
            ),
          ),
        ]),
        const SizedBox(height: 12),

        // TIP
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.orange.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: AppColors.orange.withValues(alpha: 0.18)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.bolt, size: 14, color: AppColors.orange),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFFFFD6A0),
                        height: 1.5),
                    children: [
                      TextSpan(
                        text: 'Tipp: ',
                        style: TextStyle(
                          color: AppColors.orange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextSpan(
                        text:
                            'AUTO mód előtt ellenőrizd a szenzorokat a Szenzorok fülön.',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoTile({
    required String label,
    required String sub,
    required String value,
    Color? valueColor,
    String? valueSub,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                    color: AppColors.textMuted2,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                  )),
              const SizedBox(height: 4),
              Text(sub,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  )),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(value,
                  style: TextStyle(
                    color: valueColor ?? Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  )),
              if (valueSub != null) ...[
                const SizedBox(height: 2),
                Text(valueSub,
                    style: const TextStyle(
                      color: AppColors.textMuted2,
                      fontSize: 10,
                    )),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // ========================================================================
  // TAB 1 — KÉZI
  // ========================================================================
  Widget _buildManualTab() {
    final relays = [
      ('zar', 'SZERSZÁM\nZÁR', Icons.lock_outline, false),
      ('nyit', 'SZERSZÁM\nNYIT', Icons.lock_open, false),
      ('elore', 'AGGREGÁT\nELŐRE', Icons.fast_forward, false),
      ('hatra', 'AGGREGÁT\nHÁTRA', Icons.fast_rewind, false),
      ('froccs', 'FRÖCCSÖNTÉS', Icons.water_drop, false),
      ('csiga', 'CSIGA\nFORGÁS', Icons.rotate_right, false),
      ('kiloko', 'KILÖKŐ', Icons.output, true),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(children: [
              SizedBox(
                width: 3,
                height: 16,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.orange,
                    borderRadius: BorderRadius.all(Radius.circular(2)),
                  ),
                ),
              ),
              SizedBox(width: 8),
              Text('KÉZI RELÉVEZÉRLÉS',
                  style: TextStyle(
                    color: AppColors.orange,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6,
                  )),
            ]),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                    color: AppColors.orange.withValues(alpha: 0.2)),
              ),
              child: const Text('7 RELÉ',
                  style: TextStyle(
                    color: AppColors.orange,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  )),
            ),
          ],
        ),
        const SizedBox(height: 12),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.55,
          children: relays
              .where((r) => !r.$4)
              .map((r) => _relayButton(r.$1, r.$2, r.$3, false))
              .toList(),
        ),
        const SizedBox(height: 10),
        _relayButton('kiloko', 'KILÖKŐ', Icons.output, true),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.red.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: AppColors.red.withValues(alpha: 0.18)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0x33FF5A5F),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.warning_amber_rounded,
                      size: 14, color: AppColors.red),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Hosszan nyomva tartás szükséges',
                        style: TextStyle(
                          color: Color(0xFFFF8A8E),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        )),
                    SizedBox(height: 2),
                    Text(
                      'Biztonsági okból a relék csak 600ms folyamatos nyomásra kapcsolnak. Engedd fel a leállításhoz.',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _relayButton(String id, String label, IconData icon, bool full) {
    final enabled = selectedMode == OperationMode.kezi;
    final cmd = 'MAN_${id.toUpperCase()}';

    final content = full
        ? Row(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon,
                  size: 16, color: Colors.white.withValues(alpha: 0.7)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.0,
                      )),
                  const SizedBox(height: 4),
                  Text('RLY_${id.toUpperCase()}',
                      style: const TextStyle(
                        color: AppColors.textMuted2,
                        fontSize: 10,
                        fontFamily: 'monospace',
                      )),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 16, color: Colors.white.withValues(alpha: 0.2)),
          ])
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon,
                        size: 16,
                        color: Colors.white.withValues(alpha: 0.7)),
                  ),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                    height: 1.15,
                  )),
              const SizedBox(height: 4),
              Text('RLY_${id.toUpperCase()}',
                  style: const TextStyle(
                    color: AppColors.textMuted2,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  )),
            ],
          );

    return IgnorePointer(
      ignoring: !enabled,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Listener(
          onPointerDown: (_) => _startManualCommand(cmd),
          onPointerUp: (_) => _stopManualCommand(cmd),
          onPointerCancel: (_) => _stopManualCommand(cmd),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.border),
            ),
            constraints: BoxConstraints(minHeight: full ? 76 : 96),
            child: content,
          ),
        ),
      ),
    );
  }

  // ========================================================================
  // TAB 2 — IDŐK  (60 másodperces tartomány!)
  // ========================================================================
  Widget _buildTimesTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // IDŐZÍTŐK
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('IDŐZÍTŐK',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      )),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: const Text('0–60s',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        )),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _sliderRow(
                label: 'FRÖCCS',
                value: tFroccs,
                max: 60000,
                step: 500,
                accent: AppColors.teal,
                onChanged: (v) {
                  setState(() => tFroccs = v);
                  _sendCmd("SET_F:${v.toInt()}");
                },
              ),
              const Divider(height: 1, color: AppColors.border),
              _sliderRow(
                label: 'HŰTÉS',
                value: tHules,
                max: 60000,
                step: 500,
                accent: AppColors.teal,
                onChanged: (v) {
                  setState(() => tHules = v);
                  _sendCmd("SET_H:${v.toInt()}");
                },
              ),
              const Divider(height: 1, color: AppColors.border),
              _sliderRow(
                label: 'SZÜNET',
                value: tSzunet,
                max: 60000,
                step: 500,
                accent: AppColors.teal,
                onChanged: (v) {
                  setState(() => tSzunet = v);
                  _sendCmd("SET_S:${v.toInt()}");
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // KILÖKŐ
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('HIDRAULIKUS KILÖKŐ',
                      style: TextStyle(
                        color: AppColors.orange,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      )),
                  Text('$aktualisKilokes / $kiloksekSzama',
                      style: const TextStyle(
                        color: AppColors.teal,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        fontFamily: 'monospace',
                      )),
                ],
              ),
              const SizedBox(height: 4),
              _sliderRow(
                label: 'KILÖKÉSEK',
                value: kiloksekSzama.toDouble(),
                max: 5,
                step: 1,
                accent: AppColors.orange,
                isInt: true,
                unit: ' db',
                onChanged: (v) {
                  setState(() => kiloksekSzama = v.toInt());
                  _sendCmd("SET_KSZ:${v.toInt()}");
                },
              ),
              const Divider(height: 1, color: AppColors.border),
              _sliderRow(
                label: 'KÉSLELTETÉS',
                value: tKilokesKesleltetes,
                max: 5000,
                step: 100,
                accent: AppColors.orange,
                onChanged: (v) {
                  setState(() => tKilokesKesleltetes = v);
                  _sendCmd("SET_KE:${v.toInt()}");
                },
              ),
              const Divider(height: 1, color: AppColors.border),
              _sliderRow(
                label: 'KITARTÁS',
                value: tKilokesKitartas,
                max: 5000,
                step: 100,
                accent: AppColors.orange,
                onChanged: (v) {
                  setState(() => tKilokesKitartas = v);
                  _sendCmd("SET_KK:${v.toInt()}");
                },
              ),
              const Divider(height: 1, color: AppColors.border),
              _sliderRow(
                label: 'ÁLLÁSIDŐ',
                value: tKilokesAllas,
                max: 5000,
                step: 100,
                accent: AppColors.orange,
                onChanged: (v) {
                  setState(() => tKilokesAllas = v);
                  _sendCmd("SET_KB:${v.toInt()}");
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // UTÓNYOMÁS
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('UTÓNYOMÁS',
                      style: TextStyle(
                        color: AppColors.yellow,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      )),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: (tUtonyomas > 0
                              ? AppColors.yellow
                              : AppColors.textMuted2)
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: (tUtonyomas > 0
                                  ? AppColors.yellow
                                  : AppColors.textMuted2)
                              .withValues(alpha: 0.2)),
                    ),
                    child: Text(
                      tUtonyomas > 0 ? 'AKTÍV' : 'KIKAPCSOLVA',
                      style: TextStyle(
                        color: tUtonyomas > 0
                            ? AppColors.yellow
                            : AppColors.textMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              _sliderRow(
                label: 'UTÓNYOMÁS',
                value: tUtonyomas,
                max: 10000,
                step: 500,
                accent: AppColors.yellow,
                onChanged: (v) {
                  setState(() => tUtonyomas = v);
                  _sendCmd("SET_U:${v.toInt()}");
                },
              ),
              if (tUtonyomas > 0) ...[
                const Divider(height: 1, color: AppColors.border),
                _sliderRow(
                  label: 'IMPULZUS',
                  value: tUtonyomasImpulzus,
                  max: 5000,
                  step: 100,
                  accent: AppColors.yellow,
                  onChanged: (v) {
                    setState(() => tUtonyomasImpulzus = v);
                    _sendCmd("SET_UI:${v.toInt()}");
                  },
                ),
                const Divider(height: 1, color: AppColors.border),
                _sliderRow(
                  label: '% KITÖLTÉS',
                  value: tUtonyomasKitoltes.toDouble(),
                  max: 90,
                  min: 10,
                  step: 5,
                  accent: AppColors.orange,
                  isInt: true,
                  unit: '%',
                  onChanged: (v) {
                    setState(() => tUtonyomasKitoltes = v.toInt());
                    _sendCmd("SET_UK:${v.toInt()}");
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _sliderRow({
    required String label,
    required double value,
    required double max,
    required double step,
    required Color accent,
    required ValueChanged<double> onChanged,
    double min = 0,
    bool isInt = false,
    String unit = 's',
  }) {
    final display = isInt
        ? '${value.toInt()}$unit'
        : '${(value / 1000).toStringAsFixed(1)}$unit';
    final clamped = value.clamp(min, max);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  )),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(999),
                  border:
                      Border.all(color: accent.withValues(alpha: 0.19)),
                ),
                child: Text(display,
                    style: TextStyle(
                      color: accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                    )),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: accent,
              thumbColor: accent,
              overlayColor: accent.withValues(alpha: 0.15),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
            ),
            child: Slider(
              value: clamped,
              min: min,
              max: max,
              divisions: ((max - min) / step).round(),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  // ========================================================================
  // TAB 3 — SZENZOROK
  // ========================================================================
  Widget _buildSensorsTab() {
    final endstops = [
      ('Ajtó zárva', 0),
      ('Ajtó nyitva', 1),
      ('Szerszám zárva', 2),
      ('Szerszám nyitva', 3),
      ('Csiga feltöltve', 4),
      ('Aggregát elöl', 5),
      ('Aggregát hátul', 6),
    ];

    bool bit(int i) => ((modbusDI >> i) & 1) == 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // VÉGÁLLÁSOK
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('VÉGÁLLÁSKAPCSOLÓK',
                      style: TextStyle(
                        color: Color(0xD9FFFFFF),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      )),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text('ST: $szenzorok',
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        )),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ...List.generate(endstops.length, (i) {
                final (name, idx) = endstops[i];
                final ok = szenzorok.length > idx && szenzorok[idx] == '1';
                return Container(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: i == endstops.length - 1
                            ? Colors.transparent
                            : AppColors.border,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: ok
                                ? AppColors.green
                                : Colors.white.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                            boxShadow: ok
                                ? [
                                    const BoxShadow(
                                        color: AppColors.green,
                                        blurRadius: 8)
                                  ]
                                : null,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(name,
                            style: TextStyle(
                              color: ok
                                  ? Colors.white
                                  : AppColors.textMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            )),
                      ]),
                      Row(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('DI$idx',
                              style: const TextStyle(
                                color: AppColors.textMuted2,
                                fontSize: 10,
                                fontFamily: 'monospace',
                              )),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.chevron_right,
                            size: 12,
                            color: Colors.white.withValues(alpha: 0.2)),
                      ]),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // STATUS KÁRTYÁK
        _statusCard(
          label: 'KÉZI MÓD VEZÉRLÉS',
          sub: 'Bemenet kényszerítve • relé',
          color: AppColors.orange,
          active: di8 || manualModeForced,
        ),
        const SizedBox(height: 10),
        _statusCard(
          label: 'MŰKÖDÉSI MÓD',
          sub: onlineMode ? 'Online mód' : 'Offline mód',
          color: onlineMode ? AppColors.blue : AppColors.orange,
          active: true,
        ),
        const SizedBox(height: 10),
        _statusCard(
          label: 'MODBUS BEMENETEK',
          sub: '6 csatorna • 100ms',
          color: AppColors.purple,
          active: true,
          showPulse: onlineMode,
        ),
        const SizedBox(height: 12),

        // MODBUS
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('MODBUS BEMENETEK ONLINE',
                      style: TextStyle(
                        color: AppColors.purple,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      )),
                  Text(
                      '0x${modbusDI.toRadixString(16).toUpperCase().padLeft(2, '0')}',
                      style: const TextStyle(
                        color: AppColors.textMuted2,
                        fontSize: 10,
                        fontFamily: 'monospace',
                      )),
                ],
              ),
              const SizedBox(height: 12),
              _modbusRow('DI0', 'Módváltó kapcsoló', bit(0)),
              _modbusRow('DI1', 'START gomb', bit(1)),
              _modbusRow('DI2', 'STOP gomb', bit(2)),
              _modbusRow('DI3', 'Fröccs feedback', bit(3)),
              _modbusRow('DI4', 'Hűlés feedback', bit(4)),
              _modbusRow('DI5', 'Szünet feedback', bit(5)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusCard({
    required String label,
    required String sub,
    required Color color,
    bool active = true,
    bool showPulse = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                  )),
              const SizedBox(height: 2),
              Text(sub,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                  )),
            ],
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                if (showPulse) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                Text(active ? 'AKTÍV' : '—',
                    style: TextStyle(
                      color: active ? color : AppColors.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modbusRow(String di, String label, bool active) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(di,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  )),
            ),
            const SizedBox(width: 10),
            Text(label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 12,
                )),
          ]),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (active ? AppColors.green : AppColors.textMuted2)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                  color: (active ? AppColors.green : AppColors.textMuted2)
                      .withValues(alpha: 0.2)),
            ),
            child: Text(
              active ? 'AKTÍV' : '—',
              style: TextStyle(
                color: active ? AppColors.green : AppColors.textMuted,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ========================================================================
  // TAB 4 — RENDSZER
  // ========================================================================
  Widget _buildSystemTab() {
    final bool reached =
        targetSzamlalo > 0 && ciklusSzamlalo >= targetSzamlalo;
    final bool active = targetSzamlalo > 0;
    final quickOpts = [0, 10, 50, 100, 250, 500, 1000, 5000];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // DARABSZÁM LIMIT
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('DARABSZÁM LIMIT',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      )),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: reached
                          ? AppColors.orange.withValues(alpha: 0.15)
                          : (active
                              ? AppColors.teal.withValues(alpha: 0.15)
                              : Colors.white.withValues(alpha: 0.08)),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: reached
                              ? AppColors.orange.withValues(alpha: 0.3)
                              : (active
                                  ? AppColors.teal.withValues(alpha: 0.3)
                                  : AppColors.border)),
                    ),
                    child: Text(
                      reached ? 'ELÉRVE' : (active ? 'AKTÍV' : 'NINCS LIMIT'),
                      style: TextStyle(
                        color: reached
                            ? AppColors.orange
                            : (active ? AppColors.teal : AppColors.textMuted),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text('JELENLEGI',
                  style: TextStyle(
                    color: AppColors.textMuted2,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.2,
                  )),
              const SizedBox(height: 4),
              Text('$ciklusSzamlalo',
                  style: TextStyle(
                    color: reached ? AppColors.orange : AppColors.teal,
                    fontSize: 64,
                    height: 1,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                    letterSpacing: -2,
                  )),
              if (active) ...[
                const SizedBox(height: 8),
                Text('Cél: $targetSzamlalo db',
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                    )),
              ],
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('GYORS VÁLASZTÁS',
                    style: TextStyle(
                      color: AppColors.textMuted2,
                      fontSize: 10,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w700,
                    )),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: quickOpts.map((n) {
                  final sel = targetSzamlalo == n;
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        targetSzamlalo = n;
                        _targetController.text = n == 0 ? '' : '$n';
                      });
                      _sendCmd("SET_TARGET:$n");
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: sel
                            ? AppColors.teal.withValues(alpha: 0.1)
                            : Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: sel
                              ? AppColors.teal.withValues(alpha: 0.35)
                              : AppColors.border,
                        ),
                      ),
                      child: Text(
                        n == 0 ? '∞' : '$n',
                        style: TextStyle(
                          color: sel ? AppColors.teal : AppColors.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.bg2,
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(color: AppColors.borderStrong),
                    ),
                    child: TextField(
                      controller: _targetController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(4),
                      ],
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                      decoration: const InputDecoration(
                        hintText: 'Pontos érték',
                        hintStyle: TextStyle(
                          color: AppColors.textMuted2,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        border: InputBorder.none,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    final parsed =
                        int.tryParse(_targetController.text) ?? 0;
                    final clamped = parsed.clamp(0, 9999);
                    setState(() => targetSzamlalo = clamped);
                    _sendCmd("SET_TARGET:$clamped");
                  },
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    decoration: BoxDecoration(
                      color: AppColors.teal,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    alignment: Alignment.center,
                    child: const Text('OK',
                        style: TextStyle(
                          color: Color(0xFF06120E),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.0,
                        )),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => _confirmResetCount(),
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.orange.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(
                        color: AppColors.orange.withValues(alpha: 0.35)),
                  ),
                  alignment: Alignment.center,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.refresh,
                          size: 16, color: AppColors.orange),
                      SizedBox(width: 8),
                      Text('SZÁMLÁLÓ NULLÁZÁSA',
                          style: TextStyle(
                            color: AppColors.orange,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.4,
                          )),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // OTA
        _buildFirmwareOtaCard(),
        const SizedBox(height: 12),

        // LOG
        _buildLogWindow(),
      ],
    );
  }

  // ========================================================================
  // FIRMWARE OTA CARD (új design)
  // ========================================================================
  Widget _buildFirmwareOtaCard() {
    final bool hasFile = _otaFirmwareBytes != null;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('FIRMWARE OTA',
                  style: TextStyle(
                    color: AppColors.purple,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6,
                  )),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _otaUploading
                      ? AppColors.purple.withValues(alpha: 0.15)
                      : AppColors.green.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                      color: (_otaUploading
                              ? AppColors.purple
                              : AppColors.green)
                          .withValues(alpha: 0.2)),
                ),
                child: Text(
                  _otaUploading ? 'FELTÖLTÉS' : 'KÉSZENLÉT',
                  style: TextStyle(
                    color:
                        _otaUploading ? AppColors.purple : AppColors.green,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _otaUploading ? null : _selectFirmwareFile,
            child: Container(
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.purple.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                    color: AppColors.purple.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.download_outlined,
                      size: 16, color: AppColors.purple),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      hasFile
                          ? '${_otaFirmwareName ?? "firmware.bin"} '
                              '(${(_otaFirmwareBytes!.length / 1024).toStringAsFixed(1)} KB)'
                          : 'Firmware fájl kiválasztása (.bin)',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.purple,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _otaPasswordController,
            obscureText: !_otaShowPassword,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: 'OTA jelszó',
              hintStyle: const TextStyle(
                  color: AppColors.textMuted2,
                  fontFamily: 'monospace',
                  fontSize: 12),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              filled: true,
              fillColor: AppColors.bg2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: const BorderSide(color: AppColors.borderStrong),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: const BorderSide(color: AppColors.borderStrong),
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _otaShowPassword
                      ? Icons.visibility_off
                      : Icons.visibility,
                  size: 18,
                  color: AppColors.textMuted,
                ),
                onPressed: () =>
                    setState(() => _otaShowPassword = !_otaShowPassword),
              ),
            ),
          ),
          if (_otaUploading) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _otaProgress,
                minHeight: 8,
                backgroundColor: Colors.black45,
                valueColor:
                    const AlwaysStoppedAnimation(AppColors.purple),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(_otaStatusText,
                      style: const TextStyle(
                        color: AppColors.purple,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      )),
                ),
                Text('${(_otaProgress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                      color: AppColors.purple,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    )),
              ],
            ),
          ],
          if (_otaError != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: AppColors.red.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.error,
                    color: AppColors.red, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_otaError!,
                      style: const TextStyle(
                          color: AppColors.red, fontSize: 12)),
                ),
                GestureDetector(
                  onTap: () => setState(() => _otaError = null),
                  child: const Icon(Icons.close,
                      color: AppColors.red, size: 16),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 12),
          GestureDetector(
            onTap: (!hasFile || _otaUploading) ? null : _startOtaUpload,
            child: Container(
              height: 46,
              decoration: BoxDecoration(
                color: (hasFile && !_otaUploading)
                    ? AppColors.purple
                    : Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                    color: (hasFile && !_otaUploading)
                        ? AppColors.purple
                        : AppColors.border),
              ),
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_otaUploading)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation(Colors.white),
                      ),
                    )
                  else
                    Icon(
                      Icons.cloud_upload,
                      size: 18,
                      color: (hasFile && !_otaUploading)
                          ? Colors.white
                          : AppColors.textMuted2,
                    ),
                  const SizedBox(width: 8),
                  Text(
                    _otaUploading
                        ? 'Feltöltés...'
                        : 'Firmware feltöltése',
                    style: TextStyle(
                      color: (hasFile && !_otaUploading)
                          ? Colors.white
                          : AppColors.textMuted2,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Csak .bin, max 1.2MB. A vezérlő automatikusan újraindul a feltöltés végén.',
            style: TextStyle(
              fontSize: 10,
              color: AppColors.textMuted2,
              fontStyle: FontStyle.italic,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  // ========================================================================
  // LOG WINDOW
  // ========================================================================
  Widget _buildLogWindow() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF08090D),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.02),
              border: const Border(
                  bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('NAPLÓ / MQTT',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6,
                    )),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: AppColors.green.withValues(alpha: 0.2)),
                  ),
                  child: Row(children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: AppColors.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(isConnected ? 'ONLINE' : 'OFFLINE',
                        style: TextStyle(
                          color: isConnected
                              ? AppColors.green
                              : AppColors.red,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
                        )),
                  ]),
                ),
              ],
            ),
          ),
          Container(
            height: 170,
            padding: const EdgeInsets.all(12),
            child: ListView.builder(
              reverse: false,
              itemCount: logs.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  logs[i],
                  style: const TextStyle(
                    color: Color(0xCC7CFFB2),
                    fontSize: 10,
                    fontFamily: 'monospace',
                    height: 1.6,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ========================================================================
  // BANNEREK
  // ========================================================================
  Widget _buildOfflineBanner() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.blue.withValues(alpha: 0.1),
          border: Border.all(
              color: AppColors.blue.withValues(alpha: 0.35), width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(children: [
          Icon(Icons.cloud_off, color: AppColors.blue, size: 24),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              "OFFLINE MÓD AKTÍV\nKülső időzítők vezérlik a folyamatot.",
              style: TextStyle(
                  color: AppColors.blue,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  height: 1.4),
            ),
          ),
        ]),
      );

  Widget _buildUpdateCheckingBanner() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.teal.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: AppColors.teal.withValues(alpha: 0.2)),
        ),
        child: const Row(children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(AppColors.teal),
            ),
          ),
          SizedBox(width: 12),
          Text("Frissítés ellenőrzése...",
              style: TextStyle(color: AppColors.teal, fontSize: 13)),
        ]),
      );

  Widget _buildUpdateDownloadingBanner() {
    final progressPercent = (_updateProgress * 100).toStringAsFixed(1);
    final downloadedMB =
        (_updateDownloaded / 1024 / 1024).toStringAsFixed(1);
    final totalMB = (_updateTotal / 1024 / 1024).toStringAsFixed(1);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: AppColors.orange.withValues(alpha: 0.35), width: 1.5),
      ),
      child: Column(children: [
        Row(children: [
          const Icon(Icons.download,
              color: AppColors.orange, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text("Letöltés: $progressPercent%",
                style: const TextStyle(
                    color: AppColors.orange,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
          ),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _updateProgress,
            minHeight: 8,
            backgroundColor: Colors.black45,
            valueColor: const AlwaysStoppedAnimation(AppColors.orange),
          ),
        ),
        const SizedBox(height: 8),
        Text("$downloadedMB MB / $totalMB MB",
            style: const TextStyle(
                color: Colors.white70, fontSize: 12)),
        const SizedBox(height: 6),
        const Text("NE zárd be az App-ot a letöltés alatt!",
            style: TextStyle(
                color: AppColors.red,
                fontSize: 11,
                fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Widget _buildUpdateErrorBanner() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.red.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: AppColors.red.withValues(alpha: 0.35)),
        ),
        child: Row(children: [
          const Icon(Icons.error, color: AppColors.red, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_updateError ?? "Ismeretlen hiba",
                style: const TextStyle(
                    color: AppColors.red, fontSize: 13)),
          ),
          IconButton(
            icon: const Icon(Icons.close,
                color: AppColors.red, size: 18),
            onPressed: () => setState(() => _updateError = null),
          ),
        ]),
      );

  Widget _buildTimeoutBanner() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.red.withValues(alpha: 0.15),
          border: Border.all(color: AppColors.red, width: 2),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(children: [
          Icon(Icons.timer_off, color: AppColors.red, size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              "TIMEOUT!\nA fázis 30 másodpercnél tovább tartott.\nA gép leállt - ellenőrizd, majd indítsd újra.",
              style: TextStyle(
                  color: AppColors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  height: 1.5),
            ),
          ),
        ]),
      );

  Widget _buildAlertBanner() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.red.withValues(alpha: 0.1),
          border: Border.all(
              color: AppColors.red.withValues(alpha: 0.35), width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(children: [
          Icon(Icons.warning_amber_rounded,
              color: AppColors.red, size: 24),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              "GÉP PAUSE ÁLLAPOTBAN!\nEllenőrizd a gép állapotát, majd nyomj START-ot.",
              style: TextStyle(
                  color: AppColors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  height: 1.4),
            ),
          ),
        ]),
      );

  // ========================================================================
  // DIALOGS
  // ========================================================================
  Future<void> _confirmResetCount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22)),
        title: const Text("Számláló nullázása?",
            style: TextStyle(color: AppColors.orange)),
        content: Text(
          "A jelenlegi számláló ($ciklusSzamlalo) 0-ra áll vissza.\n\n"
          "Ez NEM állítja le a gépet, csak a számlálót nullázza.",
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Mégse",
                style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.orange),
            child: const Text("Nullázás"),
          ),
        ],
      ),
    );
    if (confirmed == true) _sendCmd("RESET_COUNT");
  }

  // ========================================================================
  // FIRMWARE OTA FUNKCIÓK
  // ========================================================================
  Future<void> _selectFirmwareFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['bin'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (file.bytes == null) {
        setState(() => _otaError = "Nem sikerült beolvasni a fájlt");
        return;
      }

      setState(() {
        _otaFirmwareBytes = file.bytes;
        _otaFirmwareName = file.name;
        _otaError = null;
      });
      _addLog("Firmware kiválasztva: ${file.name} (${file.size} byte)");
    } catch (e) {
      setState(() => _otaError = "Fájlválasztó hiba: $e");
    }
  }

  Future<void> _startOtaUpload() async {
    if (_otaFirmwareBytes == null) return;

    final pw = _otaPasswordController.text.trim();
    if (pw.length < 12) {
      setState(() => _otaError = "Az OTA jelszó legalább 12 karakter");
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22)),
        title: const Text("Firmware feltöltése?",
            style: TextStyle(color: AppColors.purple)),
        content: Text(
          "Fájl: ${_otaFirmwareName ?? "firmware.bin"}\n"
          "Méret: ${(_otaFirmwareBytes!.length / 1024).toStringAsFixed(1)} KB\n\n"
          "A feltöltés akár több percet is igénybe vehet.\n"
          "A vezérlő a végén automatikusan újraindul.\n\n"
          "Biztosan folytatod?",
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Mégse",
                style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.purple),
            child: const Text("Feltöltés"),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    _stopAllManualCommands(sendOff: true);

    setState(() {
      _otaUploading = true;
      _otaProgress = 0.0;
      _otaStatusText = 'Előkészítés...';
      _otaError = null;
    });

    _addLog("OTA feltöltés indítása: ${_otaFirmwareBytes!.length} byte");

    _otaUploader = FirmwareOtaUploader(
      publish: (payload) async {
        final activeClient = client;
        if (activeClient == null ||
            activeClient.connectionStatus?.state !=
                MqttConnectionState.connected) {
          return false;
        }
        final mqttPayload = MqttClientPayloadBuilder()
          ..payload!.addAll(payload);
        activeClient.publishMessage(
          topicOta,
          MqttQos.atLeastOnce,
          mqttPayload.payload!,
        );
        return true;
      },
      onProgress: (progress, status) {
        if (!mounted) return;
        setState(() {
          _otaProgress = progress;
          _otaStatusText = status;
        });
      },
      onLog: (msg) {
        if (!mounted) return;
        _addLog("OTA: $msg");
      },
    );

    try {
      final success = await _otaUploader!.upload(
        firmwareBytes: _otaFirmwareBytes!,
        otaPassword: pw,
      );

      if (!mounted) return;
      setState(() => _otaUploading = false);

      if (success) {
        _addLog("✅ OTA sikeres - vezérlő újraindul");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: AppColors.green,
              content: Text(
                  "Firmware sikeresen feltöltve! A vezérlő újraindul."),
              duration: Duration(seconds: 5),
            ),
          );
        }
      } else {
        setState(() {
          _otaError = "Az OTA feltöltés sikertelen. Nézd meg a logot.";
        });
        _addLog("❌ OTA sikertelen");
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _otaUploading = false;
        _otaError = "Váratlan hiba: $e";
      });
      _addLog("OTA hiba: $e");
    } finally {
      _otaUploader = null;
    }
  }
}

/* ============================================================
   STATIC HELPER WIDGET
   ============================================================ */
class _InfoTileStatic extends StatelessWidget {
  final String label;
  final String sub;
  final String value;
  final String? valueSub;
  const _InfoTileStatic({
    required this.label,
    required this.sub,
    required this.value,
    this.valueSub,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                    color: AppColors.textMuted2,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                  )),
              const SizedBox(height: 4),
              Text(sub,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  )),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  )),
              if (valueSub != null) ...[
                const SizedBox(height: 2),
                Text(valueSub!,
                    style: const TextStyle(
                      color: AppColors.green,
                      fontSize: 10,
                    )),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

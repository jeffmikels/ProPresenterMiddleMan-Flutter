import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// const PRO6_CONTROL_PROTOCOL = 600;
// const PRO7_CONTROL_PROTOCOL = 701;
void main() async {
  runApp(const Home());
}

/// we do this manually here because the dart:io
/// WebSocket.connect() sends headers as lowercase
/// but propresenter needs headers to be PascalCase
Future<WebSocket> buildWebSocket(server) async {
  Uri uri = Uri.parse(server);
  uri = Uri(
      scheme: uri.scheme == "wss" ? "https" : "http",
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.port,
      path: uri.path,
      query: uri.query,
      fragment: uri.fragment);

  Uint8List nonceData = Uint8List(16);
  Random random = Random();
  for (int i = 0; i < 16; i++) {
    nonceData[i] = random.nextInt(256);
  }
  var nonce = base64.encode(nonceData);

  var _httpClient = HttpClient();
  return _httpClient.openUrl("GET", uri).then((request) {
    // Setup the initial handshake.
    request.headers.add("Connection", 'Upgrade', preserveHeaderCase: true);
    request.headers.add("Upgrade", "websocket", preserveHeaderCase: true);
    request.headers.add("Sec-WebSocket-Key", nonce, preserveHeaderCase: true);
    request.headers.add("Sec-WebSocket-Version", "13", preserveHeaderCase: true);

    return request.close();
  }).then((response) {
    return response.detachSocket().then<WebSocket>((socket) => WebSocket.fromUpgradedSocket(socket, serverSide: false));
  });
}

class ProSettings {
  String host = '';
  int port = 0;
  String password = '';
  double version = 6.0;

  Map toJson() {
    return {
      'host': host,
      'port': port,
      'password': password,
      'version': version,
    };
  }

  fromJson(Map data) {
    host = data['host'] ?? '';
    port = data['port'] ?? 0;
    password = data['password'] ?? '';
    version = data['version'] ?? 6.0;
  }
}

class ProConnection {
  ProSettings settings;
  void Function(String)? onMessage;

  final ValueNotifier connectionNotifier = ValueNotifier(false);
  bool get connected => connectionNotifier.value;
  set connected(bool b) => connectionNotifier.value = b;

  bool shouldAuth = true;
  WebSocket? ws;
  StreamSubscription? listener;

  ProConnection(this.settings, [this.onMessage]);

  void disconnect() {
    listener?.cancel();
    ws?.close();
  }

  void connect() async {
    disconnect();
    shouldAuth = true;
    var url = 'ws://${settings.host}:${settings.port}/remote';
    print('connecting to ${url}');
    ws = await buildWebSocket(url).timeout(Duration(seconds: 2));
    print(ws!.readyState);
    listener = ws!.listen((event) {
      print(event);
      handle(event.toString());
    }, onDone: () {
      print('socket closed');
      connected = false;
    });

    auth();
  }

  void auth() {
    shouldAuth = false;
    send({
      'password': settings.password,
      'protocol': settings.version > 7.4
          ? 701
          : settings.version > 7
              ? 700
              : 600,
      'action': "authenticate",
    });
  }

  void send(dynamic msg) {
    print(msg);
    if (msg is String) {
      ws?.add(msg);
    } else {
      ws?.add(json.encode(msg));
    }
  }

  void handle(String msg) {
    if (shouldAuth) return auth();
    connected = true;
    if (onMessage != null) onMessage!(msg);
  }
}

class Home extends StatefulWidget {
  const Home({Key? key}) : super(key: key);

  @override
  _HomeState createState() => _HomeState();
}

class _HomeState extends State<Home> {
  late ProConnection master;
  late ProConnection slave;

  String consoleText = '';
  bool get connected => master.connected && slave.connected;
  bool preservePath = false;

  // StreamSubscription? masterListener;
  // StreamSubscription? slaveListener;

  // WebSocket? masterConnection;
  // WebSocket? slaveConnection;

  void refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  void consoleWrite(String msg) {
    setState(() {
      consoleText += '${msg}\n';
    });
  }

  void handleMasterMessage(String msg) {
    consoleWrite('MASTER: $msg');
    Map<String, dynamic> data = json.decode(msg);
    if (data['action'] == 'presentationTriggerIndex') {
      consoleWrite('SENDING...');
      if (preservePath) {
        slave.send(msg);
      } else {
        var path = data['presentationPath']!;
        data.remove('presentationPath');
        var newMsg = json.encode(data);
        consoleWrite(newMsg);
        slave.send(newMsg);
      }
    }
  }

  void handleSlaveMessage(String msg) {
    consoleWrite('SLAVE: $msg');
  }

  void connect() async {
    await savePrefs();
    master.connect();
    slave.connect();
  }

  void loadPrefs() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    master.settings.fromJson(json.decode(prefs.getString('master') ?? ''));
    slave.settings.fromJson(json.decode(prefs.getString('slave') ?? ''));
    preservePath = prefs.getBool('preservePath') ?? false;
    refresh();
  }

  Future<void> savePrefs() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString('master', json.encode(master.settings)),
      prefs.setString('slave', json.encode(slave.settings)),
      prefs.setBool('preservePath', preservePath),
    ]);
  }

  @override
  void initState() {
    super.initState();
    master = ProConnection(ProSettings(), handleMasterMessage);
    slave = ProConnection(ProSettings(), handleSlaveMessage);
    master.connectionNotifier.addListener(refresh);
    slave.connectionNotifier.addListener(refresh);
    loadPrefs();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSwatch(primarySwatch: Colors.amber),
      ),
      home: Scaffold(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                    child: ProSettingsWidget(
                      master.settings,
                      label: 'Master',
                      color: master.connected ? Colors.amber : null,
                    ),
                  ),
                  IconButton(
                    iconSize: 40,
                    padding: const EdgeInsets.all(0),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      connect();
                    },
                    color: connected ? Colors.amber : null,
                    icon: Icon(
                      connected ? Icons.play_circle_fill : Icons.play_circle_outline,
                    ),
                  ),
                  Expanded(
                    child: ProSettingsWidget(
                      slave.settings,
                      label: 'Slave',
                      color: master.connected ? Colors.amber : null,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('This program will pass messages from the master to the slave. '
                        'However, since ProPresenter 7 and ProPresenter 6 handle the presentation path differently, '
                        'We will strip the presentation path from the command sent to the slave, unless you click here:'),
                  ),
                  const Text('Preserve Path:'),
                  Switch.adaptive(
                    value: preservePath,
                    onChanged: (bool b) async {
                      preservePath = b;
                      await savePrefs();
                      refresh();
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: ProConsoleWidget(consoleText),
            ),
          ],
        ),
      ),
    );
  }
}

class ProSettingsWidget extends StatelessWidget {
  final ProSettings settings;
  final String? label;
  final Color? color;
  const ProSettingsWidget(this.settings, {Key? key, this.label, this.color}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      // height: 100,
      margin: const EdgeInsets.all(10),
      padding: const EdgeInsets.all(8),
      foregroundDecoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        border: Border.all(
          color: color ?? Colors.grey.shade800,
          width: 2,
        ),
      ),
      decoration: BoxDecoration(
        color: Colors.grey.shade800,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
      ),
      child: FocusTraversalGroup(
        child: SingleChildScrollView(
          child: Column(
            children: [
              if (label != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    label!.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 40,
                    ),
                  ),
                ),
              TextFormField(
                key: ValueKey(settings.host + '-host'),
                onChanged: (s) => settings.host = s,
                initialValue: settings.host,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  fillColor: Colors.white24,
                  filled: true,
                  // hintText: 'Host / IP',
                  labelText: 'ProPresenter Host / IP',
                ),
              ),
              const SizedBox(height: 4),
              TextFormField(
                key: ValueKey(settings.port.toString() + '-port'),
                initialValue: settings.port.toString(),
                onChanged: (s) => settings.port = int.tryParse(s) ?? 0,
                validator: (s) {
                  if (s!.isNotEmpty && int.tryParse(s) == null) return 'Port must be a number';
                },
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  fillColor: Colors.white24,
                  filled: true,
                  labelText: 'ProPresenter Port',
                ),
              ),
              const SizedBox(height: 4),
              TextFormField(
                key: ValueKey(settings.password + '-password'),
                initialValue: settings.password,
                onChanged: (s) => settings.password = s,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  fillColor: Colors.white24,
                  filled: true,
                  labelText: 'Remote Control Password',
                ),
              ),
              const SizedBox(height: 4),
              TextFormField(
                key: ValueKey(settings.version.toString() + '-version'),
                initialValue: settings.version.toString(),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                onChanged: (s) => settings.version = double.tryParse(s) ?? 6.0,
                validator: (s) {
                  if (s!.isNotEmpty && double.tryParse(s) == null) return 'Version must be a number like 6.0 or 7.7';
                },
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  fillColor: Colors.white24,
                  filled: true,
                  labelText: 'ProPresenter Version',
                ),
              ),
              // const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class ProConsoleWidget extends StatelessWidget {
  final String text;
  const ProConsoleWidget(this.text, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.amber,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Container(
        width: double.infinity,
        alignment: Alignment.topLeft,
        margin: const EdgeInsets.all(10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.grey[850],
          borderRadius: BorderRadius.circular(10),
        ),
        child: SingleChildScrollView(
          reverse: true,
          child: Text(text),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Microphone Detector',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MicrophoneListPage(),
    );
  }
}

class MicrophoneListPage extends StatefulWidget {
  const MicrophoneListPage({super.key});

  @override
  MicrophoneListPageState createState() => MicrophoneListPageState();
}

class MicrophoneListPageState extends State<MicrophoneListPage> {
  static const microphoneEventChannel =
      EventChannel('com.example.microphone_detector/microphone_events');
  static const audioEventChannel =
      EventChannel('com.example.microphone_detector/audio_events');
  static const methodChannel =
      MethodChannel('com.example.microphone_detector/audio_control');
  List<Map<String, dynamic>> _microphones = [];
  bool _isRecording = false;
  bool _canPlayback = false;

  @override
  void initState() {
    super.initState();
    microphoneEventChannel
        .receiveBroadcastStream()
        .listen(_handleMicrophoneEvent);
    audioEventChannel.receiveBroadcastStream().listen(_handleAudioEvent);
  }

  void _handleMicrophoneEvent(dynamic event) {
    debugPrint("Received microphone event: $event");
    if (event is List<dynamic>) {
      setState(() {
        _microphones = event.map((item) {
          if (item is Map<Object?, Object?>) {
            return item.map((key, value) => MapEntry(key.toString(), value));
          }
          return <String, dynamic>{};
        }).toList();
      });
      debugPrint("Updated microphones: $_microphones");
    }
  }

  void _handleAudioEvent(dynamic event) {
    debugPrint("Received audio event: $event");
    if (event is Map) {
      if (event.containsKey('recordingFinished')) {
        setState(() {
          _isRecording = false;
          _canPlayback = true;
        });
        debugPrint(
            "Updated state: _isRecording = $_isRecording, _canPlayback = $_canPlayback");
      } else if (event.containsKey('error')) {
        setState(() {
          _isRecording = false;
          _canPlayback = false;
        });
        _showErrorDialog(event['error'] as String);
      } else if (event.containsKey('playbackStarted')) {
        // Handle playback started event if needed
      }
    } else {
      debugPrint('Unknown audio event: $event');
    }
  }

  // void _handleEvent(dynamic event) {
  //   if (event is Map<String, dynamic>) {
  //     _handleStatusUpdate(event);
  //   } else if (event is List<dynamic>) {
  //     _updateMicrophones(event);
  //   }
  // }

  // void _handleStatusUpdate(Map<String, dynamic> status) {
  //   debugPrint("Received status update: $status"); // Add this line
  //   if (status.containsKey('recordingFinished')) {
  //     setState(() {
  //       _isRecording = false;
  //       _canPlayback = true;
  //     });
  //     debugPrint(
  //         "Recording finished, UI updated. _isRecording: $_isRecording, _canPlayback: $_canPlayback");
  //   } else if (status.containsKey('error')) {
  //     setState(() {
  //       _isRecording = false;
  //       _canPlayback = false;
  //     });
  //     debugPrint(
  //         "Error received, UI updated. _isRecording: $_isRecording, _canPlayback: $_canPlayback");
  //     _showErrorDialog(status['error'] as String);
  //   }
  // }

  // void _updateMicrophones(List<dynamic> microphonesList) {
  //   setState(() {
  //     _microphones = microphonesList
  //         .map((item) => Map<String, dynamic>.from(item as Map))
  //         .toList();
  //   });
  // }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Error'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _startRecording() async {
    try {
      await methodChannel.invokeMethod('startRecording');
      setState(() {
        _isRecording = true;
        _canPlayback = false;
      });
    } on PlatformException catch (e) {
      _showErrorDialog('Failed to start recording: ${e.message}');
    }
  }

  Future<void> _playRecording() async {
    try {
      await methodChannel.invokeMethod('playRecording');
    } on PlatformException catch (e) {
      _showErrorDialog('Failed to play recording: ${e.message}');
    }
  }

  // Future<void> _startRecording() async {
  //   try {
  //     await platform.invokeMethod('startRecording');
  //     setState(() {
  //       _isRecording = true;
  //       _canPlayback = false;
  //     });
  //   } on PlatformException catch (e) {
  //     _showErrorDialog('Failed to start recording: ${e.message}');
  //   }
  // }

  // Future<void> _playRecording() async {
  //   try {
  //     await platform.invokeMethod('playRecording');
  //   } on PlatformException catch (e) {
  //     _showErrorDialog('Failed to play recording: ${e.message}');
  //   }
  // }

  @override
  Widget build(BuildContext context) {
    debugPrint(
      "Building widget, _isRecording: $_isRecording, _canPlayback: $_canPlayback",
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connected Microphones'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _microphones.length,
              itemBuilder: (context, index) {
                final microphone = _microphones[index];
                return ListTile(
                  leading: Icon(
                    Icons.mic,
                    color: microphone['isDefault'] == true
                        ? Colors.blue
                        : Colors.grey,
                  ),
                  title: Text(microphone['name'] as String? ?? 'Unknown'),
                  subtitle: Text(
                      'Type: ${microphone['type'] as String? ?? 'Unknown'} - ID: ${microphone['deviceID'] ?? 'Unknown'}'),
                  trailing: microphone['isDefault'] == true
                      ? const Chip(
                          label: Text('Default'),
                          backgroundColor: Colors.blue,
                          labelStyle: TextStyle(color: Colors.white),
                        )
                      : null,
                );
              },
            ),
          ),
          _buildVolumeIndicator(),
          _buildTestControls(),
        ],
      ),
    );
  }

  Widget _buildTestControls() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          ElevatedButton(
            onPressed: _isRecording ? null : _startRecording,
            style: ElevatedButton.styleFrom(
              backgroundColor: _isRecording ? Colors.grey : null,
            ),
            child: Text(_isRecording ? 'Recording...' : 'Test Microphone'),
          ),
          ElevatedButton(
            onPressed: _canPlayback ? _playRecording : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _canPlayback ? null : Colors.grey,
            ),
            child: const Text('Play Recording'),
          ),
        ],
      ),
    );
  }

  Widget _buildVolumeIndicator() {
    final defaultMicrophone = _microphones.firstWhere(
      (mic) => mic['isDefault'] == true,
      orElse: () => {},
    );

    if (defaultMicrophone.isEmpty) {
      return const SizedBox.shrink();
    }

    final volume = defaultMicrophone['volume'] as double? ?? 0.0;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Text('Input Volume: ${(volume * 100).toStringAsFixed(0)}%'),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: volume,
            backgroundColor: Colors.grey[300],
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
          ),
        ],
      ),
    );
  }
}

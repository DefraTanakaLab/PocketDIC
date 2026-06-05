import 'package:flutter/material.dart';
import 'settings.dart';
import 'screens/camera_screen.dart';

final _settings = AppSettings();

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketDIC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: CameraScreen(settings: _settings),
    );
  }
}

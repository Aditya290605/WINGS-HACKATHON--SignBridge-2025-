import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'dart:typed_data';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(SignToVioce(cameras: cameras));
}

class SignToVioce extends StatelessWidget {
  final List<CameraDescription> cameras;

  const SignToVioce({Key? key, required this.cameras}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sign Language Detection',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: HomePage(cameras: cameras),
    );
  }
}

class HomePage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const HomePage({Key? key, required this.cameras}) : super(key: key);

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  CameraController? _controller;
  Interpreter? _interpreter;
  bool isDetecting = false;
  String currentPrediction = '';
  double confidence = 0.0;
  List<String> labels = [];
  DateTime lastUIUpdate = DateTime.now();

  // Constants based on model analysis
  static const int inputWidth = 224;
  static const int inputHeight = 224;
  static const int numChannels = 3;

  @override
  void initState() {
    super.initState();
    _loadLabels().then((_) => _loadModel()).then((_) => _initializeCamera());
  }

  Future<void> _loadLabels() async {
    try {
      final labelData = await rootBundle.loadString('assets/tflite/labels.txt');
      labels =
          labelData
              .split('\n')
              .map((line) {
                final parts = line.trim().split(' ');
                return parts.length > 1 ? parts[1] : '';
              })
              .where((label) => label.isNotEmpty)
              .toList();
      print('Labels loaded: ${labels.length}');
    } catch (e) {
      print('Error loading labels: $e');
      labels = List.generate(26, (i) => String.fromCharCode(65 + i))
        ..add('<unknown>');
    }
  }

  Future<void> _loadModel() async {
    try {
      final options = InterpreterOptions()..threads = 4;

      _interpreter = await Interpreter.fromAsset(
        'assets/tflite/model_unquant.tflite',
        options: options,
      );

      print('Model loaded successfully');
      final inputTensors = _interpreter!.getInputTensors();
      final outputTensors = _interpreter!.getOutputTensors();
      print('Input tensors: ${inputTensors.map((t) => t.shape).toList()}');
      print('Output tensors: ${outputTensors.map((t) => t.shape).toList()}');
    } catch (e) {
      print('Error loading model: $e');
    }
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) return;

    final camera = widget.cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => widget.cameras.first,
    );

    _controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid
              ? ImageFormatGroup.yuv420
              : ImageFormatGroup.bgra8888,
    );

    try {
      await _controller!.initialize();
      if (!mounted) return;

      await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);
      setState(() {});

      _controller!.startImageStream((CameraImage image) {
        if (!isDetecting) {
          isDetecting = true;
          processImage(image);
        }
      });
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  Future<void> processImage(CameraImage image) async {
    if (_interpreter == null) return;

    try {
      // Create input tensor
      final inputShape = [1, inputHeight, inputWidth, numChannels];
      final input = Float32List(inputShape.reduce((a, b) => a * b));

      // Process image data
      if (Platform.isAndroid) {
        processAndroidImage(image, input);
      } else {
        processIOSImage(image, input);
      }

      // Prepare output tensor
      final outputShape = [1, 27]; // [batch_size, num_classes]
      final output = List<List<double>>.filled(
        outputShape[0],
        List<double>.filled(outputShape[1], 0),
      );

      // Run inference
      _interpreter!.run(input.reshape(inputShape), output);

      // Process predictions
      final predictions = output[0];
      int maxIndex = 0;
      double maxConfidence = predictions[0];

      for (int i = 0; i < predictions.length; i++) {
        if (predictions[i] > maxConfidence) {
          maxConfidence = predictions[i];
          maxIndex = i;
        }
      }

      final now = DateTime.now();
      if (maxConfidence > 0.60 &&
          now.difference(lastUIUpdate).inMilliseconds > 150) {
        setState(() {
          currentPrediction = labels[maxIndex];
          confidence = maxConfidence;
          lastUIUpdate = now;
        });
      }
    } catch (e) {
      print('Error in processImage: $e');
    } finally {
      isDetecting = false;
    }
  }

  void processAndroidImage(CameraImage image, Float32List input) {
    final int width = image.width;
    final int height = image.height;
    final yPlane = image.planes[0].bytes;
    final uvPlane = image.planes[1].bytes;
    final uvPixelStride = image.planes[1].bytesPerPixel!;
    final uvRowStride = image.planes[1].bytesPerRow;

    // Scale factors
    final double scaleX = width / inputWidth;
    final double scaleY = height / inputHeight;

    for (int y = 0; y < inputHeight; y++) {
      for (int x = 0; x < inputWidth; x++) {
        final int srcX = (x * scaleX).floor();
        final int srcY = (y * scaleY).floor();

        final int yValue = yPlane[srcY * width + srcX];
        final int uvIndex =
            (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;
        final int uValue = uvPlane[uvIndex];
        final int vValue = uvPlane[uvIndex + 1];

        // Convert YUV to RGB
        final int r = (yValue + 1.370705 * (vValue - 128)).round().clamp(
          0,
          255,
        );
        final int g = (yValue -
                0.698001 * (vValue - 128) -
                0.337633 * (uValue - 128))
            .round()
            .clamp(0, 255);
        final int b = (yValue + 1.732446 * (uValue - 128)).round().clamp(
          0,
          255,
        );

        // Normalize to [-1, 1] and store in input tensor
        final int targetPixel = (y * inputWidth + x) * numChannels;
        input[targetPixel] = (r - 127.5) / 127.5;
        input[targetPixel + 1] = (g - 127.5) / 127.5;
        input[targetPixel + 2] = (b - 127.5) / 127.5;
      }
    }
  }

  void processIOSImage(CameraImage image, Float32List input) {
    final bytes = image.planes[0].bytes;
    final double scale = image.width / inputWidth;

    for (int y = 0; y < inputHeight; y++) {
      for (int x = 0; x < inputWidth; x++) {
        final int srcX = (x * scale).floor();
        final int srcY = (y * scale).floor();
        final int pixelIndex = (srcY * image.width + srcX) * 4;

        final int targetPixel = (y * inputWidth + x) * numChannels;
        // Convert BGRA to RGB and normalize to [-1, 1]
        input[targetPixel] = (bytes[pixelIndex + 2] - 127.5) / 127.5; // R
        input[targetPixel + 1] = (bytes[pixelIndex + 1] - 127.5) / 127.5; // G
        input[targetPixel + 2] = (bytes[pixelIndex] - 127.5) / 127.5; // B
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _interpreter?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign Language Detection'),
        backgroundColor: Colors.black,
      ),
      body: Stack(
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: _controller!.value.aspectRatio,
              child: CameraPreview(_controller!),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    currentPrediction.isEmpty
                        ? 'Detecting...'
                        : currentPrediction == '<unknown>'
                        ? 'Unknown Gesture'
                        : 'Letter: $currentPrediction',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (currentPrediction.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Confidence: ${(confidence * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

extension on List<double> {
  List reshape(List<int> shape) {
    if (shape.length == 1) return this;

    var result = [];
    var size = shape.sublist(1).reduce((a, b) => a * b);
    for (var i = 0; i < shape[0]; i++) {
      var start = i * size;
      var end = start + size;
      result.add(this.sublist(start, end).reshape(shape.sublist(1)));
    }
    return result;
  }
}

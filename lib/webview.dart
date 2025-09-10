import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

class WebViewApp extends StatefulWidget {
  const WebViewApp({super.key});

  @override
  State<WebViewApp> createState() => _WebViewAppState();
}

class _WebViewAppState extends State<WebViewApp> {
  late final WebViewController controller;
  double loadingProgress = 0;
  bool _isLoading = true;
  bool _hasError = false;
  bool _isFilePickerActive = false;

  @override
  void initState() {
    super.initState();
    _initializeWebViewController();
  }

  void _initializeWebViewController() {
    late final PlatformWebViewControllerCreationParams params;

    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final WebViewController webViewController =
        WebViewController.fromPlatformCreationParams(params);

    webViewController
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            setState(() {
              loadingProgress = progress / 100;
            });
          },
          onPageStarted: (String url) {
            setState(() {
              _isLoading = true;
              _hasError = false;
              loadingProgress = 0;
            });
          },
          onPageFinished: (String url) {
            setState(() {
              _isLoading = false;
              loadingProgress = 1;
            });

            // Inject JavaScript to override file input clicks
            _injectFileUploadHandler();
          },
          onWebResourceError: (WebResourceError error) {
            setState(() {
              _isLoading = false;
              _hasError = true;
            });
            if (kDebugMode) {
              print('Web resource error: ${error.description}');
            }
          },
          onNavigationRequest: (NavigationRequest request) {
            // Handle special URLs for file uploads
            if (request.url.startsWith('flutter://fileupload')) {
              _handleFileUpload();
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..addJavaScriptChannel(
        'FileUpload',
        onMessageReceived: (JavaScriptMessage message) {
          // Handle file upload from JavaScript
          _handleFileUpload();
        },
      )
      ..loadRequest(Uri.parse('https://tihd.tv'));

    controller = webViewController;
  }

  // Inject JavaScript to handle file input clicks
  void _injectFileUploadHandler() {
    controller.runJavaScript('''
      // Override all file inputs
      document.addEventListener('click', function(e) {
        var target = e.target;
        if (target.tagName === 'INPUT' && target.type === 'file') {
          e.preventDefault();
          e.stopPropagation();
          FileUpload.postMessage('open');
          return false;
        }
        
        // Check if parent is a label for file input
        if (target.tagName === 'LABEL') {
          var forAttr = target.getAttribute('for');
          if (forAttr) {
            var input = document.getElementById(forAttr);
            if (input && input.type === 'file') {
              e.preventDefault();
              e.stopPropagation();
              FileUpload.postMessage('open');
              return false;
            }
          }
        }
      }, true);
      
      // Also override change events to prevent default behavior
      var fileInputs = document.querySelectorAll('input[type="file"]');
      for (var i = 0; i < fileInputs.length; i++) {
        fileInputs[i].addEventListener('change', function(e) {
          e.preventDefault();
          e.stopPropagation();
        }, true);
      }
    ''');
  }

  // Handle file upload from the webview
  Future<void> _handleFileUpload() async {
    if (_isFilePickerActive) return;

    setState(() {
      _isFilePickerActive = true;
    });

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final bytes = await file.readAsBytes();

        // Convert to base64 for web
        String base64Image = base64Encode(bytes);
        String fileName = path.basename(file.path);
        String mimeType = _getMimeType(fileName);

        // Inject the file into the first file input on the page
        controller.runJavaScript('''
          // Find the first file input
          var fileInputs = document.querySelectorAll('input[type="file"]');
          if (fileInputs.length > 0) {
            // Create a fake event to trigger change listeners
            var fileInput = fileInputs[0];
            var dataTransfer = new DataTransfer();
            
            // Create a blob from base64
            var byteCharacters = atob('$base64Image');
            var byteArrays = [];
            
            for (var offset = 0; offset < byteCharacters.length; offset += 1024) {
              var slice = byteCharacters.slice(offset, offset + 1024);
              
              var byteNumbers = new Array(slice.length);
              for (var i = 0; i < slice.length; i++) {
                byteNumbers[i] = slice.charCodeAt(i);
              }
              
              var byteArray = new Uint8Array(byteNumbers);
              byteArrays.push(byteArray);
            }
            
            var blob = new Blob(byteArrays, {type: '$mimeType'});
            var file = new File([blob], '$fileName', {type: '$mimeType'});
            dataTransfer.items.add(file);
            
            fileInput.files = dataTransfer.files;
            
            // Dispatch change event
            var event = new Event('change', { bubbles: true });
            fileInput.dispatchEvent(event);
          }
        ''');
      }
    } catch (e) {
      if (kDebugMode) {
        print('File picker error: $e');
      }
    } finally {
      setState(() {
        _isFilePickerActive = false;
      });
    }
  }

  // Helper function to get MIME type from filename
  String _getMimeType(String filename) {
    final extension = path.extension(filename).toLowerCase();
    switch (extension) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.bmp':
        return 'image/bmp';
      case '.webp':
        return 'image/webp';
      default:
        return 'application/octet-stream';
    }
  }

  void _reloadWebView() {
    setState(() {
      _hasError = false;
      _isLoading = true;
    });
    controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          WebViewWidget(controller: controller),
          if (_isLoading)
            LinearProgressIndicator(
              value: loadingProgress,
              backgroundColor: Colors.black,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.red),
            ),
          if (_hasError)
            Container(
              color: Colors.white,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 64,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Failed to load page',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Please check your internet connection and try again',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _reloadWebView,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// Main Video Player Dialog Component for Full-Screen Viewing
class VideoPlayerDialog extends StatefulWidget {
  final String videoUrl;
  final String exerciseTitle;

  const VideoPlayerDialog({
    super.key,
    required this.videoUrl,
    required this.exerciseTitle,
  });

  @override
  State<VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<VideoPlayerDialog> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _hasError = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _initializeVideoPlayer();
  }

  Future<void> _initializeVideoPlayer() async {
    try {
      // Dispose previous controller if exists
      _controller?.dispose();

      // Use the exact pattern that works in admin app
      _controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.videoUrl),
        videoPlayerOptions: VideoPlayerOptions(
          allowBackgroundPlayback: false,
          mixWithOthers: false,
        ),
        httpHeaders: {
          // Add Firebase Storage authentication headers if needed
          'Accept': '*/*',
          'User-Agent': 'Flutter App',
        },
      );

      // Initialize using the exact pattern from admin app
      _controller!.initialize().then((_) {
        if (mounted) {
          setState(() {
            _isInitialized = true;
            _hasError = false;
          });
          // Enable wakelock to prevent screen from turning off during video playback
          WakelockPlus.enable();
          // Set looping and play after successful initialization
          _controller!.setLooping(true);
          _controller!.play();
        }
      }).catchError((error) {
        print('Video initialization error: $error');
        if (mounted) {
          setState(() {
            _hasError = true;
            _errorMessage = _getDetailedErrorMessage(error);
          });
        }
      });

      // Add listener for ongoing error monitoring
      _controller!.addListener(() {
        if (_controller!.value.hasError && mounted) {
          print('Video player error: ${_controller!.value.errorDescription}');
          setState(() {
            _hasError = true;
            _errorMessage = _controller!.value.errorDescription ?? 'Unknown video error';
          });
        }
      });

    } catch (e) {
      print('Video controller creation error: $e');
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = _getDetailedErrorMessage(e);
        });
      }
    }
  }

  String _getDetailedErrorMessage(dynamic error) {
    final String errorStr = error.toString().toLowerCase();
    
    if (errorStr.contains('codecprivate') || errorStr.contains('codec private')) {
      return 'Video codec configuration issue. This should now be resolved with the updated video player settings. Please try again.';
    } else if (errorStr.contains('v_mpeg4/iso/avc') || errorStr.contains('h264') || errorStr.contains('avc')) {
      return 'H.264/AVC codec issue. The updated video player configuration should handle this better. Please try again or use browser fallback.';
    } else if (errorStr.contains('codec') || errorStr.contains('format')) {
      return 'Video format issue. Updated player settings should improve compatibility. Try refreshing or use browser fallback.';
    } else if (errorStr.contains('network') || errorStr.contains('connection')) {
      return 'Network error loading video. Check your internet connection and try again.';
    } else if (errorStr.contains('invalid') || errorStr.contains('url')) {
      return 'Invalid video URL or file not found.';
    } else {
      return 'Video loading failed: ${error.toString()}. Try the browser option if the issue persists.';
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    // Disable wakelock when leaving video player
    WakelockPlus.disable();
    super.dispose();
  }

  void _copyVideoUrl() {
    Clipboard.setData(ClipboardData(text: widget.videoUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Video URL copied to clipboard!'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.exerciseTitle,
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            onPressed: _copyVideoUrl,
            icon: const Icon(Icons.copy, color: Colors.white),
            tooltip: 'Copy URL',
          ),
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close, color: Colors.white),
          ),
        ],
      ),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 800, maxHeight: 600),
          child:
              _hasError
                  ? _buildErrorWidget()
                  : _isInitialized
                  ? _buildVideoPlayer()
                  : _buildLoadingWidget(),
        ),
      ),
    );
  }

  Widget _buildVideoPlayer() {
    return AspectRatio(
      aspectRatio: _controller!.value.aspectRatio,
      child: Stack(
        children: [
          VideoPlayer(_controller!),
          _VideoControls(controller: _controller!),
        ],
      ),
    );
  }

  Widget _buildLoadingWidget() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 16),
          Text(
            'Loading video...',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorWidget() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            const Text(
              'Unable to load video',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _errorMessage,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _hasError = false;
                      _isInitialized = false;
                    });
                    _initializeVideoPlayer();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _copyVideoUrl,
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy URL'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey.shade700,
                    foregroundColor: Colors.white,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _openInBrowser,
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('Open in Browser'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade900.withOpacity(0.3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade700, width: 1),
              ),
              child: Column(
                children: [
                  const Icon(Icons.info_outline, color: Colors.blue, size: 20),
                  const SizedBox(height: 8),
                  Text(
                    _getVideoCompatibilityTip(),
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openInBrowser() async {
    try {
      final Uri uri = Uri.parse(widget.videoUrl);
      final bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      
      if (launched) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Opening video in browser...'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        // Fallback to copying URL if launch fails
        _copyVideoUrl();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open browser. URL copied to clipboard.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      // Fallback to copying URL if there's an error
      _copyVideoUrl();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error opening browser. URL copied to clipboard.'),
        ),
      );
    }
  }

  String _getVideoCompatibilityTip() {
    final String errorStr = _errorMessage.toLowerCase();
    
    if (errorStr.contains('codecprivate') || errorStr.contains('codec private')) {
      return 'Technical Issue: Videos should be encoded with H.264 Baseline Profile and include SPS/PPS headers. Contact your provider about re-encoding the video file.';
    } else if (errorStr.contains('codec') || errorStr.contains('h264') || errorStr.contains('avc')) {
      return 'Compatibility Issue: Video codec not supported on Android. Recommend encoding as H.264 Baseline Profile (Level 3.0) in MP4 container for universal compatibility.';
    } else {
      return 'Tip: If the video fails to play on your device, try opening it in a web browser where it may work better.';
    }
  }
}

// Custom Video Controls Component
class _VideoControls extends StatefulWidget {
  final VideoPlayerController controller;

  const _VideoControls({required this.controller});

  @override
  State<_VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<_VideoControls> {
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _hideControlsAfterDelay();
  }

  void _hideControlsAfterDelay() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  void _togglePlayPause() {
    setState(() {
      if (widget.controller.value.isPlaying) {
        widget.controller.pause();
      } else {
        // If video has ended, seek to beginning before playing
        if (widget.controller.value.position >=
            widget.controller.value.duration) {
          widget.controller.seekTo(Duration.zero);
        }
        widget.controller.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _showControls = !_showControls;
        });
        if (_showControls) {
          _hideControlsAfterDelay();
        }
      },
      child: Container(
        color: Colors.transparent,
        child: AnimatedOpacity(
          opacity: _showControls ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 300),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.3),
                  Colors.transparent,
                  Colors.black.withOpacity(0.7),
                ],
              ),
            ),
            child: Stack(
              children: [
                // Play/Pause button in center
                Center(
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      iconSize: 64,
                      onPressed: _togglePlayPause,
                      icon: Icon(
                        widget.controller.value.isPlaying
                            ? Icons.pause
                            : Icons.play_arrow,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                // Progress bar at bottom
                Positioned(
                  bottom: 20,
                  left: 20,
                  right: 20,
                  child: ValueListenableBuilder(
                    valueListenable: widget.controller,
                    builder: (context, VideoPlayerValue value, child) {
                      return Column(
                        children: [
                          VideoProgressIndicator(
                            widget.controller,
                            allowScrubbing: true,
                            colors: const VideoProgressColors(
                              playedColor: Colors.red,
                              bufferedColor: Colors.grey,
                              backgroundColor: Colors.black26,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                value.isInitialized
                                    ? _formatDuration(value.position)
                                    : '0:00',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                value.isInitialized
                                    ? _formatDuration(value.duration)
                                    : '0:00',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    // Handle invalid or zero duration
    if (duration == Duration.zero || duration.isNegative) {
      return '0:00';
    }

    final int totalSeconds = duration.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;

    // Only show hours if video is longer than 1 hour
    if (hours > 0) {
      return '${hours}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes}:${seconds.toString().padLeft(2, '0')}';
    }
  }
}

// Original ExerciseVideoPlayer for inline preview/thumbnail display
class ExerciseVideoPlayer extends StatefulWidget {
  final String videoUrl;
  const ExerciseVideoPlayer({super.key, required this.videoUrl});

  @override
  State<ExerciseVideoPlayer> createState() => _ExerciseVideoPlayerState();
}

class _ExerciseVideoPlayerState extends State<ExerciseVideoPlayer> {
  @override
  Widget build(BuildContext context) {
    return _buildVideoThumbnail(widget.videoUrl);
  }

  // Build video thumbnail with play overlay for previews/lists
  Widget _buildVideoThumbnail(String videoUrl) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _playVideoFullScreen(videoUrl),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.grey.shade800, Colors.grey.shade900],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Click to play video',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Full-screen video dialog
  void _playVideoFullScreen(String videoUrl) {
    showDialog(
      context: context,
      barrierColor: Colors.black,
      builder:
          (context) => Dialog.fullscreen(
            child: VideoPlayerDialog(
              videoUrl: videoUrl,
              exerciseTitle: 'Exercise Video',
            ),
          ),
    );
  }
}

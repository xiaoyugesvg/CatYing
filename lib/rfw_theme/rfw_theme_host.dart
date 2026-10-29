import 'package:flutter/material.dart';
import 'package:rfw/formats.dart';
import 'package:rfw/rfw.dart';

import 'package:tvbox/rfw_theme/rfw_theme_events.dart';
import 'package:tvbox/rfw_theme/rfw_theme_library.dart';

class RfwThemeHost extends StatefulWidget {
  const RfwThemeHost({
    super.key,
    required this.themeText,
    required this.homeData,
    required this.onAction,
  });

  final String themeText;
  final Map<String, Object?> homeData;
  final void Function(RfwThemeAction action) onAction;

  @override
  State<RfwThemeHost> createState() => _RfwThemeHostState();
}

class _RfwThemeHostState extends State<RfwThemeHost> {
  late final Runtime _runtime;
  late final DynamicContent _data;
  String? _error;
  String _loadedText = '';

  @override
  void initState() {
    super.initState();
    _runtime = Runtime();
    _runtime.update(
      const LibraryName(['core', 'widgets']),
      createPeekCoreWidgets(),
    );
    _runtime.update(
      const LibraryName(['peek', 'home']),
      createPeekHomeLibrary(),
    );
    _data = DynamicContent();
    _loadTheme();
  }

  @override
  void didUpdateWidget(RfwThemeHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeText != widget.themeText) {
      _loadTheme();
    } else if (!identical(oldWidget.homeData, widget.homeData)) {
      _data.update('home', widget.homeData);
    }
  }

  @override
  void dispose() {
    _runtime.dispose();
    super.dispose();
  }

  void _loadTheme() {
    try {
      final library = parseLibraryFile(widget.themeText);
      _runtime.update(const LibraryName(['rfw', 'theme']), library);
      _data.update('home', widget.homeData);
      _error = null;
    } catch (error) {
      _error = error.toString();
    }
    _loadedText = widget.themeText;
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null || _loadedText != widget.themeText) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error ?? '主题加载中', textAlign: TextAlign.center),
        ),
      );
    }
    return RemoteWidget(
      runtime: _runtime,
      widget: const FullyQualifiedWidgetName(
        LibraryName(['rfw', 'theme']),
        'root',
      ),
      data: _data,
      onEvent: (name, args) {
        final action = parseRfwThemeEvent(name, args);
        if (action != null) {
          widget.onAction(action);
        }
      },
    );
  }
}

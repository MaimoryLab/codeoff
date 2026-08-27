import 'package:flutter/material.dart';

class ThreadDetailPage extends StatelessWidget {
  const ThreadDetailPage({
    required this.messages,
    required this.composer,
    super.key,
  });

  final Widget messages;
  final Widget composer;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(child: messages),
      composer,
    ],
  );
}

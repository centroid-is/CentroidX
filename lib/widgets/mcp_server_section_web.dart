import 'package:flutter/material.dart';

/// Nothing at all.
///
/// The MCP bridge is a server this panel would *host*, which a browser tab
/// cannot do. Rendering a disabled card would suggest a setting that could be
/// turned on, so the section is simply absent from the settings list.
class McpServerSection extends StatelessWidget {
  const McpServerSection({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

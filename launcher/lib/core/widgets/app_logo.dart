import 'package:flutter/material.dart';
import 'builders/logo_diamond_builder.dart';
import 'builders/logo_text_builder.dart';

class AppLogo extends StatelessWidget {
  final double size;

  const AppLogo({super.key, this.size = 48});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LogoDiamondBuilder.build(size),
        const SizedBox(width: 12),
        LogoTextBuilder.build(),
      ],
    );
  }
}

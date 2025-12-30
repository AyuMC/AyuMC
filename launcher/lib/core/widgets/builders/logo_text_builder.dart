import 'package:flutter/material.dart';

import '../../theme/app_text_styles.dart';

class LogoTextBuilder {
  LogoTextBuilder._();

  static Widget build() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_buildTitle(), _buildSubtitle()],
    );
  }

  static Widget _buildTitle() {
    return Text(
      'AyuMC',
      style: AppTextStyles.h2.copyWith(letterSpacing: 1.2, height: 1),
    );
  }

  static Widget _buildSubtitle() {
    return Text(
      'Server Control',
      style: AppTextStyles.caption.copyWith(letterSpacing: 0.5),
    );
  }
}

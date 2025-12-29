import 'package:flutter/material.dart';
import '../../../../core/constants/app_constants.dart';

class ButtonHelpers {
  ButtonHelpers._();

  static Widget buildLoadingIcon(BuildContext context, Color color) {
    return SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }

  static Widget buildStopIcon(BuildContext context, bool isLoading) {
    if (isLoading) {
      return buildLoadingIcon(context, Theme.of(context).colorScheme.onError);
    }
    return const Icon(Icons.stop);
  }

  static String getStopButtonText(bool isLoading) {
    return isLoading ? 'Stopping...' : AppConstants.serverStopButton;
  }
}

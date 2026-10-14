import 'package:flutter/material.dart';

/// The signed-in email's initial in the reading serif, or a neutral person icon.
class AccountMonogram extends StatelessWidget {
  /// Draws a [size]-pixel circle; decorative, so the adjacent email carries meaning.
  const AccountMonogram({super.key, required this.email, this.size = 56});

  /// Signed-in address, or null when no account is connected.
  final String? email;

  /// Diameter in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final email = this.email;
    final initial = email == null || email.isEmpty
        ? null
        : email.characters.first.toUpperCase();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: initial == null ? scheme.surfaceContainer : scheme.primary,
          border: initial == null
              ? Border.all(color: scheme.outlineVariant)
              : null,
        ),
        child: initial == null
            ? Icon(
                Icons.person_outline,
                size: size * .5,
                color: scheme.onSurfaceVariant,
              )
            : Text(
                initial,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontFamily: 'Lora',
                  fontSize: size * .46,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  color: scheme.onPrimary,
                ),
              ),
      ),
    );
  }
}

import 'package:reader/illustrations/illustration_configuration.dart';
import 'package:reader/illustrations/illustration_profile.dart';
import 'package:reader/illustrations/illustration_provider_option.dart';
import 'package:reader/illustrations/illustration_setup.dart';

/// Server catalogue fixture; no network, prose or generation operations.
IllustrationSetup selectionSetup({
  String? savedProvider,
  bool enabled = true,
  Set<String> unavailable = const {},
}) => IllustrationSetup(
  cloudBookId: enabled ? 'cloud-book' : null,
  suggestedStyle: 'Watercolor',
  alternativeStyles: const ['Woodcut', 'Cinematic'],
  estimatedCredits: 12,
  currentProfile: savedProvider == null
      ? null
      : IllustrationProfile(
          enabled: true,
          style: 'Saved custom ink',
          density: 3,
          providerId: savedProvider,
          revision: 4,
          cloudBookId: 'cloud-book',
        ),
  configuration: IllustrationConfiguration(
    enabled: enabled,
    defaultProviderId: 'openai',
    providers: [
      for (final (id, label, tier) in const [
        ('openai', 'OpenAI', 'premium'),
        ('google', 'Google', 'balanced'),
        ('seedream', 'ByteDance', 'budget'),
        ('qwen', 'Alibaba', 'budget'),
        ('xai', 'xAI', 'balanced'),
        ('flux', 'BFL', 'premium'),
        ('diagnostic', 'Pipeline test', 'free'),
      ])
        IllustrationProviderOption(
          id: id,
          label: label,
          model: 'fixture-$id',
          available: !unavailable.contains(id),
          recommended: id == 'google',
          costTier: tier,
        ),
    ],
  ),
);

import 'conjure_effect.dart';
import 'effect_canvas.dart';
import 'illustration_hint_effects.dart';
import 'narration_effects.dart';
import 'sample_passages.dart';

/// One effect as the gallery and detail view present it.
class TextEffectEntry {
  /// Illustration hints unless [narration]; [activation] is the tap response.
  const TextEffectEntry(
    this.name,
    this.description,
    this.passage,
    this.effect, {
    this.narration = false,
    this.activation = const Duration(milliseconds: 700),
  });

  /// Short name of the effect.
  final String name;

  /// What the reader sees happen, in a sentence or two.
  final String description;

  /// Passage shown in the detail view; its anchor fills the gallery tile.
  final SamplePassage passage;

  /// Frame painter.
  final TextEffect effect;

  /// Narration effects follow a word clock instead of answering taps.
  final bool narration;

  /// Length of the tap response.
  final Duration activation;
}

/// Marks for a passage that can become a picture, showpiece first.
const illustrationEffects = [
  TextEffectEntry(
    'Conjure',
    'Gold dust rises off gilt lettering. Tap it: the letters lift and tumble, '
        'sparks burst, a frame draws itself around the scene and the letters '
        'fall back as gold leaf.',
    kansas,
    conjure,
    activation: Duration(milliseconds: 2400),
  ),
  TextEffectEntry(
    'Ink underline',
    'A pen line wavers under the scene and floods into a wash when tapped.',
    callMeIshmael,
    inkUnderline,
  ),
  TextEffectEntry(
    'Gilt glint',
    'The scene is lettered in gold leaf that catches the light now and then.',
    whiteRabbit,
    giltGlint,
  ),
  TextEffectEntry(
    'Illuminated initial',
    'The first letter glows, like a rubricated capital.',
    marleyWasDead,
    illuminatedInitial,
  ),
  TextEffectEntry(
    'Watercolor bloom',
    'Pigment drifts behind the scene, waiting to become a painting.',
    greenLight,
    watercolorBloom,
  ),
  TextEffectEntry(
    'Margin leaf',
    'A leaf breathes in the margin beside the scene.',
    admiralBenbow,
    marginFleuron,
  ),
  TextEffectEntry(
    'Stipple',
    "Engraver's dots under the scene twinkle in turn.",
    thornfield,
    stipple,
  ),
  TextEffectEntry(
    'Pencil hatching',
    'Graphite strokes shade in behind the scene like the start of a sketch. '
        'Tapping cross-hatches it.',
    bestOfTimes,
    pencilHatching,
  ),
  TextEffectEntry(
    'Ink drop',
    'A drop of ink falls on the scene and spreads along the line. Tapping '
        'lets it soak up into a wash.',
    wendy,
    inkDrop,
  ),
];

/// Marks that follow the word being read aloud.
const narrationEffects = [
  TextEffectEntry(
    'Inking',
    'Words wait in grey and fill with ink as they are read.',
    bennetSisters,
    inking,
    narration: true,
  ),
  TextEffectEntry(
    'Lamplight',
    'A pool of warm light follows the voice and the rest of the page dims.',
    dreadfulNight,
    lamplight,
    narration: true,
  ),
  TextEffectEntry(
    'Reading rule',
    'A slim rule glides under each word.',
    timeMachine,
    readingRule,
    narration: true,
  ),
  TextEffectEntry(
    'Lift',
    'The spoken word rises and settles.',
    dorianStudio,
    lift,
    narration: true,
  ),
  TextEffectEntry(
    'Marker',
    'A highlighter stroke sweeps across each word and fades behind.',
    wonderlandCat,
    markerStroke,
    narration: true,
  ),
  TextEffectEntry(
    'Ripple',
    'A wave runs through the letters with the voice.',
    messingAbout,
    ripple,
    narration: true,
  ),
  TextEffectEntry(
    'Embers',
    'Sparks lift off each word as it is spoken.',
    happyFamilies,
    embers,
    narration: true,
  ),
];

/// Every effect in gallery order, which the detail view pages through.
const textEffects = [...illustrationEffects, ...narrationEffects];

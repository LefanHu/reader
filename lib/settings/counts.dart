/// Month abbreviations for locale-free settings dates.
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Groups thousands with commas, as in `48,200`.
String groupedCount(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Shortens large counts for headline figures: `950`, `8.4k`, `184k`, `1.2M`.
///
/// Rounds down so a total is never overstated; one decimal only below ten.
String compactCount(int value) {
  if (value < 1000) return '$value';
  final (unit, suffix) = value < 1000000 ? (1000, 'k') : (1000000, 'M');
  final tenths = value * 10 ~/ unit;
  if (tenths >= 100 || tenths % 10 == 0) return '${tenths ~/ 10}$suffix';
  return '${tenths ~/ 10}.${tenths % 10}$suffix';
}

/// Short calendar date such as `Nov 1`, in the date's own time zone.
String shortDate(DateTime date) => '${_months[date.month - 1]} ${date.day}';

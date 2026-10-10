/// Stable, compact English grouping used beside titles in the library.
String wordCountLabel(int count) {
  final digits = count.toString();
  return '≈ ${digits.replaceAllMapped(RegExp(r"\B(?=(\d{3})+(?!\d))"), (_) => ',')} words';
}

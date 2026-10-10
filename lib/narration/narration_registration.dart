/// Registration and current UTC-month allowance returned by the private API.
class NarrationRegistration {
  /// The server account ID is included in every local audio cache identity.
  const NarrationRegistration(this.account, this.bookId, this.remaining);

  /// Authenticated Firebase user owning this registration.
  final String account;

  /// Private narration book registration, separate from illustration credits.
  final String bookId;

  /// Remaining UTF-16 input units; cached replay consumes none.
  final int remaining;
}

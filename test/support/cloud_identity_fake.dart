// Test state records boundary behavior; production APIs document lifecycle rules.
// ignore_for_file: public_member_api_docs
import 'package:reader/cloud_identity.dart';

/// Offline account fake never grants per-book consent or invokes feature APIs.
class FakeCloudIdentity implements CloudIdentity {
  @override
  bool configured = true;
  @override
  String? email;
  int signIns = 0, signOuts = 0, reauthentications = 0, deletions = 0;
  bool cancel = false;
  bool failSignOut = false;
  @override
  Future<bool> hasSession() async => email != null;
  @override
  Future<void> signIn() async {
    signIns++;
    if (cancel) {
      throw const CloudIdentityException('Cancelled', cancelled: true);
    }
    email = 'reader@example.test';
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    email = null;
    if (failSignOut) throw StateError('Native selector cleanup failed');
  }

  @override
  Future<void> reauthenticate() async {
    reauthentications++;
  }

  @override
  Future<void> deleteAccount() async {
    deletions++;
    email = null;
  }

  @override
  Future<Map<String, String>> authorizationHeaders({
    bool interactive = true,
  }) async {
    if (interactive) await signIn();
    return {'authorization': 'Bearer test', 'x-firebase-appcheck': 'test'};
  }
}

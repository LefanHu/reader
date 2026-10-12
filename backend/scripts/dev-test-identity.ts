// Mints a real dev-environment test identity for Dart dev-API tests.
//
// `flutter test` exercises the deployed dev backend, whose every /v1 route
// verifies a Firebase ID token and an App Check token. This script obtains
// both for an arbitrary test uid: the Admin SDK signs a custom token (and an
// App Check token) through IAM signBlob as the Firebase Admin SDK service
// account using the developer's Application Default Credentials, and the
// Identity Toolkit exchanges the custom token for an ID token (creating the
// user on first sign-in). No key material or secret is stored; access is
// granted per developer by Terraform `api_test_principals` on dev only.
//
// Lives outside src/ so it is neither compiled into the service nor picked up
// by the backend test glob.
//
// Usage (cwd backend/):
//   npx tsx scripts/dev-test-identity.ts --uid <uid> --defines <dev.json>
// Prints one JSON line {uid, idToken, appCheckToken, expiresAt} where
// expiresAt is the earliest token expiry in epoch milliseconds. Errors go to
// stderr without tokens.
import { readFileSync } from 'node:fs';
import { applicationDefault, initializeApp } from 'firebase-admin/app';
import { getAppCheck } from 'firebase-admin/app-check';
import { getAuth } from 'firebase-admin/auth';

const bundleId = 'com.leafmealone.reader';
const appCheckTtlMillis = 3_600_000;

class StepError extends Error {
  constructor(readonly step: string, cause: unknown) {
    super(cause instanceof Error ? cause.message : String(cause));
  }
}

async function step<T>(name: string, run: () => Promise<T> | T): Promise<T> {
  try {
    return await run();
  } catch (error) {
    throw new StepError(name, error);
  }
}

function argument(name: string): string {
  const index = process.argv.indexOf(`--${name}`);
  const value = index < 0 ? undefined : process.argv[index + 1];
  if (!value) throw new Error(`missing --${name}`);
  return value;
}

function define(defines: Record<string, unknown>, key: string): string {
  const value = defines[key];
  if (typeof value !== 'string' || value.length === 0) throw new Error(`missing ${key}`);
  return value;
}

async function main(): Promise<void> {
  const { uid, projectId, apiKey, appId } = await step('arguments', () => {
    const defines = JSON.parse(readFileSync(argument('defines'), 'utf8')) as Record<string, unknown>;
    return {
      uid: argument('uid'),
      projectId: define(defines, 'FIREBASE_PROJECT_ID'),
      apiKey: define(defines, 'FIREBASE_API_KEY'),
      appId: define(defines, 'FIREBASE_APP_ID'),
    };
  });
  await step('initialize', () =>
    initializeApp({
      credential: applicationDefault(),
      projectId,
      serviceAccountId: `firebase-adminsdk-fbsvc@${projectId}.iam.gserviceaccount.com`,
    }),
  );
  const customToken = await step('custom token', () => getAuth().createCustomToken(uid));
  const session = await step('sign in', async () => {
    const response = await fetch(
      `https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${encodeURIComponent(apiKey)}`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'X-Ios-Bundle-Identifier': bundleId },
        body: JSON.stringify({ token: customToken, returnSecureToken: true }),
      },
    );
    const body = (await response.json()) as { idToken?: string; expiresIn?: string; error?: { message?: string } };
    if (!response.ok || !body.idToken || !body.expiresIn) {
      throw new Error(body.error?.message ?? `HTTP ${response.status}`);
    }
    return { idToken: body.idToken, expiresAt: Date.now() + Number(body.expiresIn) * 1000 };
  });
  const appCheck = await step('app check token', () =>
    getAppCheck().createToken(appId, { ttlMillis: appCheckTtlMillis }),
  );
  const appCheckExpiresAt = Date.now() + appCheck.ttlMillis;
  process.stdout.write(
    `${JSON.stringify({
      uid,
      idToken: session.idToken,
      appCheckToken: appCheck.token,
      expiresAt: Math.min(session.expiresAt, appCheckExpiresAt),
    })}\n`,
  );
}

main().catch((error: unknown) => {
  const name = error instanceof StepError ? error.step : 'unexpected';
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`dev-test-identity: ${name}: ${message}\n`);
  process.exit(1);
});

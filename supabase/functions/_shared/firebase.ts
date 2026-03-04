/**
 * Shared Firebase utilities for Edge Functions.
 *
 * Uses FCM v1 HTTP API with service account JWT auth.
 * Requires FIREBASE_SERVICE_ACCOUNT_KEY secret (JSON string).
 */

/** Encode a Uint8Array to base64url (no padding). */
function base64url(data: Uint8Array): string {
  const b64 = btoa(String.fromCharCode(...data));
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

interface ServiceAccount {
  project_id: string;
  private_key: string;
  client_email: string;
}

interface FcmMessage {
  token: string;
  title: string;
  body: string;
  data?: Record<string, string>;
}

interface FcmSendResult {
  token: string;
  success: boolean;
  stale: boolean;
  error?: string;
}

/** Load Firebase service account from Supabase secret (base64-encoded). */
export function getServiceAccount(): ServiceAccount {
  const b64 = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_KEY_B64");
  if (!b64) {
    throw new Error("FIREBASE_SERVICE_ACCOUNT_KEY_B64 secret is not set");
  }
  const json = atob(b64);
  return JSON.parse(json) as ServiceAccount;
}

/** Create a signed JWT for Google OAuth2 token exchange. */
async function createSignedJwt(sa: ServiceAccount): Promise<string> {
  const header = { alg: "RS256", typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: sa.client_email,
    sub: sa.client_email,
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
  };

  const encoder = new TextEncoder();
  const headerB64 = base64url(encoder.encode(JSON.stringify(header)));
  const payloadB64 = base64url(encoder.encode(JSON.stringify(payload)));
  const signingInput = `${headerB64}.${payloadB64}`;

  // Import the PEM private key
  const pemContents = sa.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\n/g, "");
  const binaryKey = Uint8Array.from(atob(pemContents), (c) => c.charCodeAt(0));

  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    encoder.encode(signingInput),
  );

  const signatureB64 = base64url(new Uint8Array(signature));
  return `${signingInput}.${signatureB64}`;
}

/** Exchange signed JWT for an OAuth2 access token. */
export async function getAccessToken(sa: ServiceAccount): Promise<string> {
  const jwt = await createSignedJwt(sa);

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`OAuth2 token exchange failed: ${res.status} ${text}`);
  }

  const data = await res.json();
  return data.access_token as string;
}

/**
 * Send a single FCM message via the v1 REST API.
 *
 * Returns a result indicating success, or whether the token is stale
 * (UNREGISTERED / NOT_FOUND) and should be cleaned up.
 */
export async function sendFcmMessage(
  accessToken: string,
  projectId: string,
  message: FcmMessage,
): Promise<FcmSendResult> {
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

  const body = {
    message: {
      token: message.token,
      notification: {
        title: message.title,
        body: message.body,
      },
      ...(message.data && { data: message.data }),
    },
  };

  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });

    if (res.ok) {
      return { token: message.token, success: true, stale: false };
    }

    const errorData = await res.json().catch(() => null);
    const errorCode = errorData?.error?.details?.[0]?.errorCode ?? "";
    const stale =
      errorCode === "UNREGISTERED" ||
      errorCode === "NOT_FOUND" ||
      res.status === 404;

    return {
      token: message.token,
      success: false,
      stale,
      error: `${res.status}: ${JSON.stringify(errorData)}`,
    };
  } catch (err) {
    return {
      token: message.token,
      success: false,
      stale: false,
      error: String(err),
    };
  }
}

/**
 * send-notification Edge Function
 *
 * Sends a push notification to all of a user's registered devices.
 *
 * POST body: { user_id: string, title: string, body: string, data?: Record<string, string> }
 * Returns:   { sent: number, total: number, staleTokensCleaned: number }
 *
 * Uses the service role to bypass RLS for reading tokens and cleaning stale ones.
 */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  getAccessToken,
  getServiceAccount,
  sendFcmMessage,
} from "../_shared/firebase.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const { user_id, title, body, data } = await req.json();

    if (!user_id || !title || !body) {
      return new Response(
        JSON.stringify({ error: "user_id, title, and body are required" }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }

    // Service role client — bypasses RLS
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Fetch all FCM tokens for the user
    const { data: tokens, error: fetchError } = await supabase
      .from("fcm_tokens")
      .select("token")
      .eq("user_id", user_id);

    if (fetchError) {
      throw new Error(`Failed to fetch tokens: ${fetchError.message}`);
    }

    if (!tokens || tokens.length === 0) {
      return new Response(
        JSON.stringify({ sent: 0, total: 0, staleTokensCleaned: 0 }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }

    // Get Firebase access token
    const sa = getServiceAccount();
    const accessToken = await getAccessToken(sa);

    // Send to all devices in parallel
    const results = await Promise.all(
      tokens.map((t: { token: string }) =>
        sendFcmMessage(accessToken, sa.project_id, {
          token: t.token,
          title,
          body,
          data,
        }),
      ),
    );

    // Clean up stale tokens
    const staleTokens = results
      .filter((r) => r.stale)
      .map((r) => r.token);

    if (staleTokens.length > 0) {
      await supabase
        .from("fcm_tokens")
        .delete()
        .in("token", staleTokens);
    }

    const sent = results.filter((r) => r.success).length;

    return new Response(
      JSON.stringify({
        sent,
        total: tokens.length,
        staleTokensCleaned: staleTokens.length,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("send-notification error:", err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});

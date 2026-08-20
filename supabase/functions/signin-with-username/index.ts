// supabase/functions/signin-with-username/index.ts
//
// Sign in with USERNAME + password. The client can't map username → email
// itself (emails live in auth.users, which anon can't read — and exposing
// an email column on profiles would let anyone harvest username → email).
// This function does the mapping server-side with the service role and
// performs the password grant, so emails never leave the backend and a
// bad username / bad password both return the same generic error.
//
// Deploy:
//   supabase functions deploy signin-with-username --no-verify-jwt
//
// POST { "username": "...", "password": "..." }
//   → 200 with the /auth/v1/token JSON (access_token, refresh_token, user)
//   → 400 { "error_description": "Invalid login credentials" } otherwise

// deno-lint-ignore-file no-explicit-any

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const INVALID = new Response(
  JSON.stringify({ error_description: "Invalid login credentials" }),
  { status: 400, headers: { "Content-Type": "application/json" } },
);

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  let username = "";
  let password = "";
  try {
    const body = await req.json();
    username = String(body.username ?? "").trim();
    password = String(body.password ?? "");
  } catch {
    return INVALID.clone();
  }
  if (!username || !password) return INVALID.clone();

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Case-insensitive username → user id. Usernames aren't unique-constrained
  // in the schema, so take the OLDEST profile with that name (first claim).
  const { data: profiles, error: profileError } = await admin
    .from("profiles")
    .select("id, created_at")
    .ilike("username", username)
    .order("created_at", { ascending: true })
    .limit(1);
  if (profileError || !profiles || profiles.length === 0) {
    return INVALID.clone();
  }

  // Resolve the account email via the auth admin API.
  const { data: userData, error: userError } = await admin.auth.admin
    .getUserById(profiles[0].id);
  const email = userData?.user?.email;
  if (userError || !email) return INVALID.clone();

  // Standard password grant with the ANON key — the response (including
  // error shapes like unconfirmed-email) is exactly what the app's normal
  // email sign-in already parses, so pass it through verbatim.
  const tokenResponse = await fetch(
    `${SUPABASE_URL}/auth/v1/token?grant_type=password`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: ANON_KEY,
        Authorization: `Bearer ${ANON_KEY}`,
      },
      body: JSON.stringify({ email, password }),
    },
  );
  const payload = await tokenResponse.text();
  return new Response(payload, {
    status: tokenResponse.status,
    headers: { "Content-Type": "application/json" },
  });
});

// Creates a real login account plus a workers row for a new team member.
// Has to live server-side (not a plain RLS policy) because it must call
// auth.admin.createUser before any workers row can legally exist
// (workers.auth_user_id is a not-null FK to auth.users), and that call
// needs the service role key, which must never reach the browser.
//
// Authorization is enforced here, not by RLS: the caller's own worker row
// (looked up from their JWT via the anon-key client) decides what they may
// create. manager may only create role 'employee' inside their own team.
// executive/hc_admin may create any role, with or without a team. Every
// other combination is rejected before any write happens.
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function randomPassword(): string {
  const bytes = new Uint8Array(18);
  crypto.getRandomValues(bytes);
  return "Nusva-" + btoa(String.fromCharCode(...bytes)).replace(/[+/=]/g, "").slice(0, 16);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "not authenticated" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Caller-scoped client (RLS applies): only trusted to tell us who is calling.
  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await callerClient.auth.getUser();
  if (userErr || !userData?.user) return json({ error: "not authenticated" }, 401);

  const { data: caller, error: callerErr } = await callerClient
    .from("workers")
    .select("id, tenant_id, team_id, role")
    .eq("auth_user_id", userData.user.id)
    .single();
  if (callerErr || !caller) return json({ error: "caller has no worker record" }, 403);
  if (!["manager", "executive", "hc_admin"].includes(caller.role)) {
    return json({ error: "not authorized to add team members" }, 403);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const fullName = typeof body.full_name === "string" ? body.full_name.trim() : "";
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const role = typeof body.role === "string" ? body.role : "";
  // A manager only ever has one team to add people to, so default to it
  // instead of making the frontend pass back a value it already knows.
  const teamId = body.team_id ?? (caller.role === "manager" ? caller.team_id : null);

  if (!fullName) return json({ error: "full_name is required" }, 400);
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ error: "a valid email is required" }, 400);
  if (!["employee", "manager", "executive", "hc_admin"].includes(role)) {
    return json({ error: "invalid role" }, 400);
  }

  // manager: locked to their own team, employee role only.
  if (caller.role === "manager") {
    if (role !== "employee") return json({ error: "managers can only add employees" }, 403);
    if (teamId !== caller.team_id) return json({ error: "managers can only add to their own team" }, 403);
  }
  // executive/hc_admin: any role. employee/manager still need a real team in this tenant.
  if (["employee", "manager"].includes(role)) {
    if (!teamId) return json({ error: "team_id is required for this role" }, 400);
  }

  const admin = createClient(supabaseUrl, serviceKey);

  if (teamId) {
    const { data: team, error: teamErr } = await admin
      .from("teams")
      .select("id")
      .eq("id", teamId)
      .eq("tenant_id", caller.tenant_id)
      .single();
    if (teamErr || !team) return json({ error: "team not found in this tenant" }, 400);
  }

  const tempPassword = randomPassword();
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    password: tempPassword,
    email_confirm: true,
  });
  if (createErr || !created?.user) {
    const msg = createErr?.message?.includes("already been registered")
      ? "an account with this email already exists"
      : (createErr?.message || "could not create the login account");
    return json({ error: msg }, 400);
  }

  const { data: worker, error: workerErr } = await admin
    .from("workers")
    .insert({
      tenant_id: caller.tenant_id,
      auth_user_id: created.user.id,
      full_name: fullName,
      role,
      team_id: teamId,
    })
    .select("id, full_name, role, team_id")
    .single();

  if (workerErr || !worker) {
    // Roll back the orphaned auth account so a failed worker insert never
    // leaves a login with no matching worker row behind.
    await admin.auth.admin.deleteUser(created.user.id);
    return json({ error: workerErr?.message || "could not create worker record" }, 500);
  }

  return json({ worker, email, temp_password: tempPassword });
});

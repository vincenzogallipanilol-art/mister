// Invia notifiche push a tutti gli iscritti. Solo admin (verificato con il JWT del chiamante).
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization")! } } });
    const { data: u } = await asUser.auth.getUser();
    if (!u?.user) return new Response("unauthorized", { status: 401, headers: cors });
    const { data: adm } = await asUser.rpc("is_admin");
    if (!adm) return new Response("forbidden", { status: 403, headers: cors });

    const { title, body, url: link } = await req.json();
    webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com", Deno.env.get("VAPID_PUBLIC")!, Deno.env.get("VAPID_PRIVATE")!);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: subs } = await admin.from("push_subs").select("endpoint,sub");
    const payload = JSON.stringify({ title, body, url: link || "/" });
    let sent = 0;
    await Promise.all((subs ?? []).map(async (s) => {
      try { await webpush.sendNotification(s.sub, payload); sent++; }
      catch (e) { if (e.statusCode === 404 || e.statusCode === 410) await admin.from("push_subs").delete().eq("endpoint", s.endpoint); }
    }));
    return new Response(JSON.stringify({ sent }), { headers: { ...cors, "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(String(e), { status: 500, headers: cors });
  }
});

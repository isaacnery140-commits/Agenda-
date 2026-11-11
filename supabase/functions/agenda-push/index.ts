// Envia notificações (Web Push) para os celulares inscritos na agenda.
// Só aceita chamadas do próprio banco, que mandam o segredo guardado em agenda_config.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const APP_URL = "https://isaacnery140-commits.github.io/Agenda-/index.html";
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const { data: cfg } = await sb.from("agenda_config")
    .select("vapid_public,vapid_private,push_secret").eq("id", 1).single();
  if (!cfg?.push_secret || req.headers.get("x-agenda-secret") !== cfg.push_secret) return json({ error: "forbidden" }, 403);
  webpush.setVapidDetails(APP_URL, cfg.vapid_public, cfg.vapid_private);

  const body = await req.json().catch(() => ({}));
  let messages: { title: string; body: string; agenda_id?: string; exclude?: string }[] = [];
  if (body.kind === "send") {
    messages = [{ title: String(body.title ?? "Agenda a Dois"), body: String(body.body ?? ""), agenda_id: body.agenda_id, exclude: String(body.exclude ?? "") }];
  } else if (body.kind === "reminders") {
    const { data, error } = await sb.rpc("agenda_due_reminders");
    if (error) return json({ error: error.message }, 500);
    messages = data ?? [];
  } else return json({ error: "kind" }, 400);
  if (!messages.length) return json({ sent: 0, failed: 0 });

  let sent = 0, failed = 0;
  const statuses: number[] = [];
  for (const m of messages) {
    if (!m.agenda_id) continue;
    const { data: subs } = await sb.from("agenda_push_subs").select("endpoint,p256dh,auth,name").eq("agenda_id", m.agenda_id);
    const ex = (m.exclude ?? "").trim().toLowerCase();
    const targets = (subs ?? []).filter((s) => !ex || s.name.trim().toLowerCase() !== ex);
    await Promise.all(targets.map(async (s) => {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          JSON.stringify({ title: m.title, body: m.body, url: APP_URL }),
          { TTL: 3600, urgency: "high" },
        );
        sent++;
      } catch (e) {
        failed++;
        const code = (e as { statusCode?: number }).statusCode ?? 0;
        statuses.push(code);
        if (code === 404 || code === 410) await sb.from("agenda_push_subs").delete().eq("endpoint", s.endpoint);
      }
    }));
  }
  return json({ sent, failed, statuses });
});

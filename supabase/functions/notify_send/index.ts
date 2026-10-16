// Pengirim notifikasi email Nusva Work lewat Resend.
//
// Dipanggil pg_cron (pg_net) tiap 5 menit kalau ada email yang jatuh tempo di email_outbox (migration 050). Bukan untuk browser:
// verify_jwt dimatikan, dan setiap panggilan wajib membawa header x-notify-secret yang dicocokkan dengan rahasia di Vault lewat
// RPC notify_secret_ok (rahasianya tidak pernah keluar dari database). Fungsi ini memakai service role hanya untuk tiga RPC
// pengirim: notify_claim (ambil dan kunci antrean, sekaligus melewati alamat demo, preferensi mati, dan tugas yang sudah selesai),
// notify_mark (tandai terkirim atau jadwalkan ulang), notify_health_set (catat hasil putaran supaya layar bisa jujur).
//
// Semua email yang tertunda untuk satu orang digabung menjadi satu email per putaran. Isi email hanya nama tugas, nama orang yang
// memicu, dan deadline; isi komentar dan catatan revisi tidak pernah dikirim.
//
// Rahasia yang dibutuhkan: RESEND_API_KEY. Opsional: NOTIFY_FROM (bawaan "Nusva Work <onboarding@resend.dev>", alamat uji Resend
// yang hanya bisa mengirim ke email pemilik akun Resend sampai domain diverifikasi) dan NOTIFY_APP_URL (bawaan alamat produksi).
// Tanpa kunci, fungsi menjawab 503 not_configured tanpa menyentuh antrean.
import { createClient } from "jsr:@supabase/supabase-js@2";

type Row = {
  id: string; worker_id: string; email: string; full_name: string | null; lang: string; kind: string;
  payload: Record<string, unknown> | null; actor_name: string | null; title: { id?: string; en?: string } | string | null;
  due_at: string | null; item_status: string | null; workspace: string; created_at: string;
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function esc(s: string) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function titleOf(r: Row, lang: "id" | "en") {
  const t = r.title;
  const s = typeof t === "string" ? t : (t?.[lang] || t?.id || t?.en || "");
  return s.replace(/\u2014/g, ",").replace(/\s+/g, " ").trim().slice(0, 200);
}

function dueText(iso: string | null, lang: "id" | "en") {
  if (!iso) return "";
  const d = new Date(iso);
  const f = new Intl.DateTimeFormat(lang === "id" ? "id-ID" : "en-GB", {
    day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false, timeZone: "Asia/Jakarta",
  }).format(d).replace(/,/g, "");
  return `${f} WIB`;
}

const TXT = {
  id: {
    someone: "Seseorang",
    assigned: (a: string, t: string) => `${a} menugaskan tugas ke Anda: ${t}.`,
    mention: (a: string, t: string) => `${a} menyebut Anda di tugas ${t}.`,
    approvalRequest: (a: string, t: string) => `${a} minta persetujuan untuk tugas ${t}.`,
    approved: (a: string, t: string) => `${a} menyetujui tugas ${t}.`,
    revise: (a: string, t: string) => `${a} minta revisi untuk tugas ${t}.`,
    digest: (today: number, overdue: number) =>
      `Ringkasan pagi: ${today} tugas dengan deadline hari ini, ${overdue} tugas terlambat.`,
    due: (d: string) => `Deadline ${d}.`,
    subjectAssigned: (t: string) => `Tugas baru untuk Anda: ${t}`,
    subjectMention: (a: string) => `${a} menyebut Anda di Nusva Work`,
    subjectApprovalRequest: (t: string) => `Minta persetujuan: ${t}`,
    subjectApproved: (t: string) => `Tugas disetujui: ${t}`,
    subjectRevise: (t: string) => `Perlu revisi: ${t}`,
    subjectDigest: (today: number, overdue: number) => `Hari ini: ${today} deadline, ${overdue} terlambat`,
    subjectMany: (n: number) => `${n} pembaruan tugas untuk Anda`,
    open: "Buka Nusva Work",
    hello: (n: string) => `Halo ${n},`,
    footer: "Anda menerima email ini karena notifikasi email di Nusva Work menyala. Atur di Nusva Work: menu profil, Notifikasi email. " +
      "Email yang muncul pukul 21.00 sampai 06.00 WIB dikirim setelah pukul 06.00. Isi komentar dan catatan tidak disertakan.",
  },
  en: {
    someone: "Someone",
    assigned: (a: string, t: string) => `${a} assigned you a task: ${t}.`,
    mention: (a: string, t: string) => `${a} mentioned you on the task ${t}.`,
    approvalRequest: (a: string, t: string) => `${a} asked for approval on the task ${t}.`,
    approved: (a: string, t: string) => `${a} approved the task ${t}.`,
    revise: (a: string, t: string) => `${a} asked for changes on the task ${t}.`,
    digest: (today: number, overdue: number) => `Morning summary: ${today} tasks due today, ${overdue} overdue.`,
    due: (d: string) => `Due ${d}.`,
    subjectAssigned: (t: string) => `New task for you: ${t}`,
    subjectMention: (a: string) => `${a} mentioned you in Nusva Work`,
    subjectApprovalRequest: (t: string) => `Approval requested: ${t}`,
    subjectApproved: (t: string) => `Task approved: ${t}`,
    subjectRevise: (t: string) => `Changes requested: ${t}`,
    subjectDigest: (today: number, overdue: number) => `Today: ${today} due, ${overdue} overdue`,
    subjectMany: (n: number) => `${n} task updates for you`,
    open: "Open Nusva Work",
    hello: (n: string) => `Hi ${n},`,
    footer: "You get this email because email notifications are on in Nusva Work. Change them in Nusva Work: profile menu, Email notifications. " +
      "Emails raised between 21.00 and 06.00 WIB are sent after 06.00. Comment and note text is never included.",
  },
};

function lineOf(r: Row, lang: "id" | "en") {
  const x = TXT[lang];
  const a = (r.actor_name || x.someone).trim();
  const t = titleOf(r, lang);
  const p = r.payload || {};
  switch (r.kind) {
    case "ASSIGNED": {
      const d = dueText(r.due_at, lang);
      return { line: x.assigned(a, t) + (d ? " " + x.due(d) : ""), subject: x.subjectAssigned(t) };
    }
    case "MENTION":
      return { line: x.mention(a, t), subject: x.subjectMention(a) };
    case "APPROVAL_REQUEST":
      return { line: x.approvalRequest(a, t), subject: x.subjectApprovalRequest(t) };
    case "APPROVAL_DECIDED":
      return p.decision === "APPROVED"
        ? { line: x.approved(a, t), subject: x.subjectApproved(t) }
        : { line: x.revise(a, t), subject: x.subjectRevise(t) };
    case "DIGEST": {
      const today = Number(p.today) || 0, overdue = Number(p.overdue) || 0;
      return { line: x.digest(today, overdue), subject: x.subjectDigest(today, overdue) };
    }
    default:
      return null;
  }
}

function render(rows: Row[], appUrl: string) {
  const lang: "id" | "en" = rows[0].lang === "en" ? "en" : "id";
  const x = TXT[lang];
  const items = rows.map((r) => ({ r, l: lineOf(r, lang) })).filter((i) => i.l);
  if (!items.length) return null;
  const ws = items.some((i) => i.r.workspace === "manager") ? "manager" : "employee";
  const link = `${appUrl.replace(/\/+$/, "")}/#${ws}/kerja`;
  const subject = items.length === 1 ? items[0].l!.subject : x.subjectMany(items.length);
  const name = (rows[0].full_name || "").trim();
  const lines = items.map((i) => i.l!.line);
  const text = [...(name ? [x.hello(name), ""] : []), ...lines.map((l) => `- ${l}`), "", `${x.open}: ${link}`, "", x.footer].join("\n");
  const html = `<!doctype html><html lang="${lang}"><body style="margin:0;padding:24px;background:#FFFFFF;font-family:'Plus Jakarta Sans',-apple-system,'Segoe UI',Roboto,sans-serif;font-weight:400;color:#1D1D1F">
<div style="max-width:560px;margin:0 auto;background:#FFFFFF;border:1px solid #DCE2E5;border-radius:16px;padding:24px">
<p style="margin:0 0 4px;font-size:12px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:#6B6B70">Nusva Work</p>
${name ? `<p style="margin:0 0 16px;font-size:14px;line-height:1.5">${esc(x.hello(name))}</p>` : ""}
<ul style="margin:0 0 20px;padding-left:20px;font-size:14px;line-height:1.5">${lines.map((l) => `<li style="margin:0 0 8px">${esc(l)}</li>`).join("")}</ul>
<a href="${esc(link)}" style="display:inline-block;padding:10px 16px;border-radius:6px;background:#0D7883;color:#FFFFFF;font-size:14px;font-weight:600;text-decoration:none">${esc(x.open)}</a>
<p style="margin:24px 0 0;font-size:12px;line-height:1.5;color:#6B6B70">${esc(x.footer)}</p>
</div></body></html>`;
  return { subject, text, html, ids: items.map((i) => i.r.id) };
}

async function idemKey(ids: string[]) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ids.slice().sort().join(",")));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 48);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  const secret = req.headers.get("x-notify-secret") || "";
  if (!secret) return json({ error: "not authorized" }, 401);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: ok, error: okErr } = await admin.rpc("notify_secret_ok", { p_secret: secret });
  if (okErr || ok !== true) return json({ error: "not authorized" }, 401);

  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) {
    await admin.rpc("notify_health_set", { p_status: "not_configured", p_error: null });
    return json({ error: "not_configured" }, 503);
  }
  const from = Deno.env.get("NOTIFY_FROM") || "Nusva Work <onboarding@resend.dev>";
  const appUrl = Deno.env.get("NOTIFY_APP_URL") || "https://nusvapeople-task.vercel.app";

  const { data: rows, error: claimErr } = await admin.rpc("notify_claim", { p_limit: 50 });
  if (claimErr) {
    console.error("notify_send: claim gagal", claimErr.message);
    return json({ error: "claim_failed" }, 500);
  }
  const groups = new Map<string, Row[]>();
  for (const r of (rows || []) as Row[]) {
    const g = groups.get(r.worker_id) || [];
    g.push(r);
    groups.set(r.worker_id, g);
  }

  let sent = 0, failed = 0, authFail = false;
  let lastErr = "";
  for (const g of groups.values()) {
    const mail = render(g, appUrl);
    if (!mail) {
      await admin.rpc("notify_mark", { p_ids: g.map((r) => r.id), p_ok: false, p_error: "nothing to render" });
      continue;
    }
    try {
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${key}`,
          "Content-Type": "application/json",
          "Idempotency-Key": await idemKey(mail.ids),
        },
        body: JSON.stringify({ from, to: [g[0].email], subject: mail.subject, html: mail.html, text: mail.text }),
      });
      if (res.ok) {
        await admin.rpc("notify_mark", { p_ids: mail.ids, p_ok: true, p_error: null });
        sent++;
      } else {
        let name = "", msg = "";
        try {
          const b = await res.json();
          name = typeof b?.name === "string" ? b.name : "";
          msg = typeof b?.message === "string" ? b.message.replace(/\s+/g, " ").slice(0, 200) : "";
        } catch { /* abaikan */ }
        lastErr = `${res.status} ${name} ${msg}`.trim();
        if (res.status === 401 || res.status === 403) authFail = true;
        console.error("notify_send: Resend menolak", res.status, name, msg);
        await admin.rpc("notify_mark", { p_ids: mail.ids, p_ok: false, p_error: lastErr });
        failed++;
      }
    } catch (e) {
      lastErr = (e as Error)?.name ?? "fetch error";
      console.error("notify_send: fetch ke Resend gagal", lastErr);
      await admin.rpc("notify_mark", { p_ids: mail.ids, p_ok: false, p_error: lastErr });
      failed++;
    }
  }

  await admin.rpc("notify_health_set", {
    p_status: failed && (authFail || !sent) ? "failing" : "ok",
    p_error: failed ? lastErr : null,
  });
  return json({ sent, failed, recipients: groups.size });
});

// ============================================================================
//  Edge Function: criar-tecnico
//  Cria (ou REDEFINE a senha de) o login de um técnico no Supabase Auth.
//  - Só o ADMIN pode chamar (verificado pelo perfil 'admin' em public.perfis).
//  - O segredo (service_role) fica SÓ aqui no servidor, nunca no app.
//  - O app chama com SB.functions.invoke('criar-tecnico', { body: {...} }).
//
//  Publicar (sem instalar nada):
//   Supabase -> Edge Functions -> Deploy a new function -> nome "criar-tecnico"
//   -> cole este arquivo -> Deploy. As variáveis SUPABASE_URL / SUPABASE_ANON_KEY
//   / SUPABASE_SERVICE_ROLE_KEY já vêm preenchidas automaticamente.
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function gerarSenha(): string {
  // sem caracteres ambíguos (0/O, 1/l/I) — fácil de ditar no campo
  const cs = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  let s = "";
  for (let i = 0; i < 10; i++) s += cs[Math.floor(Math.random() * cs.length)];
  return s;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "use POST" });

  try {
    const URL = Deno.env.get("SUPABASE_URL");
    const ANON = Deno.env.get("SUPABASE_ANON_KEY");
    const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!URL || !ANON || !SERVICE) {
      return json(500, { error: "função sem variáveis de ambiente (URL/ANON/SERVICE_ROLE)" });
    }

    // 1) Quem está chamando precisa ser ADMIN (usa o token do próprio usuário) -----
    const authHeader = req.headers.get("Authorization") || "";
    if (!authHeader) return json(401, { error: "não autenticado" });
    const asCaller = createClient(URL, ANON, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: ures, error: uerr } = await asCaller.auth.getUser();
    if (uerr || !ures?.user) return json(401, { error: "sessão inválida — entre de novo" });
    const { data: perfil } = await asCaller
      .from("perfis").select("papel").eq("user_id", ures.user.id).single();
    if (perfil?.papel !== "admin") {
      return json(403, { error: "só o administrador pode criar/redefinir acesso de técnico" });
    }

    // 2) Cria ou redefine o login com o service_role -----------------------------
    const body = await req.json().catch(() => ({} as Record<string, unknown>));
    const email = String(body.email || "").trim().toLowerCase();
    const nome = body.nome ? String(body.nome).trim() : null;
    let senha = body.senha ? String(body.senha) : "";
    if (!email || !email.includes("@")) return json(400, { error: "e-mail inválido" });
    if (!senha) senha = gerarSenha();
    if (senha.length < 6) return json(400, { error: "a senha precisa de pelo menos 6 caracteres" });

    const admin = createClient(URL, SERVICE);

    // já existe esse e-mail? (lista paginada; equipe pequena)
    let existing: { id: string; user_metadata?: Record<string, unknown> } | undefined;
    const { data: list } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
    existing = list?.users?.find(
      (u: { email?: string }) => (u.email || "").toLowerCase() === email,
    ) as typeof existing;

    let userId: string;
    let criado = false;
    if (existing) {
      const { error } = await admin.auth.admin.updateUserById(existing.id, {
        password: senha,
        email_confirm: true,
        user_metadata: { ...(existing.user_metadata || {}), nome: nome ?? existing.user_metadata?.nome },
      });
      if (error) return json(400, { error: "falha ao redefinir a senha: " + error.message });
      userId = existing.id;
    } else {
      const { data: created, error } = await admin.auth.admin.createUser({
        email,
        password: senha,
        email_confirm: true, // já entra sem precisar confirmar e-mail
        user_metadata: { nome },
      });
      if (error || !created?.user) {
        return json(400, { error: "falha ao criar o acesso: " + (error?.message || "desconhecido") });
      }
      userId = created.user.id;
      criado = true;
    }

    // 3) Garante o perfil 'tecnico' (papel vale no banco/RLS) --------------------
    await admin.from("perfis").upsert(
      { user_id: userId, email, nome, papel: "tecnico" },
      { onConflict: "user_id" },
    );

    return json(200, { ok: true, criado, redefinido: !criado, email, senha, nome });
  } catch (e) {
    return json(500, { error: String((e as Error)?.message || e) });
  }
});

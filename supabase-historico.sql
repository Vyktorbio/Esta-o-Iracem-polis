-- ============================================================================
--  HISTÓRICO DA NUVEM — funções p/ o app LISTAR e RESTAURAR versões antigas
--  Cole TUDO isto no Supabase  ->  SQL Editor  ->  New query  ->  Run.
--  É seguro rodar mais de uma vez (idempotente). NÃO apaga nenhum dado.
--
--  Depende da tabela public.app_state_history, que já é criada pela blindagem
--  (arquivo supabase-blindagem.sql). O gatilho de lá guarda a versão anterior
--  a cada gravação; estas duas funções só permitem LER esse histórico (com
--  segurança, via SECURITY DEFINER) para o app mostrar e restaurar.
-- ============================================================================

-- 1) Lista as versões guardadas (mais recentes primeiro) + um resumo de cada
create or replace function public.app_state_history_list(n int default 60)
returns table(hid bigint, rev int, saved_at timestamptz, quadras int, locais int, estudos int)
language sql security definer set search_path = public as $$
  select h.hid, h.rev, h.saved_at,
    (select count(*)::int from jsonb_object_keys(coalesce(h.state->'qgeo','{}'::jsonb))),
    (select count(*)::int from jsonb_object_keys(coalesce(h.state->'locais','{}'::jsonb))),
    (select coalesce(sum(jsonb_array_length(coalesce(v->'estudos','[]'::jsonb))),0)::int
       from jsonb_each(coalesce(h.state->'data','{}'::jsonb)) as e(k,v))
  from public.app_state_history h
  order by h.hid desc
  limit greatest(1, least(coalesce(n,60), 200));
$$;
grant execute on function public.app_state_history_list(int) to anon, authenticated;

-- 2) Devolve o ESTADO completo de UMA versão (o app aplica + reenvia p/ a nuvem)
create or replace function public.app_state_history_get(h bigint)
returns jsonb language sql security definer set search_path = public as $$
  select state from public.app_state_history where hid = h;
$$;
grant execute on function public.app_state_history_get(bigint) to anon, authenticated;

-- Pronto. No app:  ☰ menu  ->  "Histórico da nuvem"  ->  Restaurar.
-- (Restaurar guarda o estado atual antes — nada é perdido — e pede a senha.)

-- ============================================================================
--  BLINDAGEM RLS — Agracta  (trava de acesso REAL no banco)
--  Deixa a tabela public.app_state acessível SÓ para usuários AUTENTICADOS.
--  Hoje o anônimo ainda grava (transição); isto fecha essa porta.
--
--  ⚠️  RODE SÓ DEPOIS que TODOS os aparelhos da equipe tiverem feito login
--      pelo menos uma vez no app (a sessão fica salva no aparelho).
--      Se um aparelho não estiver logado, ele PARA de gravar/ler após isto
--      (é o objetivo — mas confirme que todos logaram para ninguém travar no campo).
--
--  Cole TUDO no Supabase -> SQL Editor -> New query -> Run.
--  Combina com a closed-signup (só o admin cria contas em Authentication -> Users):
--  signup fechado + RLS autenticado = só quem você cadastrou entra.
-- ============================================================================

alter table public.app_state enable row level security;

-- Remove TODAS as policies atuais da app_state (inclusive as que liberam anônimo)
do $$
declare p record;
begin
  for p in select policyname from pg_policies
           where schemaname='public' and tablename='app_state' loop
    execute format('drop policy if exists %I on public.app_state', p.policyname);
  end loop;
end $$;

-- Recria o acesso SÓ para 'authenticated' (logado). 'anon' fica sem acesso.
create policy app_state_auth_select on public.app_state
  for select to authenticated using (true);
create policy app_state_auth_insert on public.app_state
  for insert to authenticated with check (true);
create policy app_state_auth_update on public.app_state
  for update to authenticated using (true) with check (true);

-- Pronto. O gatilho de blindagem (app_state_guard) e o histórico continuam valendo.

-- ----------------------------------------------------------------------------
-- ROLLBACK DE EMERGÊNCIA (se algum aparelho essencial não conseguir logar e
-- você precisar voltar a liberar temporariamente). Rode SÓ se precisar:
--
--   create policy app_state_anon_tmp on public.app_state
--     for all to anon using (true) with check (true);
--
-- E remova de novo quando todos logarem:
--   drop policy if exists app_state_anon_tmp on public.app_state;
-- ----------------------------------------------------------------------------

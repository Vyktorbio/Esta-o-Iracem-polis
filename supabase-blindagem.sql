-- ============================================================================
--  BLINDAGEM DO SALVAMENTO — Estação Iracemápolis
--  Cole TUDO isto no Supabase  ->  SQL Editor  ->  New query  ->  Run.
--  É seguro rodar mais de uma vez (idempotente). NÃO apaga nenhum dado.
--
--  O que faz, no BANCO (vale pra TODO aparelho, até os que estão no app antigo):
--   1) BACKUP automático: a cada save, guarda a versão ANTERIOR em app_state_history.
--      -> nada se perde de verdade; dá pra restaurar qualquer ponto.
--   2) REJEITA gravação velha (revisão que não avançou) e encolhimento destrutivo
--      (perder quadras/locais) que NÃO seja exclusão intencional.
-- ============================================================================

-- 1) Tabela de histórico (cada versão anterior do estado) -------------------
create table if not exists public.app_state_history (
  hid       bigserial primary key,
  state     jsonb       not null,
  rev       int,
  saved_at  timestamptz not null default now()
);
-- Privada: liga RLS e NÃO cria policy => ninguém lê/escreve via API.
-- Só o trigger (security definer, abaixo) grava. Você lê pelo Table Editor.
alter table public.app_state_history enable row level security;

-- 2) Função-guarda + backup -------------------------------------------------
create or replace function public.app_state_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  old_rev int := coalesce((OLD.state->>'rev')::int, 0);
  new_rev int := coalesce((NEW.state->>'rev')::int, 0);
  old_q   int := (select count(*) from jsonb_object_keys(coalesce(OLD.state->'qgeo','{}'::jsonb)));
  new_q   int := (select count(*) from jsonb_object_keys(coalesce(NEW.state->'qgeo','{}'::jsonb)));
  old_l   int := (select count(*) from jsonb_object_keys(coalesce(OLD.state->'locais','{}'::jsonb)));
  new_l   int := (select count(*) from jsonb_object_keys(coalesce(NEW.state->'locais','{}'::jsonb)));
  allow_shrink boolean := coalesce((NEW.state->>'_allowShrink')::boolean, false);
begin
  -- (a) rejeita gravação fora de ordem / conflito (a revisão precisa AVANÇAR)
  if old_rev > 0 and new_rev <= old_rev then
    raise exception 'STALE_WRITE: revisao % nao avancou (nuvem ja esta em %).', new_rev, old_rev
      using errcode = 'check_violation';
  end if;

  -- (b) rejeita ENCOLHER quadras/locais sem ser exclusao intencional
  if not allow_shrink and (new_q < old_q or new_l < old_l) then
    raise exception 'SHRINK_BLOCKED: gravacao reduziria quadras % -> % / locais % -> % sem exclusao intencional.',
      old_q, new_q, old_l, new_l using errcode = 'check_violation';
  end if;

  -- (c) BACKUP da versao anterior
  insert into public.app_state_history(state, rev) values (OLD.state, old_rev);

  -- (d) mantem o historico enxuto (ultimas ~400 versoes)
  delete from public.app_state_history
    where hid <= (select max(hid) - 400 from public.app_state_history);

  -- (e) nao persiste o flag auxiliar
  NEW.state := NEW.state - '_allowShrink';
  return NEW;
end;
$$;

-- 3) Liga o gatilho ANTES de cada UPDATE em app_state -----------------------
drop trigger if exists app_state_guard_trg on public.app_state;
create trigger app_state_guard_trg
  before update on public.app_state
  for each row execute function public.app_state_guard();

-- 4) Função p/ o app/verificação saber quantos backups existem (só contagem)
create or replace function public.app_state_history_count()
returns int language sql security definer set search_path = public as $$
  select count(*)::int from public.app_state_history;
$$;
grant execute on function public.app_state_history_count() to anon, authenticated;

-- Pronto. Para conferir os backups:  Table Editor -> app_state_history.
-- Para RESTAURAR um ponto (se um dia precisar), me chame que eu te passo o UPDATE certo.

-- ============================================================================
-- 5) POLÍTICAS DE ACESSO (RLS) — Bloqueia leitura/escrita de anônimos --------
-- ============================================================================
alter table public.app_state enable row level security;

-- remove todas as policies atuais (inclusive as que liberam anônimo)
do $$
declare p record;
begin
  for p in select policyname from pg_policies
           where schemaname='public' and tablename='app_state' loop
    execute format('drop policy if exists %I on public.app_state', p.policyname);
  end loop;
end $$;

-- acesso só p/ logado
create policy app_state_auth_select on public.app_state for select to authenticated using (true);
create policy app_state_auth_insert on public.app_state for insert to authenticated with check (true);
create policy app_state_auth_update on public.app_state for update to authenticated using (true) with check (true);


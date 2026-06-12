-- ============================================================================
--  FASE 4 / ETAPA 1 — MODELO NORMALIZADO (tabelas + papéis + tempo real)
--  Cole TUDO isto no Supabase -> SQL Editor -> New query -> Run.
--  É seguro rodar mais de uma vez (idempotente). NÃO mexe no app_state (blob)
--  nem no app atual — nada muda para os aparelhos até a etapa de corte.
--
--  O que cria:
--   1) perfis           — quem é admin e quem é técnico (papéis valem no BANCO)
--   2) locais/quadras/estudos          — estrutura (só admin escreve)
--   3) aplicacoes/avaliacoes/lancamentos/notas_campo — trabalho de campo
--      (técnico também escreve). Cada LANÇAMENTO = 1 linha por
--      avaliação+parcela+variável, com QUEM avaliou — dois técnicos dividindo
--      um estudo (pares/ímpares) nunca se sobrescrevem.
--   4) LWW por linha     — gravação mais velha que a existente é IGNORADA
--      (aparelho que ficou dias offline não atropela o que está mais novo)
--   5) Soft delete       — excluir = marcar deleted_at (nada some de verdade;
--      sem lápide eterna: recriar nunca colide, ids são sempre únicos)
--   6) Realtime por linha — cada tabela publica só a linha alterada
-- ============================================================================

-- 1) PAPÉIS -----------------------------------------------------------------
create table if not exists public.perfis (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  email     text unique not null,
  nome      text,
  papel     text not null default 'tecnico' check (papel in ('admin','tecnico')),
  criado_em timestamptz not null default now()
);
alter table public.perfis enable row level security;

-- novo usuário criado no painel -> ganha perfil 'tecnico' automaticamente
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfis (user_id, email)
  values (new.id, coalesce(new.email, new.id::text))
  on conflict (user_id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- usuários que JÁ existem -> perfil agora (admin = e-mail do administrador)
insert into public.perfis (user_id, email, papel)
select id, coalesce(email, id::text),
       case when lower(coalesce(email,'')) = 'machadovictorchaves@gmail.com'
            then 'admin' else 'tecnico' end
from auth.users
on conflict (user_id) do nothing;
-- p/ promover alguém depois:
--   update public.perfis set papel='admin' where email='fulano@exemplo.com';

create or replace function public.papel_atual()
returns text language sql stable security definer set search_path = public as $$
  select papel from public.perfis where user_id = auth.uid()
$$;
create or replace function public.eh_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select papel from public.perfis where user_id = auth.uid()) = 'admin', false)
$$;

-- 2) GUARDA DE SINCRONIZAÇÃO (LWW por linha) --------------------------------
-- client_ts = carimbo (ms) de quando a edição foi feita NO APARELHO.
-- Se chegar uma gravação mais VELHA que a da linha atual, ela é ignorada.
create or replace function public.sync_guard()
returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE'
     and new.client_ts is not null and old.client_ts is not null
     and new.client_ts < old.client_ts then
    return null;  -- gravação obsoleta: mantém o que está (mais novo vence)
  end if;
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end $$;

-- 3) TABELAS ----------------------------------------------------------------
create table if not exists public.locais (
  id         text primary key,
  nome       text not null,
  centro     jsonb,
  zoom       numeric,   -- zoom contínuo do mapa (pode ser fracionário, ex.: 17.92)
  extras     jsonb not null default '{}',
  client_ts  bigint,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  deleted_at timestamptz
);

create table if not exists public.quadras (
  id         text primary key,
  local_id   text not null references public.locais(id),
  nome       text not null,
  geo        jsonb,                       -- polígono [[lat,lng],...]
  area_ha    numeric,
  culturas   jsonb not null default '[]', -- [{cultura,cultivar,plantio},...] (1ª = principal)
  extras     jsonb not null default '{}',
  client_ts  bigint,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  deleted_at timestamptz
);

create table if not exists public.estudos (
  id             text primary key,
  quadra_id      text not null references public.quadras(id),
  codigo         text,
  nome           text,
  descricao      text,
  data_inicio    date,
  num_aplicacoes int,
  intervalo_dias int,
  num_repeticoes int,
  tratamentos    jsonb not null default '[]',
  randomizacao   jsonb,
  audit          jsonb not null default '[]',
  extras         jsonb not null default '{}',
  client_ts      bigint,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  deleted_at     timestamptz
);

create table if not exists public.aplicacoes (
  id         text primary key,
  estudo_id  text not null references public.estudos(id),
  data       date,
  bbch       text,
  obs        text,
  carimbo    jsonb,                       -- clima/NDVI/GPS no momento (BPL)
  extras     jsonb not null default '{}',
  client_ts  bigint,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  deleted_at timestamptz
);

create table if not exists public.avaliacoes (
  id         text primary key,
  estudo_id  text not null references public.estudos(id),
  data       date,
  tipo       text,
  bbch       text,
  obs        text,
  auto       boolean not null default false,  -- slot planejado gerado pelo app
  variaveis  jsonb not null default '[]',     -- ["severidade","altura",...]
  tipos      jsonb not null default '{}',     -- {"severidade":"pct",...}
  carimbo    jsonb,
  extras     jsonb not null default '{}',
  client_ts  bigint,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  deleted_at timestamptz
);

-- O CORAÇÃO DO MULTIUSUÁRIO: 1 linha por célula da grade, com o autor.
-- Dois técnicos dividindo as parcelas nunca tocam nas linhas um do outro.
create table if not exists public.lancamentos (
  avaliacao_id    text not null references public.avaliacoes(id),
  parcela         text not null,         -- ex.: "T2:B" (tratamento:repetição)
  variavel        text not null,
  valor           text,                  -- null = célula limpa
  avaliador       uuid,
  avaliador_email text,
  client_ts       bigint,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (avaliacao_id, parcela, variavel)
);

create table if not exists public.notas_campo (
  id           text primary key,
  local_id     text,
  quadra_id    text,
  lat          double precision,
  lng          double precision,
  titulo       text,
  categoria    text,
  severidade   text,
  recomendacao text,
  descricao    text,
  foto_url     text,                     -- etapa 5: Storage; até lá, foto_b64
  foto_b64     text,
  criado_em    date,
  resolvido    boolean not null default false,
  extras       jsonb not null default '{}',
  client_ts    bigint,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  deleted_at   timestamptz
);

create table if not exists public.randomizacoes (
  id         text primary key,
  nome       text,
  dados      jsonb not null default '{}',
  client_ts  bigint,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  deleted_at timestamptz
);

create table if not exists public.config (
  id         int primary key default 1 check (id = 1),
  dados      jsonb not null default '{}',
  client_ts  bigint,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into public.config (id) values (1) on conflict (id) do nothing;

-- 4) ÍNDICES (sincronização delta + navegação) ------------------------------
create index if not exists idx_quadras_local      on public.quadras(local_id);
create index if not exists idx_estudos_quadra     on public.estudos(quadra_id);
create index if not exists idx_aplicacoes_estudo  on public.aplicacoes(estudo_id);
create index if not exists idx_avaliacoes_estudo  on public.avaliacoes(estudo_id);
create index if not exists idx_lanc_avaliacao     on public.lancamentos(avaliacao_id);
create index if not exists idx_notas_quadra       on public.notas_campo(quadra_id);
create index if not exists idx_locais_upd         on public.locais(updated_at);
create index if not exists idx_quadras_upd        on public.quadras(updated_at);
create index if not exists idx_estudos_upd        on public.estudos(updated_at);
create index if not exists idx_aplicacoes_upd     on public.aplicacoes(updated_at);
create index if not exists idx_avaliacoes_upd     on public.avaliacoes(updated_at);
create index if not exists idx_lanc_upd           on public.lancamentos(updated_at);
create index if not exists idx_notas_upd          on public.notas_campo(updated_at);

-- 5) GUARDA LWW EM TODAS AS TABELAS -----------------------------------------
do $$
declare t text;
begin
  foreach t in array array['locais','quadras','estudos','aplicacoes',
                           'avaliacoes','lancamentos','notas_campo',
                           'randomizacoes','config'] loop
    execute format('drop trigger if exists sync_guard_trg on public.%I', t);
    execute format('create trigger sync_guard_trg before insert or update on public.%I
                    for each row execute function public.sync_guard()', t);
  end loop;
end $$;

-- 6) RLS — PAPÉIS VALEM NO BANCO --------------------------------------------
-- Leitura: qualquer usuário LOGADO lê tudo (anônimo não lê nada).
-- Estrutura (locais/quadras/estudos/randomizacoes/config): só ADMIN escreve.
-- Campo (aplicacoes/avaliacoes/lancamentos/notas_campo): TÉCNICO também.
-- Não existe DELETE pela API: excluir é marcar deleted_at (soft delete).
do $$
declare t text; p record;
begin
  foreach t in array array['locais','quadras','estudos','aplicacoes',
                           'avaliacoes','lancamentos','notas_campo',
                           'randomizacoes','config','perfis'] loop
    execute format('alter table public.%I enable row level security', t);
    for p in select policyname from pg_policies
             where schemaname='public' and tablename=t loop
      execute format('drop policy if exists %I on public.%I', p.policyname, t);
    end loop;
    execute format('create policy %I_sel on public.%I for select to authenticated using (true)', t, t);
  end loop;

  foreach t in array array['locais','quadras','estudos','randomizacoes','config'] loop
    execute format('create policy %I_ins on public.%I for insert to authenticated with check (public.eh_admin())', t, t);
    execute format('create policy %I_upd on public.%I for update to authenticated using (public.eh_admin()) with check (public.eh_admin())', t, t);
  end loop;

  foreach t in array array['aplicacoes','avaliacoes','lancamentos','notas_campo'] loop
    execute format('create policy %I_ins on public.%I for insert to authenticated with check (public.papel_atual() in (''admin'',''tecnico''))', t, t);
    execute format('create policy %I_upd on public.%I for update to authenticated using (public.papel_atual() in (''admin'',''tecnico'')) with check (public.papel_atual() in (''admin'',''tecnico''))', t, t);
  end loop;

  -- perfis: só admin gerencia
  execute 'create policy perfis_ins on public.perfis for insert to authenticated with check (public.eh_admin())';
  execute 'create policy perfis_upd on public.perfis for update to authenticated using (public.eh_admin()) with check (public.eh_admin())';
end $$;

-- 7) TEMPO REAL POR LINHA ----------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['locais','quadras','estudos','aplicacoes',
                           'avaliacoes','lancamentos','notas_campo',
                           'randomizacoes','config'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception
      when duplicate_object then null;   -- já estava na publicação
      when undefined_object then null;   -- projeto sem a publicação padrão: realtime liga no painel
    end;
  end loop;
end $$;

-- Pronto. Conferir: Table Editor deve mostrar as 10 tabelas novas.
-- O app atual continua usando app_state normalmente — nada mudou para ele.

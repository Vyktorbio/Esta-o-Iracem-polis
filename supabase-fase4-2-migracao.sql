-- ============================================================================
--  FASE 4 / ETAPA 2 — MIGRAÇÃO: copia o blob (app_state) para as tabelas
--  Cole TUDO isto no Supabase -> SQL Editor -> New query -> Run.
--
--  - NÃO altera o app_state: o blob continua intacto, como backup congelado.
--  - É seguro rodar mais de uma vez: re-rodar ATUALIZA as tabelas com o que
--    estiver no blob naquele momento (vamos re-rodar no dia do corte).
--  - O app atual continua funcionando no blob — nada muda para os aparelhos.
--
--  O que copia:
--   locais, quadras (nome/local/polígono/culturas), estudos (protocolo),
--   aplicações, avaliações, lançamentos (cada célula da grade vira 1 linha,
--   com carimbo de quando foi digitada), notas de campo (com foto),
--   randomizações e config.
--  Pula quadras com lápide de exclusão mais nova que a criação (excluídas).
-- ============================================================================

-- datas podem vir como AAAA-MM-DD (padrão) ou DD/MM/AAAA (legado)
create or replace function public._f4_data(t text)
returns date language plpgsql immutable as $$
begin
  if t is null or t = '' then return null; end if;
  if t ~ '^\d{4}-\d{2}-\d{2}' then return left(t,10)::date; end if;
  if t ~ '^\d{2}/\d{2}/\d{4}$' then return to_date(t,'DD/MM/YYYY'); end if;
  return null;
exception when others then return null;
end $$;

do $$
declare
  st    jsonb;
  delq  jsonb;
  k     text;
  v     jsonb;
  qid   text;
  q     jsonb;
  est   jsonb;
  ap    jsonb;
  av    jsonb;
  parc  text;
  linha jsonb;
  vari  text;
  meta  jsonb;
  item  jsonb;
  n_loc int := 0; n_q int := 0; n_e int := 0; n_ap int := 0;
  n_av int := 0; n_lan int := 0; n_not int := 0; n_rz int := 0;
begin
  select state into st from public.app_state where id = 1;
  if st is null then
    raise exception 'app_state (id=1) vazio — nada para migrar.';
  end if;
  delq := coalesce(st->'_deletedQuadras', '{}'::jsonb);

  -- ---------------------------------------------------------------- LOCAIS
  for k, v in select * from jsonb_each(coalesce(st->'locais','{}'::jsonb)) loop
    insert into public.locais (id, nome, centro, zoom, client_ts)
    values (k, coalesce(v->>'nome', k), v->'centro', nullif(v->>'zoom','')::int,
            nullif(st->'locaists'->>k,'')::bigint)
    on conflict (id) do update
      set nome=excluded.nome, centro=excluded.centro, zoom=excluded.zoom,
          client_ts=excluded.client_ts;
    n_loc := n_loc + 1;
  end loop;
  insert into public.locais (id, nome) values ('iracemapolis','Estação Iracemápolis')
  on conflict (id) do nothing;

  -- ---------------------------------------------------------------- QUADRAS
  for qid in select jsonb_object_keys(coalesce(st->'qgeo','{}'::jsonb)) loop
    -- lápide mais nova que a criação = quadra excluída: não migra
    if delq ? qid and
       coalesce(nullif(st->'qgeots'->>qid,'')::bigint, 0)
         <= coalesce(nullif(delq->>qid,'')::bigint, 0) then
      continue;
    end if;
    q := coalesce(st->'data'->qid, '{}'::jsonb);

    -- garante que o local referenciado existe (cria casca se faltar)
    insert into public.locais (id, nome)
    values (coalesce(st->'qlocal'->>qid,'iracemapolis'),
            coalesce(st->'qlocal'->>qid,'iracemapolis'))
    on conflict (id) do nothing;

    insert into public.quadras (id, local_id, nome, geo, area_ha, culturas, extras, client_ts)
    values (
      qid,
      coalesce(st->'qlocal'->>qid, 'iracemapolis'),
      coalesce(st->'qnome'->>qid, qid),
      st->'qgeo'->qid,
      nullif(q->>'area','')::numeric,
      case
        when jsonb_typeof(q->'culturas')='array' and jsonb_array_length(q->'culturas')>0
          then q->'culturas'
        when coalesce(q->>'cultura','') <> ''
          then jsonb_build_array(jsonb_build_object(
                 'cultura',  q->>'cultura',
                 'cultivar', coalesce(q->>'cultivar',''),
                 'plantio',  coalesce(q->>'plantio','')))
        else '[]'::jsonb
      end,
      q - 'estudos' - 'culturas' - '_deletedStudies',
      coalesce(nullif(q->>'_ts','')::bigint, nullif(st->'qgeots'->>qid,'')::bigint)
    )
    on conflict (id) do update
      set local_id=excluded.local_id, nome=excluded.nome, geo=excluded.geo,
          area_ha=excluded.area_ha, culturas=excluded.culturas,
          extras=excluded.extras, client_ts=excluded.client_ts;
    n_q := n_q + 1;

    -- -------------------------------------------------------------- ESTUDOS
    if jsonb_typeof(q->'estudos')='array' then
      for est in select * from jsonb_array_elements(q->'estudos') loop
        continue when est->>'id' is null;
        insert into public.estudos (id, quadra_id, codigo, nome, descricao, data_inicio,
          num_aplicacoes, intervalo_dias, num_repeticoes, tratamentos, randomizacao,
          audit, extras, client_ts)
        values (
          est->>'id', qid, est->>'codigo', est->>'nome', est->>'descricao',
          public._f4_data(est->>'dataInicio'),
          nullif(est->>'numAplicacoes','')::int,
          nullif(est->>'intervaloDias','')::int,
          nullif(est->>'numRepeticoes','')::int,
          coalesce(est->'tratamentos','[]'::jsonb),
          est->'randomizacao',
          coalesce(est->'auditLog','[]'::jsonb),
          (est - 'aplicacoes' - 'avaliacoes' - 'tratamentos' - 'randomizacao' - 'auditLog'
               - 'id' - 'codigo' - 'nome' - 'descricao' - 'dataInicio'
               - 'numAplicacoes' - 'intervaloDias' - 'numRepeticoes'),
          nullif(est->>'_ts','')::bigint
        )
        on conflict (id) do update
          set quadra_id=excluded.quadra_id, codigo=excluded.codigo, nome=excluded.nome,
              descricao=excluded.descricao, data_inicio=excluded.data_inicio,
              num_aplicacoes=excluded.num_aplicacoes, intervalo_dias=excluded.intervalo_dias,
              num_repeticoes=excluded.num_repeticoes, tratamentos=excluded.tratamentos,
              randomizacao=excluded.randomizacao, audit=excluded.audit,
              extras=excluded.extras, client_ts=excluded.client_ts;
        n_e := n_e + 1;

        -- --------------------------------------------------------- APLICAÇÕES
        if jsonb_typeof(est->'aplicacoes')='array' then
          for ap in select * from jsonb_array_elements(est->'aplicacoes') loop
            continue when ap->>'id' is null;
            insert into public.aplicacoes (id, estudo_id, data, bbch, obs, carimbo, extras, client_ts)
            values (
              ap->>'id', est->>'id', public._f4_data(ap->>'data'),
              ap->>'bbch', ap->>'obs', ap->'carimbo',
              (ap - 'id' - 'data' - 'bbch' - 'obs' - 'carimbo'),
              nullif(ap->>'_ts','')::bigint
            )
            on conflict (id) do update
              set estudo_id=excluded.estudo_id, data=excluded.data, bbch=excluded.bbch,
                  obs=excluded.obs, carimbo=excluded.carimbo, extras=excluded.extras,
                  client_ts=excluded.client_ts;
            n_ap := n_ap + 1;
          end loop;
        end if;

        -- --------------------------------------------------------- AVALIAÇÕES
        if jsonb_typeof(est->'avaliacoes')='array' then
          for av in select * from jsonb_array_elements(est->'avaliacoes') loop
            continue when av->>'id' is null;
            insert into public.avaliacoes (id, estudo_id, data, tipo, bbch, obs, auto,
              variaveis, tipos, carimbo, extras, client_ts)
            values (
              av->>'id', est->>'id', public._f4_data(av->>'data'),
              av->>'tipo', av->>'bbch', av->>'obs',
              coalesce((av->>'auto')::boolean, false),
              coalesce(av->'variaveis','[]'::jsonb),
              coalesce(av->'tipos','{}'::jsonb),
              av->'carimbo',
              (av - 'id' - 'data' - 'tipo' - 'bbch' - 'obs' - 'auto'
                  - 'variaveis' - 'tipos' - 'carimbo' - 'notas' - 'notasMeta'),
              nullif(av->>'_ts','')::bigint
            )
            on conflict (id) do update
              set estudo_id=excluded.estudo_id, data=excluded.data, tipo=excluded.tipo,
                  bbch=excluded.bbch, obs=excluded.obs, auto=excluded.auto,
                  variaveis=excluded.variaveis, tipos=excluded.tipos,
                  carimbo=excluded.carimbo, extras=excluded.extras,
                  client_ts=excluded.client_ts;
            n_av := n_av + 1;

            -- ------------------------------------------- LANÇAMENTOS (células)
            if jsonb_typeof(av->'notas')='object' then
              for parc, linha in select * from jsonb_each(av->'notas') loop
                continue when jsonb_typeof(linha) <> 'object';
                for vari in select jsonb_object_keys(linha) loop
                  continue when coalesce(linha->>vari,'') = '';
                  meta := av->'notasMeta'->parc->vari;
                  insert into public.lancamentos
                    (avaliacao_id, parcela, variavel, valor, client_ts)
                  values (
                    av->>'id', parc, vari, linha->>vari,
                    nullif(meta->>'ts','')::bigint
                  )
                  on conflict (avaliacao_id, parcela, variavel) do update
                    set valor=excluded.valor, client_ts=excluded.client_ts;
                  n_lan := n_lan + 1;
                end loop;
              end loop;
            end if;
          end loop;
        end if;
      end loop;
    end if;
  end loop;

  -- ---------------------------------------------------------- NOTAS DE CAMPO
  if jsonb_typeof(st->'notas_campo')='array' then
    for item in select * from jsonb_array_elements(st->'notas_campo') loop
      continue when item->>'id' is null;
      insert into public.notas_campo (id, local_id, quadra_id, lat, lng, titulo,
        categoria, severidade, recomendacao, descricao, foto_b64, criado_em,
        resolvido, extras, client_ts)
      values (
        item->>'id', item->>'localId', item->>'quadraId',
        nullif(item->>'lat','')::double precision,
        nullif(item->>'lng','')::double precision,
        item->>'titulo', item->>'categoria', item->>'severidade',
        item->>'recomendacao', item->>'descricao', item->>'foto',
        public._f4_data(item->>'criadoEm'),
        coalesce((item->>'resolvido')::boolean, false),
        (item - 'id' - 'localId' - 'quadraId' - 'lat' - 'lng' - 'titulo'
              - 'categoria' - 'severidade' - 'recomendacao' - 'descricao'
              - 'foto' - 'criadoEm' - 'resolvido'),
        nullif(item->>'_ts','')::bigint
      )
      on conflict (id) do update
        set local_id=excluded.local_id, quadra_id=excluded.quadra_id,
            lat=excluded.lat, lng=excluded.lng, titulo=excluded.titulo,
            categoria=excluded.categoria, severidade=excluded.severidade,
            recomendacao=excluded.recomendacao, descricao=excluded.descricao,
            foto_b64=excluded.foto_b64, criado_em=excluded.criado_em,
            resolvido=excluded.resolvido, extras=excluded.extras,
            client_ts=excluded.client_ts;
      n_not := n_not + 1;
    end loop;
  end if;

  -- ----------------------------------------------------------- RANDOMIZAÇÕES
  if jsonb_typeof(st->'randomizacoes')='array' then
    for item in select * from jsonb_array_elements(st->'randomizacoes') loop
      insert into public.randomizacoes (id, nome, dados)
      values (coalesce(item->>'id', md5(item::text)), item->>'nome', item)
      on conflict (id) do update set nome=excluded.nome, dados=excluded.dados;
      n_rz := n_rz + 1;
    end loop;
  end if;

  -- ------------------------------------------------------------------ CONFIG
  if st->'data'->'__config' is not null then
    insert into public.config (id, dados) values (1, st->'data'->'__config')
    on conflict (id) do update set dados=excluded.dados;
  end if;

  raise notice 'MIGRADO: % locais, % quadras, % estudos, % aplicações, % avaliações, % lançamentos, % notas, % randomizações',
    n_loc, n_q, n_e, n_ap, n_av, n_lan, n_not, n_rz;
end $$;

drop function if exists public._f4_data(text);

-- Conferência: o que ficou em cada tabela
select 'locais' as tabela, count(*) as linhas from public.locais
union all select 'quadras',       count(*) from public.quadras
union all select 'estudos',       count(*) from public.estudos
union all select 'aplicacoes',    count(*) from public.aplicacoes
union all select 'avaliacoes',    count(*) from public.avaliacoes
union all select 'lancamentos',   count(*) from public.lancamentos
union all select 'notas_campo',   count(*) from public.notas_campo
union all select 'randomizacoes', count(*) from public.randomizacoes
order by 1;

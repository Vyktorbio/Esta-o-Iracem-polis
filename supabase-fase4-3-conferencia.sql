-- ============================================================================
--  FASE 4 / CONFERÊNCIA — compara o blob (app_state) com as tabelas migradas
--  Cole no SQL Editor -> Run. SÓ LEITURA: não altera nada.
--  Cada linha mostra: o que o blob tem vs. o que as tabelas têm.
--  Tudo "✓ confere" = migração fiel.
-- ============================================================================
with st as (select state s from public.app_state where id = 1),

blob_locais as (
  select count(*)::int n from st, jsonb_object_keys(coalesce(s->'locais','{}'::jsonb))
),
-- quadras vivas no blob (descarta as com lápide mais nova que a criação)
blob_quadras as (
  select count(*)::int n from st, jsonb_object_keys(coalesce(s->'qgeo','{}'::jsonb)) k
  where not ( coalesce(s->'_deletedQuadras','{}'::jsonb) ? k
              and coalesce(round(nullif(s->'qgeots'->>k,'')::numeric)::bigint,0)
                  <= coalesce(nullif(s->'_deletedQuadras'->>k,'')::bigint,0) )
),
blob_estudos as (
  select count(*)::int n
  from st, jsonb_each(coalesce(s->'data','{}'::jsonb)) q,
       jsonb_array_elements(case when jsonb_typeof(q.value->'estudos')='array'
                                 then q.value->'estudos' else '[]'::jsonb end) e
  where q.key <> '__config' and e->>'id' is not null
    and not ( coalesce(s->'_deletedQuadras','{}'::jsonb) ? q.key
              and coalesce(round(nullif(s->'qgeots'->>q.key,'')::numeric)::bigint,0)
                  <= coalesce(nullif(s->'_deletedQuadras'->>q.key,'')::bigint,0) )
),
blob_apl as (
  select count(*)::int n
  from st, jsonb_each(coalesce(s->'data','{}'::jsonb)) q,
       jsonb_array_elements(case when jsonb_typeof(q.value->'estudos')='array'
                                 then q.value->'estudos' else '[]'::jsonb end) e,
       jsonb_array_elements(case when jsonb_typeof(e->'aplicacoes')='array'
                                 then e->'aplicacoes' else '[]'::jsonb end) a
  where q.key <> '__config' and a->>'id' is not null
    and not ( coalesce(s->'_deletedQuadras','{}'::jsonb) ? q.key
              and coalesce(round(nullif(s->'qgeots'->>q.key,'')::numeric)::bigint,0)
                  <= coalesce(nullif(s->'_deletedQuadras'->>q.key,'')::bigint,0) )
),
blob_aval as (
  select count(*)::int n
  from st, jsonb_each(coalesce(s->'data','{}'::jsonb)) q,
       jsonb_array_elements(case when jsonb_typeof(q.value->'estudos')='array'
                                 then q.value->'estudos' else '[]'::jsonb end) e,
       jsonb_array_elements(case when jsonb_typeof(e->'avaliacoes')='array'
                                 then e->'avaliacoes' else '[]'::jsonb end) a
  where q.key <> '__config' and a->>'id' is not null
    and not ( coalesce(s->'_deletedQuadras','{}'::jsonb) ? q.key
              and coalesce(round(nullif(s->'qgeots'->>q.key,'')::numeric)::bigint,0)
                  <= coalesce(nullif(s->'_deletedQuadras'->>q.key,'')::bigint,0) )
),
-- células preenchidas (cada uma deve virar 1 lançamento)
blob_lanc as (
  select count(*)::int n
  from st, jsonb_each(coalesce(s->'data','{}'::jsonb)) q,
       jsonb_array_elements(case when jsonb_typeof(q.value->'estudos')='array'
                                 then q.value->'estudos' else '[]'::jsonb end) e,
       jsonb_array_elements(case when jsonb_typeof(e->'avaliacoes')='array'
                                 then e->'avaliacoes' else '[]'::jsonb end) a,
       jsonb_each(case when jsonb_typeof(a->'notas')='object'
                       then a->'notas' else '{}'::jsonb end) p,
       jsonb_each_text(case when jsonb_typeof(p.value)='object'
                            then p.value else '{}'::jsonb end) c
  where q.key <> '__config' and a->>'id' is not null
    and coalesce(c.value,'') <> ''
    and not ( coalesce(s->'_deletedQuadras','{}'::jsonb) ? q.key
              and coalesce(round(nullif(s->'qgeots'->>q.key,'')::numeric)::bigint,0)
                  <= coalesce(nullif(s->'_deletedQuadras'->>q.key,'')::bigint,0) )
),
blob_notas as (
  select case when jsonb_typeof(s->'notas_campo')='array'
              then jsonb_array_length(s->'notas_campo') else 0 end::int n from st
),
blob_rz as (
  select case when jsonb_typeof(s->'randomizacoes')='array'
              then jsonb_array_length(s->'randomizacoes') else 0 end::int n from st
),

comp as (
  select 'locais' tabela,        (select n from blob_locais) no_blob,
         (select count(*)::int from public.locais l where exists (select 1 from st where s->'locais' ? l.id)) nas_tabelas
  union all
  select 'quadras',              (select n from blob_quadras),         (select count(*)::int from public.quadras)
  union all
  select 'estudos',              (select n from blob_estudos),         (select count(*)::int from public.estudos)
  union all
  select 'aplicacoes',           (select n from blob_apl),             (select count(*)::int from public.aplicacoes)
  union all
  select 'avaliacoes',           (select n from blob_aval),            (select count(*)::int from public.avaliacoes)
  union all
  select 'lancamentos (células)',(select n from blob_lanc),            (select count(*)::int from public.lancamentos)
  union all
  select 'notas_campo',          (select n from blob_notas),           (select count(*)::int from public.notas_campo)
  union all
  select 'randomizacoes',        (select n from blob_rz),              (select count(*)::int from public.randomizacoes)
)
select tabela, no_blob, nas_tabelas,
       case when no_blob = nas_tabelas then '✓ confere'
            else '⚠ DIFERENÇA' end as status
from comp
order by tabela;

-- A executer dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Peut etre relance sans risque. Partie 1 sur 3 : a executer dans l'ordre.
--
-- Pastille "decision rendue" : colonne decision_lue_le, qc_marquer_lue(),
-- qc_compteurs().

-- ---------------------------------------------------------------------------
-- 1. Decision rendue
-- ---------------------------------------------------------------------------
alter table qc_evaluations add column if not exists decision_lue_le timestamptz;

create or replace function public.qc_marquer_lue(p_evaluation_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update qc_evaluations
     set statut = case when statut = 'publiee' then 'lue' else statut end,
         lue_le = coalesce(lue_le, now()),
         decision_lue_le = case when arbitree_le is not null then coalesce(decision_lue_le, now()) else decision_lue_le end
   where id = p_evaluation_id
     and agent_id = auth.uid()
     and (statut = 'publiee' or (arbitree_le is not null and decision_lue_le is null));
end;
$function$;

create or replace function public.qc_compteurs()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_moi uuid := auth.uid();
  v_role text;
  v_contestations integer := 0;
begin
  select role into v_role from profils where id = v_moi;
  if v_role in ('superviseur', 'admin', 'super_admin') then
    select count(*) into v_contestations from qc_evaluations
     where statut = 'contestee' and agent_id in (select agent_id from mon_perimetre_agents());
  end if;
  return jsonb_build_object(
    'a_traiter', (select count(*) from qc_evaluations
                   where agent_id = v_moi and statut in ('publiee', 'lue')
                     and created_at >= now() - interval '7 days'),
    'decisions', (select count(*) from qc_evaluations
                   where agent_id = v_moi and arbitree_le is not null and decision_lue_le is null),
    'non_lues', (select count(*) from qc_evaluations where agent_id = v_moi and statut = 'publiee'),
    'contestations', v_contestations
  );
end;
$function$;

notify pgrst, 'reload schema';

-- Attendu : colonne_decision_lue_le = 1, compteur_decisions = true.
select
  (select count(*) from information_schema.columns
    where table_name = 'qc_evaluations' and column_name = 'decision_lue_le') as colonne_decision_lue_le,
  (select pg_get_functiondef('public.qc_compteurs'::regproc) like '%decisions%') as compteur_decisions;

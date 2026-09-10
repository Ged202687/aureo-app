-- À exécuter une seule fois dans l'éditeur SQL de Supabase (Dashboard > SQL Editor).
-- RPC utilisée par le nouveau bloc "Évolution" sous Mes résultats : agrège les
-- qualifications par semaine ou par mois, sur le même périmètre que le reste des
-- rapports (mon_perimetre_agents — agent seul, coach + son équipe, superviseur,
-- admin, super admin selon le rôle de l'appelant).

create or replace function public.evolution_resultats(p_granularite text, p_debut date, p_fin date)
returns table(
  periode date,
  fiches_traitees integer,
  contacts integer,
  ventes integer,
  rechargements_valides integer
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_trunc text;
begin
  v_trunc := case when p_granularite = 'mois' then 'month' else 'week' end;

  return query
    select
      date_trunc(v_trunc, q.created_at)::date as periode,
      count(q.id)::int as fiches_traitees,
      count(q.id) filter (where tq.est_contact)::int as contacts,
      count(q.id) filter (where tq.est_vente)::int as ventes,
      count(q.id) filter (where tq.motif = 'Rechargement validé')::int as rechargements_valides
    from qualifications q
    join types_qualification tq on tq.id = q.type_qualification_id
    where q.agent_id in (select agent_id from mon_perimetre_agents())
      and q.created_at >= p_debut
      and q.created_at < (p_fin + 1)
    group by 1
    order by 1;
end;
$function$;

grant execute on function public.evolution_resultats(text, date, date) to authenticated;

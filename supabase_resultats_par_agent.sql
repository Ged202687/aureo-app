-- À exécuter une seule fois dans l'éditeur SQL de Supabase (Dashboard > SQL Editor).
-- Ajoute la RPC utilisée par "Mes résultats" côté admin/super admin pour afficher le
-- détail par agent (fiches traitées, fiches contactées, rechargements validés), sur les
-- mêmes dates que les compteurs globaux déjà affichés (même logique de correspondance de
-- date et même périmètre d'agents que mes_resultats, pour rester cohérent).

create or replace function public.resultats_par_agent(p_dates date[])
returns table(agent_id uuid, nom text, fiches_traitees integer, fiches_contactees integer, rechargements_valides integer)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select
    p.id as agent_id,
    p.nom,
    count(q.id)::int as fiches_traitees,
    count(q.id) filter (where tq.est_contact)::int as fiches_contactees,
    count(q.id) filter (where tq.motif = 'Rechargement validé')::int as rechargements_valides
  from profils p
  left join qualifications q on q.agent_id = p.id and q.created_at::date = any(p_dates)
  left join types_qualification tq on tq.id = q.type_qualification_id
  where p.id in (select agent_id from mon_perimetre_agents())
  group by p.id, p.nom
  order by fiches_traitees desc, p.nom asc;
$function$;

grant execute on function public.resultats_par_agent(date[]) to authenticated;

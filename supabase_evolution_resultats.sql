-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- RPC utilisee par l'onglet "Analytics" : agrege les qualifications par semaine ou
-- par mois, sur le meme perimetre que le reste des rapports (mon_perimetre_agents).
-- Ajoute un filtre optionnel par campagne et par equipe.
--
-- Remplace la version initiale (text, date, date) par une version a 5 parametres.

drop function if exists public.evolution_resultats(text, date, date);

create or replace function public.evolution_resultats(
  p_granularite text,
  p_debut date,
  p_fin date,
  p_campagne_id uuid default null,
  p_equipe_id uuid default null
)
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
    join profils p on p.id = q.agent_id
    left join clients c on c.id = q.client_id
    left join lots l on l.id = c.lot_id
    where q.agent_id in (select agent_id from mon_perimetre_agents())
      and q.created_at >= p_debut
      and q.created_at < (p_fin + 1)
      and (p_campagne_id is null or l.campagne_id = p_campagne_id)
      and (p_equipe_id is null or p.equipe_id = p_equipe_id)
    group by 1
    order by 1;
end;
$function$;

grant execute on function public.evolution_resultats(text, date, date, uuid, uuid) to authenticated;

-- Liste des equipes visibles par l'appelant (memes regles que mon_perimetre_agents),
-- pour peupler le filtre "Equipe" de l'onglet Analytics.
create or replace function public.perimetre_equipes()
returns table(id uuid, nom text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select distinct e.id, e.nom
  from equipes e
  join profils p on p.equipe_id = e.id
  where p.id in (select agent_id from mon_perimetre_agents())
  order by e.nom;
$function$;

grant execute on function public.perimetre_equipes() to authenticated;

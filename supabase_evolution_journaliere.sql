-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- Refonte de l'onglet Analytics. L'ancienne version agregeait par semaine ou par
-- mois sur une plage libre : on obtenait 2 ou 3 points, illisibles, et la
-- derniere periode etant toujours en cours, la comparaison affichait une chute
-- imaginaire (une semaine complete comparee a une semaine d'un jour et demi).
--
-- Nouveau modele : on choisit une periode (une semaine, ou un mois) et le
-- graphe detaille les jours a l'interieur. La RPC renvoie donc une ligne par
-- jour, y compris les jours sans activite (generate_series), sinon la courbe
-- saute les week-ends et ment sur le rythme reel.
--
-- Nouveau filtre p_agent_id : suivre la progression d'un agent en particulier.
-- Le perimetre reste celui de mon_perimetre_agents, un agent filtre ne peut
-- donc jamais sortir de ce que le role autorise deja a voir.

drop function if exists public.evolution_resultats(text, date, date, uuid, uuid);

create or replace function public.evolution_resultats(
  p_debut date,
  p_fin date,
  p_campagne_id uuid default null,
  p_equipe_id uuid default null,
  p_agent_id uuid default null
)
returns table(
  jour date,
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
begin
  return query
  select
    d::date as jour,
    count(q.id)::int as fiches_traitees,
    count(q.id) filter (where tq.est_contact)::int as contacts,
    count(q.id) filter (where tq.est_vente)::int as ventes,
    count(q.id) filter (where tq.motif = 'Rechargement validé')::int as rechargements_valides
  from generate_series(p_debut::timestamptz, p_fin::timestamptz, interval '1 day') d
  left join (
    select q.id, q.created_at, q.type_qualification_id
    from qualifications q
    join profils pr on pr.id = q.agent_id
    left join clients c on c.id = q.client_id
    left join lots l on l.id = c.lot_id
    where q.agent_id in (select agent_id from mon_perimetre_agents())
      and (p_agent_id is null or q.agent_id = p_agent_id)
      and (p_campagne_id is null or l.campagne_id = p_campagne_id)
      and (p_equipe_id is null or pr.equipe_id = p_equipe_id)
      and q.created_at >= p_debut
      and q.created_at < (p_fin + 1)
  ) q on q.created_at >= d and q.created_at < d + interval '1 day'
  left join types_qualification tq on tq.id = q.type_qualification_id
  group by d
  order by d;
end;
$function$;

grant execute on function public.evolution_resultats(date, date, uuid, uuid, uuid) to authenticated;

-- Liste des agents visibles par l'appelant, pour peupler le filtre "Agent".
-- Meme perimetre que le reste des rapports. Passe par une RPC security definer
-- car la RLS de profils empeche un agent ou un coach de lire la ligne d'un
-- collegue (meme raison que historique_client).
create or replace function public.perimetre_agents_nommes()
returns table(id uuid, nom text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.id, p.nom::text
  from profils p
  where p.id in (select agent_id from mon_perimetre_agents())
  order by p.nom;
$function$;

revoke execute on function public.perimetre_agents_nommes() from public;
revoke execute on function public.perimetre_agents_nommes() from anon;
grant execute on function public.perimetre_agents_nommes() to authenticated;

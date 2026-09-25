-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Peut etre relance sans risque. S'execute d'un bloc : en cas d'erreur, rien
-- n'est modifie.
--
-- Distinguer, dans "Mes resultats", les ventes realisees par l'agent depuis
-- son poste de celles attribuees a partir d'une liste de rechargements
-- constates (liste MTN du 25/09/2026 : 2 363 ventes, attribuees au dernier
-- agent qui avait traite la box, ou reparties entre les agents).
--
--   - qualifications.origine : null pour une qualification faite depuis
--     l'application, 'liste' pour une vente attribuee depuis une liste. Les
--     2 363 ventes de la liste du 25/09 sont marquees ; une future liste le
--     sera de la meme facon ;
--   - resultats_par_agent() renvoie en plus rechargements_liste (type de
--     retour modifie, d'ou le drop prealable) ;
--   - mes_ventes_liste() donne a l'agent ses propres ventes issues d'une
--     liste, sur les dates choisies et sur le mois en cours.
-- Les totaux ne changent pas : les ventes issues d'une liste restent des
-- ventes, l'ecran les montre seulement a part.

alter table qualifications add column if not exists origine text;

comment on column qualifications.origine is
  'null : qualifiee depuis l''application. ''liste'' : vente attribuee depuis une liste de rechargements constates.';

update qualifications
   set origine = 'liste'
 where commentaire like 'Rechargement constaté (liste du 25/09/2026)%'
   and origine is distinct from 'liste';


drop function if exists public.resultats_par_agent(date[]);

create function public.resultats_par_agent(p_dates date[])
returns table(agent_id uuid, nom text, fiches_traitees integer, fiches_contactees integer,
              rechargements_valides integer, rechargements_liste integer)
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
    count(q.id) filter (where tq.motif = 'Rechargement validé')::int as rechargements_valides,
    count(q.id) filter (where tq.motif = 'Rechargement validé' and q.origine = 'liste')::int as rechargements_liste
  from profils p
  left join qualifications q on q.agent_id = p.id and q.created_at::date = any(p_dates)
  left join types_qualification tq on tq.id = q.type_qualification_id
  where p.id in (select agent_id from mon_perimetre_agents())
  group by p.id, p.nom
  order by fiches_traitees desc, p.nom asc;
$function$;

revoke execute on function public.resultats_par_agent(date[]) from public, anon;
grant execute on function public.resultats_par_agent(date[]) to authenticated;


create or replace function public.mes_ventes_liste(p_dates date[])
returns table(liste_dates integer, liste_mois integer)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select
    count(*) filter (where q.created_at::date = any(p_dates))::int,
    count(*) filter (where q.created_at >= date_trunc('month', now()))::int
  from qualifications q
  join types_qualification tq on tq.id = q.type_qualification_id
  where q.agent_id = auth.uid()
    and tq.motif = 'Rechargement validé'
    and q.origine = 'liste';
$function$;

revoke execute on function public.mes_ventes_liste(date[]) from public, anon;
grant execute on function public.mes_ventes_liste(date[]) to authenticated;


-- ---------------------------------------------------------------------------
-- Verification : l'editeur n'affiche que le resultat de la derniere requete.
-- Attendu : ventes_marquees_liste = 2363.
-- ---------------------------------------------------------------------------
notify pgrst, 'reload schema';

select
  (select count(*) from qualifications where origine = 'liste') as ventes_marquees_liste,
  (select count(*) from pg_proc where proname in ('resultats_par_agent', 'mes_ventes_liste')) as fonctions;

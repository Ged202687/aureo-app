-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Peut etre relance sans risque. S'execute d'un bloc : en cas d'erreur, rien
-- n'est modifie.
--
-- Une fiche qualifiee "Rechargement valide" reste verrouillee 30 jours : elle
-- ne doit ni revenir dans la file, ni etre reprise par un agent.
--
-- Depuis le 8 septembre, un trigger sur qualifications refuse toute nouvelle
-- qualification pendant ces 30 jours. Mais rien n'empechait la FICHE de
-- revenir en circuit, et plusieurs chemins le faisaient (mesure au
-- 24/09/2026, sur 5 898 fiches validees en 30 jours) :
--   - le recyclage (admin_recycler_fiches) et la liberation d'une fiche
--     bloquee la remettent "disponible", sans regarder le verrou ;
--   - des requalifications posees avant le 8 septembre ont remplace le delai
--     de 30 jours par un delai plus court ("Rappel sous 24h", "Occupe"...).
-- Resultat : 40 fiches disponibles, 32 planifiees pour revenir trop tot, et 3
-- fiches bloquees "en cours" chez des agents, qui ne peuvent pas les
-- qualifier puisque le trigger le refuse.
--
-- Correction en deux temps :
--   1. un trigger sur clients garantit le verrou quel que soit le chemin :
--        - une fiche verrouillee qu'on remet "disponible", ou qu'on planifie
--          pour revenir avant la fin du verrou, est replanifiee a la fin du
--          verrou ;
--        - la prendre "en cours" (file, recherche...) est refuse, avec la date
--          de fin du verrou ;
--   2. les 75 fiches actuelles sont remises en etat : planifiees, sans agent,
--      jusqu'a la fin de leur verrou.
-- Les fiches archivees ne sont pas concernees : elles ne reviennent jamais.


-- ---------------------------------------------------------------------------
-- 0. Index : le trigger cherche la derniere validation d'une fiche a chaque
--    changement de statut. Cree seulement si aucun index ne commence deja par
--    client_id.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public' and tablename = 'qualifications'
      and indexdef ~ '\(client_id[,)]'
  ) then
    create index qualifications_client_id_idx on qualifications (client_id, created_at desc);
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 1. Fin du verrou d'une fiche (null si elle n'est pas verrouillee)
-- ---------------------------------------------------------------------------
-- security definer : le trigger s'execute avec les droits de l'agent, qui ne
-- voit pas forcement les qualifications posees par ses collegues.
create or replace function public.fin_verrou_rechargement(p_client_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path to 'public'
as $function$
  select max(q.created_at) + interval '30 days'
  from qualifications q
  join types_qualification tq on tq.id = q.type_qualification_id
  where q.client_id = p_client_id
    and tq.categorie = 'Positif'
    and tq.motif = 'Rechargement validé'
    and q.created_at > now() - interval '30 days';
$function$;

revoke execute on function public.fin_verrou_rechargement(uuid) from public, anon;
grant execute on function public.fin_verrou_rechargement(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. Trigger sur clients
-- ---------------------------------------------------------------------------
create or replace function public.maintenir_verrou_rechargement()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_fin timestamptz;
begin
  if new.statut not in ('disponible', 'planifie', 'en_cours') then
    return new;
  end if;

  v_fin := fin_verrou_rechargement(new.id);
  if v_fin is null or v_fin <= now() then
    return new;
  end if;

  -- Prise d'une fiche verrouillee : refusee. Une fiche deja en cours chez le
  -- meme agent n'est pas recontrolee (on ne bloque que la prise).
  if new.statut = 'en_cours'
     and (tg_op = 'INSERT' or old.statut is distinct from 'en_cours' or old.agent_id is distinct from new.agent_id) then
    raise exception 'Cette fiche a été validée (rechargement) : elle est verrouillée jusqu''au %.',
      to_char(v_fin at time zone 'Africa/Abidjan', 'DD/MM/YYYY à HH24:MI');
  end if;

  -- Remise en circuit trop tot : replanifiee a la fin du verrou.
  if new.statut = 'disponible'
     or (new.statut = 'planifie' and (new.visible_apres is null or new.visible_apres < v_fin)) then
    new.statut := 'planifie';
    new.visible_apres := v_fin;
    new.agent_id := null;
  end if;

  return new;
end;
$function$;

revoke execute on function public.maintenir_verrou_rechargement() from public, anon, authenticated;

drop trigger if exists trg_maintenir_verrou_rechargement on clients;
create trigger trg_maintenir_verrou_rechargement
  before insert or update of statut, visible_apres, agent_id on clients
  for each row execute function public.maintenir_verrou_rechargement();


-- ---------------------------------------------------------------------------
-- 3. Remise en etat des fiches actuelles
-- ---------------------------------------------------------------------------
create temp table bilan_verrou on commit drop as
with verrous as (
  select q.client_id, max(q.created_at) + interval '30 days' as fin
  from qualifications q
  join types_qualification tq on tq.id = q.type_qualification_id
  where tq.categorie = 'Positif' and tq.motif = 'Rechargement validé'
    and q.created_at > now() - interval '30 days'
  group by q.client_id
)
select c.id, c.statut as statut_avant, v.fin
from clients c
join verrous v on v.client_id = c.id
where c.statut in ('disponible', 'en_cours')
   or (c.statut = 'planifie' and (c.visible_apres is null or c.visible_apres < v.fin));

update clients c
   set statut = 'planifie', visible_apres = b.fin, agent_id = null
  from bilan_verrou b
 where c.id = b.id;


-- ---------------------------------------------------------------------------
-- Verification : l'editeur n'affiche que le resultat de la derniere requete.
-- Attendu : fiches_remises_en_etat autour de 75 (dont 3 en cours, environ 40
-- disponibles), encore_mal_verrouillees = 0 et trigger_en_place = 1.
-- ---------------------------------------------------------------------------
notify pgrst, 'reload schema';

with verrous as (
  select q.client_id, max(q.created_at) + interval '30 days' as fin
  from qualifications q
  join types_qualification tq on tq.id = q.type_qualification_id
  where tq.categorie = 'Positif' and tq.motif = 'Rechargement validé'
    and q.created_at > now() - interval '30 days'
  group by q.client_id
)
select
  (select count(*) from bilan_verrou) as fiches_remises_en_etat,
  (select count(*) from bilan_verrou where statut_avant = 'en_cours') as dont_en_cours,
  (select count(*) from bilan_verrou where statut_avant = 'disponible') as dont_disponibles,
  (select count(*) from bilan_verrou where statut_avant = 'planifie') as dont_planifiees_trop_tot,
  (select count(*) from clients c join verrous v on v.client_id = c.id
     where c.statut in ('disponible', 'en_cours')
        or (c.statut = 'planifie' and (c.visible_apres is null or c.visible_apres < v.fin))) as encore_mal_verrouillees,
  (select count(*) from pg_trigger where tgname = 'trg_maintenir_verrou_rechargement') as trigger_en_place;

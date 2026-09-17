-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- Pour arreter un lot, il fallait jusqu'ici retirer ses cibles (agents ou
-- groupes) une par une, puis les remettre pour le relancer. Manipulation
-- fastidieuse et risquee : on perd le parametrage d'origine.
--
-- Un simple interrupteur par lot suffit. Un lot inactif ne sort plus dans
-- get_next_fiche : ses fiches cessent d'etre distribuees, sans toucher au
-- rattachement des agents.
--
-- Ce qui n'est PAS affecte :
--   - les fiches deja en main : un agent termine ce qu'il a commence ;
--   - les rappels deja poses, qui restent attaches a leur auteur ;
--   - la recherche : une fiche d'un lot eteint reste consultable.

alter table lots
  add column if not exists actif boolean not null default true;

comment on column lots.actif is
  'Interrupteur de distribution. A false, get_next_fiche ignore ce lot sans toucher a ses cibles.';

-- campagnes.actif existait deja mais get_next_fiche ne le lisait pas : couper une
-- campagne n'avait aucun effet sur la distribution, le champ ne servait qu'a
-- filtrer la liste deroulante de l'Import. Il devient un interrupteur general :
-- campagne eteinte, tous ses lots cessent de distribuer, quel que soit leur
-- propre etat. Leur reglage individuel est conserve et reprend tel quel au
-- rallumage.
comment on column campagnes.actif is
  'Interrupteur general. A false, aucun lot de la campagne ne distribue, meme actif.';

-- get_next_fiche : seule la constitution de v_lot_ids change, on ne retient
-- desormais que les lots actifs d'une campagne active. Le reste est inchange.
create or replace function public.get_next_fiche()
returns clients
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_agent uuid := auth.uid();
  v_agent_statut text;
  v_client clients;
  v_lot_ids uuid[];
begin
  select statut into v_agent_statut from profils where id = v_agent;
  if v_agent_statut is distinct from 'en_prod' then
    raise exception 'Passe en statut Production pour récupérer une fiche.';
  end if;

  select array_agg(distinct lc.lot_id) into v_lot_ids
  from lots_cibles lc
  join lots l on l.id = lc.lot_id and l.actif
  join campagnes ca on ca.id = l.campagne_id and ca.actif
  where (lc.cible_type = 'agent' and lc.agent_id = v_agent)
     or (lc.cible_type = 'groupe' and lc.groupe_id in (
          select gam.groupe_id from groupes_agents_membres gam where gam.agent_id = v_agent ));

  if v_lot_ids is null then return null; end if;

  select c.* into v_client
  from clients c
  where c.lot_id = any(v_lot_ids)
    and ( c.statut = 'disponible'
       or ( c.statut = 'planifie'
            and c.visible_apres <= now()
            and ( c.agent_id = v_agent
               or not exists ( select 1 from types_qualification tq
                               where tq.id = c.type_qualification_id
                                 and tq.categorie = 'À rappeler' ) ) ) )
  order by
    case
      when c.statut = 'planifie'
           and c.agent_id = v_agent
           and exists ( select 1 from types_qualification tq
                        where tq.id = c.type_qualification_id
                          and tq.categorie = 'À rappeler' ) then 0
      else 1
    end,
    random()
  for update skip locked
  limit 1;

  if v_client.id is null then return null; end if;

  update clients
     set statut = 'en_cours',
         agent_id = v_agent,
         recuperee_le = now()
   where id = v_client.id
  returning * into v_client;

  return v_client;
end;
$function$;

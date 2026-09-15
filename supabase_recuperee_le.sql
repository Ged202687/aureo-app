-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- Le bloc "Fiches bloquees" affichait "recuperee il y a X" a partir de
-- clients.updated_at. Or ce champ ne marque pas la recuperation : selon le
-- chemin emprunte il vaut la date de qualification, ou la date d'echeance
-- (visible_apres). Une fiche prise il y a deux minutes mais qualifiee il y a
-- quatre jours apparaissait donc comme oubliee depuis quatre jours, ce qui rend
-- la liste trompeuse et dangereuse : on y "libere" des appels en cours.
--
-- D'ou une colonne dediee, ecrite au seul moment ou une fiche passe en_cours.
--
-- Les fiches deja en_cours restent a null : leur vraie date de recuperation est
-- perdue et la deviner serait reproduire le defaut qu'on corrige. L'interface
-- affiche "date de recuperation inconnue" pour celles-la, et elles se
-- regularisent d'elles-memes au prochain cycle.

alter table clients
  add column if not exists recuperee_le timestamptz;

comment on column clients.recuperee_le is
  'Horodatage de la derniere mise en statut en_cours (recuperation par un agent). Ne pas confondre avec updated_at.';

-- get_next_fiche : meme logique de distribution qu'avant, on ajoute seulement
-- l'horodatage de la recuperation dans l'UPDATE final.
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

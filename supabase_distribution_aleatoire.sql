-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- Jusqu'ici, toute fiche "planifie" ne revenait qu'a l'agent qui l'avait
-- qualifiee (condition c.agent_id = v_agent). Une fiche passee en Injoignable,
-- Pas disponible, Contact... retombait donc toujours sur le meme agent a
-- l'echeance, ce qui casse la distribution aleatoire.
--
-- Nouvelle regle : seules les fiches "A rappeler" restent attachees a leur
-- agent (c'est un rendez-vous qu'il a pris avec le client). Toutes les autres
-- repartent dans le pool commun et sont tirees au hasard.
--
-- Inchange : le delai avant reouverture (visible_apres), donc le verrou de 30
-- jours des "Rechargement valide", et le ciblage par lot (lots_cibles).
--
-- L'ordre de service devient :
--   0. mes rappels arrives a echeance : un rendez-vous pris avec le client,
--      il doit tomber a l'heure prevue et non au hasard.
--   1. tout le reste dans un seul tirage au sort : fiches recyclees (Injoignable,
--      Pas disponible, Contact...) et fiches neuves melangees, sans priorite.

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

  -- clients.type_qualification_id porte toujours la derniere qualification de
  -- la fiche : on s'en sert pour reconnaitre un rappel sans relire la table
  -- qualifications.
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

  update clients set statut = 'en_cours', agent_id = v_agent where id = v_client.id returning * into v_client;

  return v_client;
end;
$function$;

-- À exécuter une seule fois dans l'éditeur SQL de Supabase (Dashboard > SQL Editor).
-- Empêche toute nouvelle qualification d'une fiche dans les 30 jours suivant une
-- qualification "Rechargement validé" (catégorie Positif) — quel que soit le chemin
-- utilisé pour y arriver (recherche, file d'attente, recyclage admin, appel API direct).
-- C'est le verrou serveur qui garantit la règle, en complément des filtres côté
-- interface (recherche agent, recyclage) qui évitent déjà de proposer ces fiches.

create or replace function bloquer_requalification_rechargement_valide()
returns trigger
language plpgsql
as $$
declare
  v_derniere_validation timestamptz;
begin
  select q.created_at into v_derniere_validation
  from qualifications q
  join types_qualification tq on tq.id = q.type_qualification_id
  where q.client_id = new.client_id
    and tq.categorie = 'Positif'
    and tq.motif = 'Rechargement validé'
  order by q.created_at desc
  limit 1;

  if v_derniere_validation is not null and v_derniere_validation > now() - interval '30 days' then
    raise exception 'Cette fiche a été validée (rechargement) le % — verrouillée 30 jours, aucune nouvelle qualification n''est autorisée.',
      to_char(v_derniere_validation, 'DD/MM/YYYY');
  end if;

  return new;
end;
$$;

drop trigger if exists trg_bloquer_requalification_rechargement_valide on qualifications;
create trigger trg_bloquer_requalification_rechargement_valide
before insert on qualifications
for each row execute function bloquer_requalification_rechargement_valide();

-- À exécuter une seule fois dans l'éditeur SQL de Supabase (Dashboard > SQL Editor).
-- Ajoute la fonction RPC utilisée par le nouvel onglet "Recyclage" (App.jsx : RecyclagePanel).
-- Remet en circuit des fiches archivées/planifiées/en cours oubliées : statut -> 'disponible',
-- agent_id -> null, visible_apres -> null. La fiche reste dans son lot/campagne d'origine.

create or replace function admin_recycler_fiches(p_client_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_count integer;
begin
  select role into v_role from profils where id = auth.uid();
  if v_role is null or v_role not in ('admin', 'super_admin') then
    raise exception 'Accès refusé : réservé aux administrateurs.';
  end if;

  update clients
  set statut = 'disponible', agent_id = null, visible_apres = null
  where id = any(p_client_ids) and statut in ('archive', 'planifie', 'en_cours');

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function admin_recycler_fiches(uuid[]) to authenticated;

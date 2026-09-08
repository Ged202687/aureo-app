-- À exécuter une seule fois dans l'éditeur SQL de Supabase (Dashboard > SQL Editor).
-- RPC utilisée pour la suppression en masse des fiches en doublon (et pour toute
-- suppression ciblée future) : supprime l'historique de qualifications puis les
-- fiches elles-mêmes, réservée aux admins/super admins.

create or replace function public.admin_supprimer_fiches(p_client_ids uuid[])
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text;
  v_count integer;
begin
  select role into v_role from profils where id = auth.uid();
  if v_role is null or v_role not in ('admin', 'super_admin') then
    raise exception 'Accès refusé : réservé aux administrateurs.';
  end if;

  delete from qualifications where client_id = any(p_client_ids);
  delete from clients where id = any(p_client_ids);
  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

grant execute on function public.admin_supprimer_fiches(uuid[]) to authenticated;

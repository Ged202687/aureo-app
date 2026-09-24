-- A executer dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Peut etre relance sans risque. Partie 3 sur 3 : a executer dans l'ordre.
--
-- Lien d'appel Axterix : colonne lien_appel, regler_lien_appel().

-- ---------------------------------------------------------------------------
-- 2. Lien d'appel (Axterix)
-- ---------------------------------------------------------------------------
alter table supervision_seuils add column if not exists lien_appel text;

create or replace function public.regler_lien_appel(p_lien text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text;
begin
  select role into v_role from profils where id = auth.uid();
  if v_role is null or v_role not in ('admin', 'super_admin') then
    raise exception 'Seuls les administrateurs reglent le lien d''appel.';
  end if;
  if nullif(trim(p_lien), '') is not null and trim(p_lien) !~* '^(https?://|tel:|sip:|callto:)' then
    raise exception 'Le lien doit commencer par https://, http://, tel:, sip: ou callto:.';
  end if;
  update supervision_seuils
     set lien_appel = nullif(trim(p_lien), ''), modifie_le = now(), modifie_par = auth.uid()
   where id = 1;
end;
$function$;

revoke execute on function public.regler_lien_appel(text) from public, anon;
grant execute on function public.regler_lien_appel(text) to authenticated;


notify pgrst, 'reload schema';

-- Attendu : regler_lien_appel = 1, colonne_lien_appel = 1.
select
  (select count(*) from pg_proc where proname = 'regler_lien_appel') as regler_lien_appel,
  (select count(*) from information_schema.columns
    where table_name = 'supervision_seuils' and column_name = 'lien_appel') as colonne_lien_appel;

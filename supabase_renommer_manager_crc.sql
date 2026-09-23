-- Renomme le compte super administrateur "Administrateur Relais" en "Manager CRC".
-- Seul le nom affiche change : l'identifiant de connexion, le role et les droits
-- restent identiques.
--
-- Le compte est cible par son nom ET son role, et le script refuse de continuer
-- s'il ne trouve pas exactement une ligne : rien d'autre ne peut etre renomme
-- par erreur.

do $$
declare
  n integer;
begin
  update profils
     set nom = 'Manager CRC'
   where nom = 'Administrateur Relais'
     and role = 'super_admin';
  get diagnostics n = row_count;

  if n <> 1 then
    raise exception 'Attendu 1 compte a renommer, trouve %. Rien n''a ete modifie.', n;
  end if;
end $$;

-- Verification
select id, nom, login, role from profils where role = 'super_admin';

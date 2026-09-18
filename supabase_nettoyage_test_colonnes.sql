-- A executer une seule fois, puis ce fichier peut etre supprime.
--
-- Nettoyage du bac a sable qui a servi a tester le choix des champs affiches
-- sur la fiche agent : une campagne "ZZ TEST", un lot inactif et sans cible,
-- et deux fiches fictives (ZZTEST001, ZZTEST002).
--
-- Rien de tout cela n'a jamais pu atteindre un agent : le lot n'a aucune ligne
-- dans lots_cibles et son interrupteur est sur arret. Mais les deux fiches
-- comptent dans le total du tableau de bord, d'ou ce menage.
--
-- La suppression des fiches est refusee depuis le navigateur (la RLS n'ouvre
-- pas DELETE sur clients), d'ou le passage par l'editeur SQL.
--
-- Le lot est designe par son identifiant exact : aucune autre donnee ne peut
-- etre touchee, meme si un nom se repetait ailleurs.

do $do$
declare
  v_lot uuid := 'fb6272cb-d434-4a29-bed4-dd1f6a6d7281';
  v_campagne uuid := '50b72ece-975c-4fa4-9334-e174ab8c0742';
  v_fiches int;
begin
  -- Garde-fou : on refuse d'agir si ce lot contient autre chose que les deux
  -- fiches de test, signe qu'on ne vise pas ce qu'on croit.
  select count(*) into v_fiches from clients where lot_id = v_lot;
  if v_fiches > 2 then
    raise exception 'Le lot contient % fiches au lieu de 2. Rien supprime.', v_fiches;
  end if;

  delete from qualifications where client_id in (select id from clients where lot_id = v_lot);
  delete from clients where lot_id = v_lot;
  delete from lots_cibles where lot_id = v_lot;
  delete from lots where id = v_lot;
  delete from campagnes where id = v_campagne;

  raise notice 'Bac a sable supprime : % fiche(s), 1 lot, 1 campagne.', v_fiches;
end
$do$;

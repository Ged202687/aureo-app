-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- L'import ne retenait que neuf colonnes connues d'avance (box, nom, contact,
-- numero MTN, segment, commune, entreprise, email, note). Tout le reste du
-- fichier etait purement et simplement jete, et l'ecran de l'agent affichait
-- toujours les quatre memes champs. Resultat : selon la campagne, il manque a
-- l'agent une information presente dans le fichier d'origine (offre en cours,
-- date d'echeance, niveau de consommation...) sans aucun moyen de la lui donner.
--
-- Deux colonnes suffisent a lever le blocage :
--
--   clients.donnees        les colonnes supplementaires retenues a l'import,
--                          sous forme cle -> valeur texte ;
--   lots.champs_affiches   la liste ordonnee de ce que l'agent voit sur la
--                          fiche, choisie au moment de l'injection.
--
-- Aucune politique RLS a ajouter : une colonne herite des politiques de sa
-- table, et l'import comme la gestion des lots passent deja par ces tables.
--
-- Retour arriere : les lots sans champs_affiches (donc tous les lots
-- existants) gardent l'affichage actuel. Rien ne change tant qu'un nouvel
-- import n'a pas defini de configuration.

alter table clients
  add column if not exists donnees jsonb;

comment on column clients.donnees is
  'Colonnes supplementaires retenues a l''import (cle courte -> valeur texte). Les champs historiques (nom, telephone...) restent des colonnes a part entiere.';

alter table lots
  add column if not exists champs_affiches jsonb;

comment on column lots.champs_affiches is
  'Champs montres a l''agent, dans l''ordre : [{"cle":"telephone","libelle":"Numero de contact 1"}]. Une cle prefixee "donnees." pointe vers clients.donnees. Null = affichage par defaut.';

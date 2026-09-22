-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- Certaines qualifications se prolongent dans un autre outil : un
-- dysfonctionnement doit etre declare dans l'outil d'incidents, et l'agent
-- doit aujourd'hui aller le chercher lui-meme, retrouver l'adresse, la
-- retaper. Autant l'ouvrir depuis la fiche.
--
-- Une colonne par categorie suffit. Renseignee, un clic sur la categorie
-- ouvre l'adresse dans un nouvel onglet, et un lien reste disponible sous les
-- motifs pour la rouvrir sans avoir a recliquer sur la categorie.
--
-- Comme l'icone et la couleur, le lien appartient a la categorie : toutes ses
-- lignes portent la meme valeur, mise a jour d'un seul coup.
--
-- L'application n'ouvre que des adresses http:// ou https:// : une valeur
-- d'un autre type est refusee a la saisie et ignoree a l'affichage.
--
-- Non renseignee, cette colonne ne change rien.

alter table types_qualification
  add column if not exists lien text;

comment on column types_qualification.lien is
  'Adresse ouverte quand l''agent choisit cette categorie (outil externe : declaration d''incident, SAV...). http/https uniquement. Null = aucun lien.';

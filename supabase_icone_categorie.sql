-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- Les categories de qualification affichent une icone et une couleur codees
-- en dur dans l'application : Positif, A rappeler, Injoignable et Negatif en
-- ont une, toutes les autres heritent d'une horloge grise. C'est pourquoi
-- "Contact" s'affiche avec une horloge, ce qui ne veut rien dire, alors que
-- ces categories sont creees librement depuis l'onglet Regles.
--
-- Deux colonnes suffisent pour que le choix appartienne au super admin plutot
-- qu'au code. Elles sont posees sur types_qualification et non sur une
-- nouvelle table : les politiques RLS de cette table sont deja en place et
-- eprouvees (les agents la lisent, les administrateurs l'ecrivent), alors
-- qu'une table supplementaire demanderait d'ecrire ces regles a neuf.
--
-- L'icone appartient a la categorie, pas au motif : toutes les lignes d'une
-- meme categorie portent donc la meme valeur, mise a jour d'un seul coup.
-- L'application lit la premiere valeur non nulle rencontree dans la
-- categorie, ce qui reste juste meme si une ligne ancienne n'a pas ete mise
-- a jour.
--
-- Non renseignees, ces colonnes laissent l'affichage actuel inchange.

alter table types_qualification
  add column if not exists icone text,
  add column if not exists couleur text;

comment on column types_qualification.icone is
  'Nom d''icone choisi pour la categorie (catalogue fixe cote application). Null = icone par defaut.';

comment on column types_qualification.couleur is
  'Couleur de la categorie : vert, ambre, turquoise, rouge, encre ou gris. Null = couleur par defaut.';

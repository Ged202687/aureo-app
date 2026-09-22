-- A executer une seule fois dans l'editeur SQL de Supabase.
--
-- ANNULE ET REMPLACE la version precedente de ce fichier, qui creait l'index
-- clients_id_lot_idx. Mesure faite apres sa creation : la vue "Mois" du
-- panneau d'avancement est passee de 387 ms a 395 ms, soit aucun gain.
--
-- Pourquoi l'hypothese etait fausse : un index couvrant ne dispense Postgres
-- de lire la table que si les pages concernees sont marquees "toutes
-- visibles". Or clients est ecrite en permanence — chaque prise de fiche et
-- chaque qualification la modifient — donc ses pages ne le restent jamais
-- assez longtemps. La lecture de la table a lieu malgre l'index.
--
-- Un index inutile n'est pas neutre : il est mis a jour a chaque ecriture,
-- soit plusieurs milliers de fois par jour sur cette table. On le retire.
--
-- L'index clients_lot_statut_qualif_idx, lui, est conserve : il a divise par
-- plus de deux le cout de la vue "Jour", qui est celle affichee par defaut.

drop index concurrently if exists public.clients_id_lot_idx;

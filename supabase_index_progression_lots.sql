-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- Le panneau "Avancement par campagne et par lot" doit passer en temps reel,
-- c'est-a-dire etre recalcule toutes les 30 secondes comme le reste du
-- tableau de bord. Sa partie la plus couteuse est le comptage d'etat : un
-- parcours complet des 82 000 lignes de clients, regroupe par lot, a chaque
-- appel.
--
-- Cet index couvre exactement les trois colonnes lues par ce comptage, dans
-- l'ordre ou elles servent : regroupement sur lot_id, puis comptages
-- conditionnels sur statut et sur la presence d'une qualification. Postgres
-- peut alors repondre depuis l'index seul, sans toucher a la table.
--
-- Il sert aussi a get_next_fiche, qui cherche les fiches disponibles d'une
-- liste de lots : meme colonnes, meme ordre.
--
-- CONCURRENTLY evite de bloquer les ecritures pendant la creation : les 44
-- agents continuent de qualifier sans s'en apercevoir. Cette forme ne
-- supporte pas d'etre executee dans une transaction — si l'editeur SQL
-- proteste ("CREATE INDEX CONCURRENTLY cannot run inside a transaction
-- block"), relancer la meme commande sans le mot CONCURRENTLY : sur 82 000
-- lignes le verrou dure moins d'une seconde.

create index concurrently if not exists clients_lot_statut_qualif_idx
  on public.clients (lot_id, statut, type_qualification_id);

-- Verification apres coup :
--   select indexrelname, idx_scan
--   from pg_stat_user_indexes
--   where relname = 'clients';

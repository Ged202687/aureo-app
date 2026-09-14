-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- L'import de base ignore silencieusement toute ligne dont le numero de box
-- existe deja, toutes campagnes confondues. Or certaines campagnes ciblent
-- volontairement des clients deja presents ailleurs (un upsell s'adresse par
-- definition a des clients existants), et leurs lignes etaient donc jetees.
--
-- La detection devient reglable campagne par campagne. Par defaut elle reste
-- active : les campagnes existantes gardent le comportement actuel.

alter table campagnes
  add column if not exists detection_doublons boolean not null default true;

comment on column campagnes.detection_doublons is
  'Import : ignorer les lignes dont le numero de box existe deja en base. Reglable par le super admin.';

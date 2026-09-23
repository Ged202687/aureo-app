-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Complete les scripts de la messagerie.
--
-- Repondre a un message precis. Dans un canal ou plusieurs conversations se
-- croisent, "oui d'accord" ne veut rien dire sans savoir a quoi il repond.
--
-- Une seule colonne suffit : le message cite. on delete set null, et non
-- cascade -- si quelqu'un retire son message, les reponses qu'il a suscitees
-- restent, elles ne lui appartiennent pas.
--
-- Aucune politique a ajouter. La citation est lue par une jointure sur la
-- meme table : chaque lecteur ne voit le message cite que s'il a le droit de
-- le lire, sinon la citation lui revient vide. La visibilite se regle donc
-- toute seule, comme pour les reactions.

alter table messages_chat
  add column if not exists repond_a bigint references messages_chat(id) on delete set null;

comment on column messages_chat.repond_a is
  'Message auquel celui-ci repond. Null = message autonome. La citation affichee suit la RLS du message cite.';

create index if not exists messages_chat_repond_a_idx
  on messages_chat (repond_a) where repond_a is not null;

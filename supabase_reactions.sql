-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Complete les scripts de la messagerie.
--
-- Reactions aux messages : un emoji pose par une personne sur un message.
-- La cle primaire fait le travail -- une meme personne ne peut poser deux
-- fois le meme emoji sur le meme message, mais elle peut en poser plusieurs
-- differents.
--
-- Les politiques n'ont pas a redire qui voit quoi : elles s'appuient sur la
-- visibilite du message lui-meme. Comme messages_chat est protegee par RLS,
-- la sous-requete ne trouve rien quand le message est hors de portee de
-- l'appelant. Les reactions heritent donc automatiquement de toutes les
-- regles deja posees -- y compris la coupure de la messagerie aux agents en
-- Production, sans une ligne de plus.

create table if not exists reactions_chat (
  message_id bigint not null references messages_chat(id) on delete cascade,
  agent_id uuid not null references profils(id) on delete cascade,
  emoji text not null,
  created_at timestamptz not null default now(),
  primary key (message_id, agent_id, emoji),
  constraint emoji_court check (length(emoji) between 1 and 16)
);

comment on table reactions_chat is
  'Reactions aux messages. La visibilite suit celle du message, via les politiques RLS de messages_chat.';

create index if not exists reactions_chat_message_idx on reactions_chat (message_id);

alter table reactions_chat enable row level security;

drop policy if exists reactions_lire on reactions_chat;
create policy reactions_lire on reactions_chat
  for select to authenticated
  using (exists (select 1 from messages_chat m where m.id = message_id));

drop policy if exists reactions_ajouter on reactions_chat;
create policy reactions_ajouter on reactions_chat
  for insert to authenticated
  with check (
    agent_id = auth.uid()
    and exists (select 1 from messages_chat m where m.id = message_id)
  );

-- On retire sa propre reaction, jamais celle d'un autre.
drop policy if exists reactions_retirer on reactions_chat;
create policy reactions_retirer on reactions_chat
  for delete to authenticated
  using (agent_id = auth.uid());

-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- Messagerie interne d'Aureo. Trois portees, decidees avec l'exploitation :
--
--   general : tout le plateau, chacun lit et ecrit ;
--   equipe  : une conversation par equipe (Angels, Winners...), ouverte a ses
--             agents, a son coach, et a la hierarchie au-dessus ;
--   direct  : d'une personne a une autre, librement, mais lisible par ces
--             deux personnes uniquement -- la hierarchie ne lit pas les
--             messages directs.
--
-- Tout tient dans une seule table : une conversation n'est pas un objet a
-- creer et a maintenir, c'est simplement la portee d'un message. Une equipe
-- nouvelle a donc son canal sans qu'on ait rien a faire.
--
-- Point d'attention : la RLS de profils masque a un agent les lignes de ses
-- collegues. Une politique qui interrogerait profils directement se
-- verrouillerait donc elle-meme. Les verifications passent par des fonctions
-- SECURITY DEFINER, seules habilitees a lire l'organigramme.

create table if not exists messages_chat (
  id bigint generated always as identity primary key,
  portee text not null check (portee in ('general', 'equipe', 'direct')),
  equipe_id uuid references equipes(id) on delete cascade,
  destinataire_id uuid references profils(id) on delete cascade,
  auteur_id uuid not null references profils(id) on delete cascade,
  contenu text not null,
  created_at timestamptz not null default now(),

  -- Chaque portee a exactement les champs qui la concernent : on ne peut pas
  -- ecrire un message d'equipe sans equipe, ni un direct sans destinataire.
  constraint portee_coherente check (
       (portee = 'general' and equipe_id is null and destinataire_id is null)
    or (portee = 'equipe'  and equipe_id is not null and destinataire_id is null)
    or (portee = 'direct'  and equipe_id is null and destinataire_id is not null)
  ),
  constraint contenu_non_vide check (length(btrim(contenu)) between 1 and 2000)
);

comment on table messages_chat is
  'Messagerie interne. Une ligne = un message. La portee (general/equipe/direct) definit qui le lit, via les politiques RLS.';

-- Lecture d'une conversation : toujours les N derniers messages, par portee.
create index if not exists messages_chat_general_idx
  on messages_chat (created_at desc) where portee = 'general';
create index if not exists messages_chat_equipe_idx
  on messages_chat (equipe_id, created_at desc) where portee = 'equipe';
create index if not exists messages_chat_direct_idx
  on messages_chat (destinataire_id, auteur_id, created_at desc) where portee = 'direct';
create index if not exists messages_chat_direct_retour_idx
  on messages_chat (auteur_id, destinataire_id, created_at desc) where portee = 'direct';

-- ---------------------------------------------------------------- habilitations

-- Un compte desactive ne lit ni n'ecrit plus rien.
create or replace function public.compte_actif(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (select 1 from profils where id = p_id and coalesce(actif, true));
$function$;

-- Qui peut lire -- et donc ecrire dans -- le canal d'une equipe :
--   ses agents, son coach, l'administration, et le superviseur dont releve
--   au moins un membre de cette equipe.
create or replace function public.peut_lire_equipe(p_equipe uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1
    from profils moi
    where moi.id = auth.uid()
      and coalesce(moi.actif, true)
      and (
           moi.equipe_id = p_equipe
        or exists (select 1 from equipes e where e.id = p_equipe and e.coach_id = moi.id)
        or moi.role in ('admin', 'super_admin')
        or (moi.role = 'superviseur' and exists (
              select 1 from profils a
              where a.equipe_id = p_equipe and a.superviseur_id = moi.id))
      )
  );
$function$;

-- ---------------------------------------------------------------- RLS

alter table messages_chat enable row level security;

drop policy if exists chat_lire_general on messages_chat;
create policy chat_lire_general on messages_chat
  for select to authenticated
  using (portee = 'general' and compte_actif(auth.uid()));

drop policy if exists chat_lire_equipe on messages_chat;
create policy chat_lire_equipe on messages_chat
  for select to authenticated
  using (portee = 'equipe' and peut_lire_equipe(equipe_id));

-- Les messages directs restent entre leurs deux interlocuteurs : ni le
-- coach, ni le superviseur, ni l'administration n'y ont acces.
drop policy if exists chat_lire_direct on messages_chat;
create policy chat_lire_direct on messages_chat
  for select to authenticated
  using (portee = 'direct' and (auteur_id = auth.uid() or destinataire_id = auth.uid()));

drop policy if exists chat_ecrire on messages_chat;
create policy chat_ecrire on messages_chat
  for insert to authenticated
  with check (
    auteur_id = auth.uid()
    and compte_actif(auth.uid())
    and (
         portee = 'general'
      or (portee = 'equipe' and peut_lire_equipe(equipe_id))
      or (portee = 'direct' and compte_actif(destinataire_id))
    )
  );

-- On peut retirer son propre message, jamais celui d'un autre.
drop policy if exists chat_supprimer_le_sien on messages_chat;
create policy chat_supprimer_le_sien on messages_chat
  for delete to authenticated
  using (auteur_id = auth.uid());

-- ---------------------------------------------------------------- annuaire

-- Pour ecrire a quelqu'un, encore faut-il pouvoir le nommer. La RLS de
-- profils masquant les collegues, cette fonction est le seul chemin : elle
-- ne renvoie que ce qu'il faut pour choisir un destinataire et afficher le
-- nom d'un auteur, jamais le login ni le matricule.
create or replace function public.annuaire_chat()
returns table (id uuid, nom text, role text, equipe_id uuid, equipe_nom text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.id, p.nom, p.role, p.equipe_id, e.nom
  from profils p
  left join equipes e on e.id = p.equipe_id
  where coalesce(p.actif, true)
    and auth.uid() is not null
    and compte_actif(auth.uid())
  order by p.nom asc;
$function$;

-- ---------------------------------------------------------------- suivi de lecture

create table if not exists lectures_chat (
  agent_id uuid not null references profils(id) on delete cascade,
  canal text not null,          -- 'general' | 'equipe:<uuid>' | 'direct:<uuid>'
  lu_jusqu_a timestamptz not null default now(),
  primary key (agent_id, canal)
);

alter table lectures_chat enable row level security;

drop policy if exists lectures_les_miennes on lectures_chat;
create policy lectures_les_miennes on lectures_chat
  for all to authenticated
  using (agent_id = auth.uid())
  with check (agent_id = auth.uid());

-- ---------------------------------------------------------------- droits

-- Postgres accorde EXECUTE a PUBLIC sur toute nouvelle fonction : sans ces
-- revocations, l'annuaire du personnel serait lisible sans etre connecte.
revoke all on function public.annuaire_chat() from public, anon;
revoke all on function public.peut_lire_equipe(uuid) from public, anon;
revoke all on function public.compte_actif(uuid) from public, anon;

grant execute on function public.annuaire_chat() to authenticated;
grant execute on function public.peut_lire_equipe(uuid) to authenticated;
grant execute on function public.compte_actif(uuid) to authenticated;

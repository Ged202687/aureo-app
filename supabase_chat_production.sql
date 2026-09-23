-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Complete les trois scripts de la messagerie.
--
-- Interrupteur demande par l'exploitation : pouvoir couper la messagerie aux
-- agents pendant qu'ils sont en Production, pour qu'elle ne se paie pas sur
-- le taux d'occupation. En pause, ils la retrouvent.
--
-- Portee volontairement etroite :
--   - ne sont concernes que les profils de role "agent" ;
--   - coachs, superviseurs et administration gardent l'acces en permanence,
--     sinon l'encadrement perdrait le moyen de joindre le plateau ;
--   - l'agent retrouve tout l'historique des qu'il repasse en pause : rien
--     n'est perdu, seulement differe.
--
-- La regle est posee en base et non dans l'interface : les ecritures partent
-- du navigateur, un garde-fou cote ecran se contournerait.

create table if not exists parametres (
  cle text primary key,
  valeur jsonb not null,
  maj_le timestamptz not null default now()
);

comment on table parametres is
  'Reglages generaux d''Aureo, modifiables par le super administrateur.';

insert into parametres (cle, valeur)
values ('chat_coupe_en_production', to_jsonb(false))
on conflict (cle) do nothing;

alter table parametres enable row level security;

-- Tout le monde lit les reglages : l'interface doit savoir quoi afficher.
drop policy if exists parametres_lecture on parametres;
create policy parametres_lecture on parametres
  for select to authenticated using (true);

create or replace function public.est_super_admin()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (select 1 from profils where id = auth.uid() and role = 'super_admin');
$function$;

drop policy if exists parametres_ecriture on parametres;
create policy parametres_ecriture on parametres
  for update to authenticated
  using (est_super_admin())
  with check (est_super_admin());

-- Vrai si l'appelant a droit a la messagerie en cet instant.
create or replace function public.chat_autorise()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case
    when coalesce((select valeur = to_jsonb(true) from parametres where cle = 'chat_coupe_en_production'), false)
      then exists (
        select 1 from profils p
        where p.id = auth.uid()
          and (p.role <> 'agent' or coalesce(p.statut, '') <> 'en_prod')
      )
    else auth.uid() is not null
  end;
$function$;

-- Les politiques existantes sont reprises a l'identique, augmentees de ce
-- seul test. Un agent en Production ne lit plus et n'ecrit plus ; des qu'il
-- passe en pause, tout revient.
drop policy if exists chat_lire_general on messages_chat;
create policy chat_lire_general on messages_chat
  for select to authenticated
  using (portee = 'general' and compte_actif(auth.uid()) and chat_autorise());

drop policy if exists chat_lire_equipe on messages_chat;
create policy chat_lire_equipe on messages_chat
  for select to authenticated
  using (portee = 'equipe' and peut_lire_equipe(equipe_id) and chat_autorise());

drop policy if exists chat_lire_direct on messages_chat;
create policy chat_lire_direct on messages_chat
  for select to authenticated
  using (portee = 'direct' and (auteur_id = auth.uid() or destinataire_id = auth.uid()) and chat_autorise());

drop policy if exists chat_ecrire on messages_chat;
create policy chat_ecrire on messages_chat
  for insert to authenticated
  with check (
    auteur_id = auth.uid()
    and compte_actif(auth.uid())
    and chat_autorise()
    and (
         portee = 'general'
      or (portee = 'equipe' and peut_lire_equipe(equipe_id))
      or (portee = 'direct' and compte_actif(destinataire_id))
    )
  );

revoke all on function public.chat_autorise() from public, anon;
revoke all on function public.est_super_admin() from public, anon;
grant execute on function public.chat_autorise() to authenticated;
grant execute on function public.est_super_admin() to authenticated;

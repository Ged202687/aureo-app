-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Complete supabase_messagerie.sql, a executer apres lui.
--
-- Defaut constate a l'essai : l'interface listait toutes les equipes, parce
-- qu'elle les deduisait de l'annuaire. Un agent voyait donc les canaux
-- "Angels" et "Winners" sans pouvoir y lire quoi que ce soit -- la RLS
-- faisait bien son travail, mais l'ecran promettait ce qu'il ne pouvait pas
-- tenir, et une tentative d'ecriture se serait soldee par une erreur brute.
--
-- Cette fonction renvoie les seules equipes dont l'appelant peut suivre la
-- conversation. Elle s'appuie sur peut_lire_equipe, donc sur exactement la
-- meme regle que les politiques RLS : l'ecran et la base ne peuvent pas
-- diverger.

create or replace function public.canaux_equipes()
returns table (id uuid, nom text, est_la_mienne boolean)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select e.id,
         e.nom,
         exists (select 1 from profils p where p.id = auth.uid() and p.equipe_id = e.id)
  from equipes e
  where auth.uid() is not null
    and peut_lire_equipe(e.id)
  order by e.nom asc;
$function$;

revoke all on function public.canaux_equipes() from public, anon;
grant execute on function public.canaux_equipes() to authenticated;

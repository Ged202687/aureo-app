-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Complete les scripts de la messagerie.
--
-- Jusqu'ici un seul repere de lecture, "global" : ouvrir n'importe quelle
-- conversation marquait tout comme lu. Un message arrivant ailleurs pendant
-- ce temps ne declenchait plus ni pastille ni son.
--
-- La table lectures_chat stockait deja un repere par conversation ; c'est le
-- comptage qui n'en lisait qu'un. Cette fonction rend un total par
-- conversation, calcule en base : compter cote navigateur obligerait a
-- rapatrier les messages eux-memes, pour n'en garder qu'un nombre.
--
-- Point important : la fonction n'est PAS en security definer. Elle
-- s'execute avec les droits de l'appelant, donc la RLS de messages_chat
-- s'applique telle quelle et ne compte que ce qu'il a le droit de lire --
-- canal d'equipe, messages directs, coupure en Production comprise. Aucune
-- regle n'est reecrite ici, donc aucune ne peut diverger.

create or replace function public.non_lus_par_canal()
returns table (canal text, total bigint)
language sql
stable
set search_path to 'public'
as $function$
  with reperes as (
    select l.canal, l.lu_jusqu_a
    from lectures_chat l
    where l.agent_id = auth.uid()
  ),
  recus as (
    select
      case m.portee
        when 'general' then 'general'
        when 'equipe'  then 'equipe:' || m.equipe_id::text
        else 'direct:' || (case when m.auteur_id = auth.uid()
                                then m.destinataire_id else m.auteur_id end)::text
      end as canal,
      m.created_at
    from messages_chat m
    where auth.uid() is not null
      and m.auteur_id <> auth.uid()      -- ses propres messages ne sont jamais "non lus"
  )
  select r.canal, count(*)
  from recus r
  left join reperes p on p.canal = r.canal
  where r.created_at > coalesce(p.lu_jusqu_a, '-infinity'::timestamptz)
  group by r.canal;
$function$;

revoke all on function public.non_lus_par_canal() from public, anon;
grant execute on function public.non_lus_par_canal() to authenticated;

-- Le repere "global" ne sert plus. On s'en sert une derniere fois pour
-- amorcer celui du canal general, qui concentre l'essentiel des messages :
-- sans cela, chaque agent verrait au premier chargement le cumul de tout ce
-- qu'il n'a jamais formellement ouvert.
insert into lectures_chat (agent_id, canal, lu_jusqu_a)
select agent_id, 'general', lu_jusqu_a
from lectures_chat
where canal = 'global'
on conflict (agent_id, canal) do nothing;

delete from lectures_chat where canal = 'global';

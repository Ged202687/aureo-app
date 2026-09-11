-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- L'historique affiche sur la fiche de l'agent lisait le nom de l'auteur via
-- l'embed PostgREST qualifications -> profils. La RLS de profils empeche un
-- agent de lire la ligne d'un collegue : l'embed renvoyait null, donc "agent"
-- a la place du nom. Le probleme est devenu visible en passant la distribution
-- en aleatoire, puisque les agents traitent maintenant des fiches qualifiees
-- par d'autres.
--
-- On passe par une RPC security definer (comme mes_resultats, get_next_fiche...)
-- qui ne renvoie que le nom de l'auteur, plutot que d'ouvrir profils en lecture
-- a tous les agents (ce qui exposerait aussi login, matricule, role...).
--
-- ATTENTION : cette fonction prend l'id du client en parametre, elle ne se
-- limite donc pas d'elle-meme via auth.uid() comme les autres RPC du projet.
-- PostgreSQL accorde EXECUTE a PUBLIC par defaut sur toute nouvelle fonction :
-- sans le revoke ci-dessous, n'importe qui possedant la cle publique (elle est
-- dans le bundle JS, donc publique) lirait l'historique de n'importe quel
-- client. D'ou les deux garde-fous : le revoke, et le test auth.uid().

create or replace function public.historique_client(p_client_id uuid)
returns table(
  id uuid,
  created_at timestamptz,
  categorie text,
  motif text,
  commentaire text,
  agent_nom text
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select
    q.id,
    q.created_at,
    tq.categorie::text,
    tq.motif::text,
    q.commentaire::text,
    p.nom::text
  from qualifications q
  join types_qualification tq on tq.id = q.type_qualification_id
  left join profils p on p.id = q.agent_id
  where q.client_id = p_client_id
    and auth.uid() is not null
  order by q.created_at desc;
$function$;

revoke execute on function public.historique_client(uuid) from public;
revoke execute on function public.historique_client(uuid) from anon;
grant execute on function public.historique_client(uuid) to authenticated;

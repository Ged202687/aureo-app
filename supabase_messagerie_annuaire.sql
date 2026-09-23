-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Complete supabase_messagerie.sql et supabase_messagerie_canaux.sql.
--
-- annuaire_chat renvoyait tout le personnel a chaque agent : pratique pour
-- choisir un destinataire, mais l'agent n'a pas a disposer de la liste
-- complete du plateau. La masquer a l'ecran n'aurait rien regle -- elle
-- serait restee dans le navigateur, lisible par qui ouvre les outils de
-- developpement.
--
-- Elle est donc remplacee par trois fonctions qui ne renvoient chacune que le
-- strict necessaire :
--
--   rechercher_personnes : les correspondances d'une recherche, a partir de
--                          deux caracteres, plafonnees ;
--   mes_conversations    : les personnes avec qui j'ai deja echange, sans
--                          quoi un message recu serait introuvable ;
--   noms_personnes       : le nom des auteurs des messages affiches.
--
-- Aucune ne permet d'obtenir la liste entiere.

drop function if exists public.annuaire_chat();

-- Recherche par nom, insensible a la casse et aux accents. Les caracteres
-- joker de LIKE sont neutralises : sans cela, une recherche sur "%" aurait
-- ramene tout le monde et vide la mesure de son sens.
create or replace function public.rechercher_personnes(p_recherche text)
returns table (id uuid, nom text, role text, equipe_nom text)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_q text;
  v_accents constant text := 'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ';
  v_plats   constant text := 'aaaeeeeiioouucAAAEEEEIIOOUUUC';
begin
  if not compte_actif(auth.uid()) then
    raise exception 'Acces refuse.';
  end if;

  v_q := translate(lower(btrim(coalesce(p_recherche, ''))), v_accents, v_plats);
  if length(v_q) < 2 then
    return;                       -- rien tant que la recherche est trop courte
  end if;
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');

  return query
  select p.id, p.nom, p.role, e.nom
  from profils p
  left join equipes e on e.id = p.equipe_id
  where coalesce(p.actif, true)
    and p.id <> auth.uid()
    and translate(lower(p.nom), v_accents, v_plats) like '%' || v_q || '%'
  order by p.nom asc
  limit 25;
end
$function$;

-- Les conversations deja engagees. Sans elles, un message recu d'une
-- personne dont on ignore le nom serait impossible a retrouver.
create or replace function public.mes_conversations()
returns table (id uuid, nom text, role text, equipe_nom text, dernier_echange timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.id, p.nom, p.role, e.nom, max(t.created_at)
  from (
    select case when m.auteur_id = auth.uid() then m.destinataire_id else m.auteur_id end as autre,
           m.created_at
    from messages_chat m
    where m.portee = 'direct'
      and (m.auteur_id = auth.uid() or m.destinataire_id = auth.uid())
  ) t
  join profils p on p.id = t.autre
  left join equipes e on e.id = p.equipe_id
  where auth.uid() is not null and coalesce(p.actif, true)
  group by p.id, p.nom, p.role, e.nom
  order by max(t.created_at) desc
  limit 40;
$function$;

-- Nom des auteurs des messages affiches. Bornee a ce que l'appelant demande,
-- elle ne permet pas de parcourir l'organigramme.
create or replace function public.noms_personnes(p_ids uuid[])
returns table (id uuid, nom text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.id, p.nom
  from profils p
  where auth.uid() is not null
    and compte_actif(auth.uid())
    and p.id = any(p_ids)
  limit 200;
$function$;

revoke all on function public.rechercher_personnes(text) from public, anon;
revoke all on function public.mes_conversations() from public, anon;
revoke all on function public.noms_personnes(uuid[]) from public, anon;

grant execute on function public.rechercher_personnes(text) to authenticated;
grant execute on function public.mes_conversations() to authenticated;
grant execute on function public.noms_personnes(uuid[]) to authenticated;

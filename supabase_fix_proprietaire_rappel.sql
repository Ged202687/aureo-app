-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- Bug : un rappel ne revenait pas a l'agent qui l'avait pose, et remontait chez
-- un autre. En parallele, le bandeau "Rappels de la semaine" restait vide pour
-- son auteur.
--
-- Cause unique : qualifier_fiche conserve l'ancien clients.agent_id au lieu de
-- l'attribuer a celui qui vient de qualifier :
--
--   agent_id = case when v_type.terminale then null else agent_id end
--
-- La fiche reste donc la propriete de l'agent qui l'avait traitee au tour
-- precedent. Or les deux mecanismes du rappel s'appuient sur ce champ :
--   - le bandeau filtre sur agent_id = moi, donc l'auteur ne voit pas son RDV ;
--   - get_next_fiche teste c.agent_id = v_agent, donc le rappel est refuse a son
--     auteur et sert a l'ancien proprietaire.
--
-- Correction : l'agent qui qualifie devient proprietaire de la fiche. Le cas
-- terminale (fiche archivee, plus d'agent) est inchange.
--
-- On ne reecrit pas la fonction entiere : on relit sa definition installee et on
-- remplace cette seule expression. Si le texte attendu n'y est pas, le script
-- s'arrete sans rien modifier.

do $do$
declare
  v_src text;
  v_new text;
  v_attendu text := 'agent_id = case when v_type.terminale then null else agent_id end';
  v_corrige text := 'agent_id = case when v_type.terminale then null else auth.uid() end';
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'qualifier_fiche';

  if v_src is null then
    raise exception 'qualifier_fiche introuvable dans le schema public.';
  end if;

  if position(v_attendu in v_src) = 0 then
    raise exception 'Expression attendue absente : la fonction a change depuis le diagnostic. Rien modifie.';
  end if;

  v_new := replace(v_src, v_attendu, v_corrige);
  execute v_new;
  raise notice 'qualifier_fiche corrigee : l''agent qui qualifie devient proprietaire de la fiche.';
end
$do$;

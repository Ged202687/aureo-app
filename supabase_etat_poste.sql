-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Peut etre relance sans risque.
--
-- Un seul appel pour l'etat du poste, au lieu de quatre.
--
-- Chaque navigateur ouvert interrogeait Supabase en continu : messages non
-- lus (30 s), evaluations qualite (2 min), fiches en cours non qualifiees
-- (30 s), rappels de la semaine (60 s). Supabase journalise chaque requete :
-- avec une quarantaine d'agents, cela faisait pres de 200 000 requetes par
-- jour, et le volume de journaux (Log Ingestion) a atteint 5 fois le quota.
--
-- etat_poste() renvoie les quatre en une fois :
--   - non_lus : messages non lus par conversation (non_lus_par_canal) ;
--   - qc : compteurs du controle qualite (qc_compteurs) ;
--   - orphelines : fiches "en cours" au nom de l'appelant ;
--   - nb_rappels : ses rappels "A rappeler" de la semaine.
--
-- SECURITY INVOKER (valeur par defaut, volontairement) : la fonction lit avec
-- les droits de l'appelant, la RLS s'applique exactement comme pour les
-- appels separes qu'elle remplace. non_lus_par_canal repose d'ailleurs sur
-- elle pour ne compter que les messages que l'appelant a le droit de lire.

create or replace function public.etat_poste()
returns jsonb
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  v_moi uuid := auth.uid();
  v_debut_semaine timestamptz := date_trunc('week', now() at time zone 'Africa/Abidjan') at time zone 'Africa/Abidjan';
begin
  if v_moi is null then
    raise exception 'Non connecte.';
  end if;

  return jsonb_build_object(
    'non_lus', coalesce((
      select jsonb_agg(jsonb_build_object('canal', n.canal, 'total', n.total))
      from non_lus_par_canal() n
    ), '[]'::jsonb),
    'qc', qc_compteurs(),
    'orphelines', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.recuperee_le asc nulls first)
      from clients c
      where c.statut = 'en_cours' and c.agent_id = v_moi
    ), '[]'::jsonb),
    'nb_rappels', (
      select count(*)
      from clients c
      join types_qualification tq on tq.id = c.type_qualification_id
      where c.statut = 'planifie'
        and c.agent_id = v_moi
        and tq.categorie = 'À rappeler'
        and c.visible_apres >= v_debut_semaine
        and c.visible_apres < v_debut_semaine + interval '7 days'
    )
  );
end;
$function$;

revoke execute on function public.etat_poste() from public, anon;
grant execute on function public.etat_poste() to authenticated;


-- ---------------------------------------------------------------------------
-- Verification : l'editeur n'affiche que le resultat de la derniere requete.
-- Attendu : etat_poste = 1.
-- ---------------------------------------------------------------------------
notify pgrst, 'reload schema';

select (select count(*) from pg_proc where proname = 'etat_poste') as etat_poste;

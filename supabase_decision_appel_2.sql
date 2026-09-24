-- A executer dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Peut etre relance sans risque. Partie 2 sur 3 : a executer dans l'ordre.
--
-- Liste des evaluations : renvoie decision_lue_le.

-- Identique a la version precedente, avec decision_lue_le en plus.
create or replace function public.qc_evaluations_liste(p_depuis timestamptz, p_jusqua timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_moi uuid := auth.uid();
  v_role text;
  v_resultat jsonb;
begin
  select role into v_role from profils where id = v_moi;
  if v_role is null then
    raise exception 'Profil introuvable.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', ev.id, 'statut', ev.statut, 'created_at', ev.created_at,
    'note', ev.note, 'niveau', ev.niveau, 'note_initiale', ev.note_initiale,
    'reponses', ev.reponses, 'eliminatoires', ev.eliminatoires, 'grille_id', ev.grille_id,
    'commentaire', ev.commentaire, 'axes_progres', ev.axes_progres,
    'lue_le', ev.lue_le, 'validee_le', ev.validee_le,
    'contestation_motif', ev.contestation_motif, 'contestee_le', ev.contestee_le,
    'arbitrage_commentaire', ev.arbitrage_commentaire, 'arbitree_le', ev.arbitree_le,
    'decision_lue_le', ev.decision_lue_le,
    'agent_id', ev.agent_id, 'agent_nom', ag.nom, 'agent_matricule', ag.matricule,
    'evaluateur_id', ev.evaluateur_id, 'evaluateur_nom', co.nom,
    'arbitre_nom', ar.nom,
    'qualification_id', q.id, 'appel_le', q.created_at, 'duree_secondes', q.duree_secondes,
    'qualification_commentaire', q.commentaire, 'categorie', tq.categorie, 'motif', tq.motif,
    'numero_fiche', c.numero_fiche, 'client_nom', c.nom, 'telephone', c.telephone, 'numero_box', c.numero_box
  ) order by ev.created_at desc), '[]'::jsonb)
  into v_resultat
  from qc_evaluations ev
  join profils ag on ag.id = ev.agent_id
  join profils co on co.id = ev.evaluateur_id
  left join profils ar on ar.id = ev.arbitre_id
  join qualifications q on q.id = ev.qualification_id
  join types_qualification tq on tq.id = q.type_qualification_id
  join clients c on c.id = ev.client_id
  where ev.created_at >= p_depuis and ev.created_at < p_jusqua
    and (
      ev.agent_id = v_moi
      or (v_role in ('coach', 'superviseur', 'admin', 'super_admin')
          and ev.agent_id in (select agent_id from mon_perimetre_agents()))
    );

  return v_resultat;
end;
$function$;


notify pgrst, 'reload schema';

-- Attendu : liste_a_jour = true.
select (select pg_get_functiondef('public.qc_evaluations_liste'::regproc) like '%decision_lue_le%') as liste_a_jour;

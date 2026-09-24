-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Peut etre relance sans risque.
--
-- L'agent doit prendre position sur chaque evaluation : il la valide, ou il la
-- conteste. Jusqu'ici il ne pouvait que contester ; ne rien faire etait la
-- seule facon d'accepter, et rien ne distinguait "d'accord" de "pas encore vu".
--
--   - nouveau statut 'validee', avec sa date (validee_le) ;
--   - qc_valider() : l'agent valide sa propre evaluation, tant qu'elle est
--     publiee ou lue, dans le delai de 7 jours (le meme que pour contester) ;
--   - qc_evaluations_liste() renvoie validee_le ;
--   - qc_compteurs() compte desormais les evaluations "a traiter" par l'agent
--     (ni validees ni contestees, delai non ecoule), et plus seulement les non
--     lues : une evaluation ouverte mais sans reponse reste a faire.
--
-- Passe le delai de 7 jours sans reponse, l'evaluation est reputee acceptee :
-- elle sort de la pastille, mais garde le statut "lue" (ou "publiee"), pour
-- que l'encadrement voie qu'elle n'a jamais ete validee explicitement.

alter table qc_evaluations add column if not exists validee_le timestamptz;

alter table qc_evaluations drop constraint if exists qc_evaluations_statut_check;
alter table qc_evaluations add constraint qc_evaluations_statut_check
  check (statut in ('publiee', 'lue', 'validee', 'contestee', 'maintenue', 'revisee', 'annulee'));


create or replace function public.qc_valider(p_evaluation_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ev qc_evaluations;
begin
  select * into v_ev from qc_evaluations where id = p_evaluation_id and agent_id = auth.uid();
  if v_ev.id is null then
    raise exception 'Evaluation introuvable.';
  end if;
  if v_ev.statut not in ('publiee', 'lue') then
    raise exception 'Cette evaluation a deja recu une reponse.';
  end if;
  if v_ev.created_at < now() - interval '7 days' then
    raise exception 'Le delai de reponse (7 jours) est depasse.';
  end if;

  update qc_evaluations
     set statut = 'validee', validee_le = now(), lue_le = coalesce(lue_le, now())
   where id = p_evaluation_id;
end;
$function$;

revoke execute on function public.qc_valider(uuid) from public, anon;
grant execute on function public.qc_valider(uuid) to authenticated;


-- Identique a la version precedente, avec validee_le en plus.
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


create or replace function public.qc_compteurs()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_moi uuid := auth.uid();
  v_role text;
  v_contestations integer := 0;
begin
  select role into v_role from profils where id = v_moi;
  if v_role in ('superviseur', 'admin', 'super_admin') then
    select count(*) into v_contestations from qc_evaluations
     where statut = 'contestee' and agent_id in (select agent_id from mon_perimetre_agents());
  end if;
  return jsonb_build_object(
    'a_traiter', (select count(*) from qc_evaluations
                   where agent_id = v_moi and statut in ('publiee', 'lue')
                     and created_at >= now() - interval '7 days'),
    'non_lues', (select count(*) from qc_evaluations where agent_id = v_moi and statut = 'publiee'),
    'contestations', v_contestations
  );
end;
$function$;


-- ---------------------------------------------------------------------------
-- Verification : l'editeur n'affiche que le resultat de la derniere requete.
-- Attendu : qc_valider = 1, colonne_validee_le = 1.
-- ---------------------------------------------------------------------------
notify pgrst, 'reload schema';

select
  (select count(*) from pg_proc where proname = 'qc_valider') as qc_valider,
  (select count(*) from information_schema.columns
    where table_name = 'qc_evaluations' and column_name = 'validee_le') as colonne_validee_le;

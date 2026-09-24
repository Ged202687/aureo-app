-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Peut etre relance sans risque : rien n'est recree ni ecrase.
--
-- Controle qualite.
--
--   - Les coachs evaluent les appels des agents de leur equipe, avec une grille.
--   - L'agent lit son evaluation et peut la contester dans les 7 jours.
--   - Le superviseur (ou un admin) tranche : note maintenue, revisee, ou
--     evaluation annulee.
--
-- Tout passe par des fonctions : les deux tables n'ont aucune policy
-- d'ecriture, et les evaluations aucune policy de lecture. Les regles de qui
-- voit quoi sont donc ecrites une seule fois, ici, et non dispersees entre la
-- base et l'application.
--
-- La grille est versionnee : la modifier cree une nouvelle version, l'ancienne
-- est conservee. Une evaluation garde la grille avec laquelle elle a ete faite ;
-- changer un bareme ne modifie jamais une note deja donnee.
--
-- Le lien vers l'enregistrement (outil Axterix, quand il sera disponible) est
-- un modele d'adresse avec variables, range avec les seuils de supervision.
-- Vide, le bouton "Ecouter l'enregistrement" reste masque.


-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists qc_grilles (
  id uuid primary key default gen_random_uuid(),
  version integer not null,
  contenu jsonb not null,
  actif boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid references profils(id)
);

-- Une seule grille active a la fois.
create unique index if not exists qc_grilles_une_active on qc_grilles ((true)) where actif;

alter table qc_grilles enable row level security;
drop policy if exists qc_grilles_lecture on qc_grilles;
create policy qc_grilles_lecture on qc_grilles for select to authenticated using (true);

create table if not exists qc_evaluations (
  id uuid primary key default gen_random_uuid(),
  qualification_id uuid not null references qualifications(id),
  client_id uuid not null references clients(id),
  agent_id uuid not null references profils(id),
  evaluateur_id uuid not null references profils(id),
  grille_id uuid not null references qc_grilles(id),
  reponses jsonb not null,
  eliminatoires jsonb not null default '[]'::jsonb,
  note numeric(5,1) not null,
  niveau text not null,
  note_initiale numeric(5,1),
  commentaire text,
  axes_progres text,
  -- publiee -> lue -> contestee -> maintenue | revisee | annulee
  statut text not null default 'publiee'
    check (statut in ('publiee', 'lue', 'contestee', 'maintenue', 'revisee', 'annulee')),
  created_at timestamptz not null default now(),
  lue_le timestamptz,
  contestation_motif text,
  contestee_le timestamptz,
  arbitre_id uuid references profils(id),
  arbitrage_commentaire text,
  arbitree_le timestamptz
);

-- Un appel n'est evalue qu'une fois (une evaluation annulee libere l'appel).
create unique index if not exists qc_evaluations_une_par_appel
  on qc_evaluations (qualification_id) where statut <> 'annulee';
create index if not exists qc_evaluations_agent_date on qc_evaluations (agent_id, created_at desc);
create index if not exists qc_evaluations_date on qc_evaluations (created_at desc);

alter table qc_evaluations enable row level security;
-- Aucune policy : lecture et ecriture uniquement par les fonctions ci-dessous.

alter table supervision_seuils add column if not exists lien_enregistrement text;


-- ---------------------------------------------------------------------------
-- 2. Grille par defaut (version 1), inseree seulement s'il n'y en a aucune
-- ---------------------------------------------------------------------------
insert into qc_grilles (version, actif, contenu)
select 1, true, $grille$
{
  "sections": [
    { "id": "accueil", "titre": "Accueil", "criteres": [
      { "id": "accueil_presentation", "libelle": "Salue, se présente et annonce appeler pour MTN", "points": 3 },
      { "id": "accueil_titulaire", "libelle": "Vérifie qu'il parle au titulaire de la box ou de la ligne", "points": 4 },
      { "id": "accueil_objet", "libelle": "Annonce clairement l'objet de l'appel", "points": 3 }
    ]},
    { "id": "decouverte", "titre": "Découverte", "criteres": [
      { "id": "decouverte_questions", "libelle": "Questionne sur l'usage, la satisfaction ou la raison du non-rechargement", "points": 8 },
      { "id": "decouverte_ecoute", "libelle": "Écoute active : laisse parler, reformule", "points": 7 }
    ]},
    { "id": "proposition", "titre": "Proposition", "criteres": [
      { "id": "proposition_adaptee", "libelle": "Offre adaptée au besoin identifié", "points": 8 },
      { "id": "proposition_exacte", "libelle": "Informations exactes : prix, validité, modalités de rechargement", "points": 8 },
      { "id": "proposition_clarte", "libelle": "Clarté, vocabulaire simple", "points": 4 }
    ]},
    { "id": "objections", "titre": "Objections", "criteres": [
      { "id": "objections_identifie", "libelle": "Identifie l'objection réelle", "points": 5 },
      { "id": "objections_repond", "libelle": "Répond avec un argument pertinent, sans insister lourdement", "points": 10 }
    ]},
    { "id": "conclusion", "titre": "Conclusion", "criteres": [
      { "id": "conclusion_recap", "libelle": "Récapitule l'engagement : date de rechargement, rappel convenu", "points": 5 },
      { "id": "conclusion_conge", "libelle": "Prise de congé courtoise", "points": 5 }
    ]},
    { "id": "savoir_etre", "titre": "Savoir-être", "criteres": [
      { "id": "savoir_etre_ton", "libelle": "Politesse, ton, sourire dans la voix", "points": 5 },
      { "id": "savoir_etre_attente", "libelle": "N'interrompt pas, annonce les mises en attente", "points": 5 },
      { "id": "savoir_etre_maitrise", "libelle": "Maîtrise de l'appel, durée adaptée", "points": 5 }
    ]},
    { "id": "qualification", "titre": "Qualification dans Auréo", "criteres": [
      { "id": "qualification_motif", "libelle": "Le motif choisi correspond à ce qui s'est réellement passé", "points": 8 },
      { "id": "qualification_commentaire", "libelle": "Commentaire utile quand nécessaire", "points": 4 },
      { "id": "qualification_rappel", "libelle": "Rappel posé à la date et l'heure convenues avec le client", "points": 3 }
    ]}
  ],
  "eliminatoires": [
    { "id": "elim_impolitesse", "libelle": "Impolitesse ou propos déplacés" },
    { "id": "elim_fausse_info", "libelle": "Fausse information ou promesse engageant MTN" },
    { "id": "elim_falsification", "libelle": "Qualification falsifiée (ex. « Pas de réponse » alors que le client a décroché)" },
    { "id": "elim_ne_plus_contacter", "libelle": "Non-respect d'une demande « Ne plus contacter »" },
    { "id": "elim_donnees", "libelle": "Informations du compte données à un tiers" }
  ],
  "niveaux": [
    { "min": 90, "libelle": "Excellent" },
    { "min": 75, "libelle": "Conforme" },
    { "min": 60, "libelle": "À améliorer" },
    { "min": 0, "libelle": "Non conforme" }
  ]
}
$grille$::jsonb
where not exists (select 1 from qc_grilles);


-- ---------------------------------------------------------------------------
-- 3. Outils internes
-- ---------------------------------------------------------------------------

-- Controle de forme d'une grille avant publication. Leve une exception au
-- premier defaut, avec un message lisible par l'admin qui l'a saisie.
create or replace function public.qc_verifier_grille(p_contenu jsonb)
returns void
language plpgsql
immutable
set search_path to 'public'
as $function$
declare
  v_section jsonb;
  v_critere jsonb;
  v_ids text[] := '{}';
  v_total numeric := 0;
begin
  if jsonb_typeof(p_contenu -> 'sections') is distinct from 'array' or jsonb_array_length(p_contenu -> 'sections') = 0 then
    raise exception 'La grille doit contenir au moins une section.';
  end if;
  for v_section in select * from jsonb_array_elements(p_contenu -> 'sections') loop
    if coalesce(trim(v_section ->> 'titre'), '') = '' then
      raise exception 'Chaque section doit avoir un titre.';
    end if;
    if jsonb_typeof(v_section -> 'criteres') is distinct from 'array' or jsonb_array_length(v_section -> 'criteres') = 0 then
      raise exception 'La section "%" ne contient aucun critere.', v_section ->> 'titre';
    end if;
    for v_critere in select * from jsonb_array_elements(v_section -> 'criteres') loop
      if coalesce(trim(v_critere ->> 'id'), '') = '' or coalesce(trim(v_critere ->> 'libelle'), '') = '' then
        raise exception 'Un critere de la section "%" n''a pas de libelle.', v_section ->> 'titre';
      end if;
      if (v_critere ->> 'id') = any(v_ids) then
        raise exception 'Identifiant de critere en double : %.', v_critere ->> 'id';
      end if;
      if jsonb_typeof(v_critere -> 'points') is distinct from 'number' or (v_critere ->> 'points')::numeric <= 0 then
        raise exception 'Le critere "%" doit valoir au moins 1 point.', v_critere ->> 'libelle';
      end if;
      v_ids := v_ids || (v_critere ->> 'id');
      v_total := v_total + (v_critere ->> 'points')::numeric;
    end loop;
  end loop;
  if jsonb_typeof(p_contenu -> 'eliminatoires') is distinct from 'array' then
    raise exception 'La liste des criteres eliminatoires est manquante (elle peut etre vide).';
  end if;
  if jsonb_typeof(p_contenu -> 'niveaux') is distinct from 'array' or jsonb_array_length(p_contenu -> 'niveaux') = 0 then
    raise exception 'La grille doit definir au moins un niveau.';
  end if;
  if not exists (select 1 from jsonb_array_elements(p_contenu -> 'niveaux') n where (n ->> 'min')::numeric = 0) then
    raise exception 'Un niveau doit commencer a 0, sinon une note basse n''aurait aucun niveau.';
  end if;
end;
$function$;

-- Note sur 100 et niveau. Chaque critere de la grille doit avoir une reponse :
-- oui (tous les points), partiel (la moitie), non (zero), na (retire du
-- total, la note est ramenee sur 100). Un eliminatoire coche met la note a 0.
create or replace function public.qc_calculer(p_grille jsonb, p_reponses jsonb, p_eliminatoires jsonb, out note numeric, out niveau text)
language plpgsql
immutable
set search_path to 'public'
as $function$
declare
  v_critere jsonb;
  v_rep text;
  v_obtenu numeric := 0;
  v_possible numeric := 0;
  v_elim_ids text[];
begin
  if jsonb_typeof(p_reponses) is distinct from 'object' then
    raise exception 'Reponses manquantes.';
  end if;

  for v_critere in
    select c from jsonb_array_elements(p_grille -> 'sections') s, jsonb_array_elements(s -> 'criteres') c
  loop
    v_rep := p_reponses ->> (v_critere ->> 'id');
    if v_rep is null then
      raise exception 'Critere sans reponse : %.', v_critere ->> 'libelle';
    end if;
    if v_rep not in ('oui', 'partiel', 'non', 'na') then
      raise exception 'Reponse inconnue pour "%" : %.', v_critere ->> 'libelle', v_rep;
    end if;
    if v_rep <> 'na' then
      v_possible := v_possible + (v_critere ->> 'points')::numeric;
      v_obtenu := v_obtenu + (v_critere ->> 'points')::numeric
        * case v_rep when 'oui' then 1 when 'partiel' then 0.5 else 0 end;
    end if;
  end loop;

  if v_possible = 0 then
    raise exception 'Tous les criteres sont "sans objet" : il n''y a rien a noter.';
  end if;

  select array_agg(e ->> 'id') into v_elim_ids from jsonb_array_elements(p_grille -> 'eliminatoires') e;
  if exists (
    select 1 from jsonb_array_elements_text(coalesce(p_eliminatoires, '[]'::jsonb)) x
    where x <> all(coalesce(v_elim_ids, '{}'))
  ) then
    raise exception 'Critere eliminatoire inconnu de cette grille.';
  end if;

  if jsonb_array_length(coalesce(p_eliminatoires, '[]'::jsonb)) > 0 then
    note := 0;
  else
    note := round(100 * v_obtenu / v_possible, 1);
  end if;

  select n ->> 'libelle' into niveau
  from jsonb_array_elements(p_grille -> 'niveaux') n
  where (n ->> 'min')::numeric <= note
  order by (n ->> 'min')::numeric desc
  limit 1;
end;
$function$;

-- Outils internes : appeles par les fonctions ci-dessous, jamais directement.
revoke execute on function public.qc_verifier_grille(jsonb) from public, anon, authenticated;
revoke execute on function public.qc_calculer(jsonb, jsonb, jsonb) from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 4. Appels proposes a l'evaluation (coach)
-- ---------------------------------------------------------------------------
-- Pour chaque agent de l'equipe, sur les p_jours derniers jours, parmi les
-- appels pas encore evalues :
--   - 2 tires au hasard ;
--   - 1 contact tres court (moins de 30 s de traitement alors que le client a
--     repondu : soit un appel expedie, soit une qualification douteuse) ;
--   - 1 vente ;
--   - 1 appel negatif.
-- S'y ajoutent, par agent, le nombre d'evaluations deja faites cette semaine
-- (objectif : 4) et son taux de contact sur la periode, compare a celui de
-- l'equipe, pour reperer les profils atypiques.
create or replace function public.qc_a_evaluer(p_jours integer default 7)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_moi uuid := auth.uid();
  v_role text;
  v_depuis timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_jours, 7), 31)));
  v_semaine timestamptz := date_trunc('week', now() at time zone 'Africa/Abidjan') at time zone 'Africa/Abidjan';
  v_resultat jsonb;
begin
  select role into v_role from profils where id = v_moi;
  if v_role is null or v_role not in ('coach', 'super_admin') then
    raise exception 'Seuls les coachs evaluent les appels.';
  end if;

  with equipe as (
    select pa.agent_id from mon_perimetre_agents() pa where pa.agent_id <> v_moi
  ),
  appels as (
    select q.id, q.agent_id, q.client_id, q.created_at, q.duree_secondes, q.commentaire,
           tq.categorie, tq.motif, tq.est_contact, tq.est_vente
    from qualifications q
    join types_qualification tq on tq.id = q.type_qualification_id
    where q.created_at >= v_depuis
      and q.agent_id in (select agent_id from equipe)
      and not exists (select 1 from qc_evaluations ev where ev.qualification_id = q.id and ev.statut <> 'annulee')
  ),
  tagues as (
    select a.*,
      row_number() over (partition by a.agent_id order by random()) as r_hasard,
      row_number() over (partition by a.agent_id, (a.est_contact and a.duree_secondes < 30) order by random()) as r_court,
      row_number() over (partition by a.agent_id, a.est_vente order by random()) as r_vente,
      row_number() over (partition by a.agent_id, (a.categorie = 'Négatif') order by random()) as r_negatif
    from appels a
  ),
  choisis as (
    select t.*, 'hasard' as raison from tagues t where t.r_hasard <= 2
    union all
    select t.*, 'contact_court' from tagues t where t.est_contact and t.duree_secondes < 30 and t.r_court = 1
    union all
    select t.*, 'vente' from tagues t where t.est_vente and t.r_vente = 1
    union all
    select t.*, 'negatif' from tagues t where t.categorie = 'Négatif' and t.r_negatif = 1
  ),
  -- Un meme appel peut sortir a plusieurs titres : on le garde une fois, avec
  -- la raison la plus parlante.
  dedoubles as (
    select distinct on (c.id) c.*
    from choisis c
    order by c.id, case c.raison when 'contact_court' then 0 when 'vente' then 1 when 'negatif' then 2 else 3 end
  ),
  par_agent as (
    select q.agent_id,
      count(*) as appels,
      count(*) filter (where tq.est_contact) as contacts
    from qualifications q
    join types_qualification tq on tq.id = q.type_qualification_id
    where q.created_at >= v_depuis and q.agent_id in (select agent_id from equipe)
    group by q.agent_id
  ),
  faites as (
    select ev.agent_id, count(*) as n
    from qc_evaluations ev
    where ev.created_at >= v_semaine and ev.statut <> 'annulee' and ev.agent_id in (select agent_id from equipe)
    group by ev.agent_id
  )
  select jsonb_build_object(
    'equipe_taux_contact', (select case when sum(appels) > 0 then round(100.0 * sum(contacts) / sum(appels), 1) end from par_agent),
    'agents', coalesce((
      select jsonb_agg(jsonb_build_object(
        'agent_id', p.id, 'nom', p.nom, 'matricule', p.matricule,
        'evaluations_semaine', coalesce(f.n, 0),
        'appels', coalesce(pa.appels, 0),
        'taux_contact', case when pa.appels > 0 then round(100.0 * pa.contacts / pa.appels, 1) end
      ) order by p.nom)
      from profils p
      left join par_agent pa on pa.agent_id = p.id
      left join faites f on f.agent_id = p.id
      where p.id in (select agent_id from equipe) and p.actif is not false
    ), '[]'::jsonb),
    'appels', coalesce((
      select jsonb_agg(jsonb_build_object(
        'qualification_id', d.id, 'agent_id', d.agent_id, 'created_at', d.created_at,
        'duree_secondes', d.duree_secondes, 'commentaire', d.commentaire,
        'categorie', d.categorie, 'motif', d.motif, 'raison', d.raison,
        'client_id', c.id, 'numero_fiche', c.numero_fiche, 'client_nom', c.nom,
        'telephone', c.telephone, 'numero_box', c.numero_box
      ) order by d.agent_id, d.created_at desc)
      from dedoubles d
      join clients c on c.id = d.client_id
    ), '[]'::jsonb)
  ) into v_resultat;

  return v_resultat;
end;
$function$;

revoke execute on function public.qc_a_evaluer(integer) from public, anon;
grant execute on function public.qc_a_evaluer(integer) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Evaluer (coach)
-- ---------------------------------------------------------------------------
create or replace function public.qc_evaluer(
  p_qualification_id uuid,
  p_reponses jsonb,
  p_eliminatoires jsonb,
  p_commentaire text,
  p_axes_progres text
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_moi uuid := auth.uid();
  v_role text;
  v_q qualifications;
  v_grille qc_grilles;
  v_calcul record;
  v_id uuid;
begin
  select role into v_role from profils where id = v_moi;
  if v_role is null or v_role not in ('coach', 'super_admin') then
    raise exception 'Seuls les coachs evaluent les appels.';
  end if;

  select * into v_q from qualifications where id = p_qualification_id;
  if v_q.id is null then
    raise exception 'Appel introuvable.';
  end if;
  if v_q.agent_id = v_moi then
    raise exception 'On n''evalue pas ses propres appels.';
  end if;
  if v_q.agent_id not in (select agent_id from mon_perimetre_agents()) then
    raise exception 'Cet agent ne fait pas partie de votre equipe.';
  end if;
  if exists (select 1 from qc_evaluations where qualification_id = p_qualification_id and statut <> 'annulee') then
    raise exception 'Cet appel a deja ete evalue.';
  end if;

  select * into v_grille from qc_grilles where actif;
  if v_grille.id is null then
    raise exception 'Aucune grille active.';
  end if;

  select * into v_calcul from qc_calculer(v_grille.contenu, p_reponses, coalesce(p_eliminatoires, '[]'::jsonb));

  insert into qc_evaluations (qualification_id, client_id, agent_id, evaluateur_id, grille_id,
                              reponses, eliminatoires, note, niveau, commentaire, axes_progres)
  values (v_q.id, v_q.client_id, v_q.agent_id, v_moi, v_grille.id,
          p_reponses, coalesce(p_eliminatoires, '[]'::jsonb), v_calcul.note, v_calcul.niveau,
          nullif(trim(p_commentaire), ''), nullif(trim(p_axes_progres), ''))
  returning id into v_id;

  return v_id;
end;
$function$;

revoke execute on function public.qc_evaluer(uuid, jsonb, jsonb, text, text) from public, anon;
grant execute on function public.qc_evaluer(uuid, jsonb, jsonb, text, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. Liste des evaluations
-- ---------------------------------------------------------------------------
-- Un agent ne voit que les siennes. L'encadrement voit celles de son perimetre.
-- Les annulees sont renvoyees (pour l'historique) ; l'ecran les exclut des
-- moyennes.
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
    'lue_le', ev.lue_le, 'contestation_motif', ev.contestation_motif, 'contestee_le', ev.contestee_le,
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

revoke execute on function public.qc_evaluations_liste(timestamptz, timestamptz) from public, anon;
grant execute on function public.qc_evaluations_liste(timestamptz, timestamptz) to authenticated;


-- ---------------------------------------------------------------------------
-- 7. Cote agent : lire, contester
-- ---------------------------------------------------------------------------
create or replace function public.qc_marquer_lue(p_evaluation_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update qc_evaluations
     set statut = 'lue', lue_le = now()
   where id = p_evaluation_id and agent_id = auth.uid() and statut = 'publiee';
end;
$function$;

revoke execute on function public.qc_marquer_lue(uuid) from public, anon;
grant execute on function public.qc_marquer_lue(uuid) to authenticated;

-- Contestation ouverte 7 jours apres la publication, une seule fois.
create or replace function public.qc_contester(p_evaluation_id uuid, p_motif text)
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
    raise exception 'Cette evaluation ne peut plus etre contestee.';
  end if;
  if v_ev.created_at < now() - interval '7 days' then
    raise exception 'Le delai de contestation (7 jours) est depasse.';
  end if;
  if coalesce(trim(p_motif), '') = '' then
    raise exception 'Expliquez ce que vous contestez.';
  end if;

  update qc_evaluations
     set statut = 'contestee', contestation_motif = trim(p_motif), contestee_le = now(),
         lue_le = coalesce(lue_le, now())
   where id = p_evaluation_id;
end;
$function$;

revoke execute on function public.qc_contester(uuid, text) from public, anon;
grant execute on function public.qc_contester(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 8. Arbitrage d'une contestation (superviseur, admin)
-- ---------------------------------------------------------------------------
-- p_decision : 'maintenue', 'revisee' (nouvelles reponses, note recalculee sur
-- la grille d'origine, l'ancienne note est conservee), ou 'annulee'.
create or replace function public.qc_arbitrer(
  p_evaluation_id uuid,
  p_decision text,
  p_commentaire text,
  p_reponses jsonb default null,
  p_eliminatoires jsonb default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_moi uuid := auth.uid();
  v_role text;
  v_ev qc_evaluations;
  v_grille jsonb;
  v_calcul record;
begin
  select role into v_role from profils where id = v_moi;
  if v_role is null or v_role not in ('superviseur', 'admin', 'super_admin') then
    raise exception 'Seul un superviseur tranche une contestation.';
  end if;

  select * into v_ev from qc_evaluations where id = p_evaluation_id;
  if v_ev.id is null or v_ev.agent_id not in (select agent_id from mon_perimetre_agents()) then
    raise exception 'Evaluation introuvable.';
  end if;
  if v_ev.statut <> 'contestee' then
    raise exception 'Cette evaluation n''est pas contestee.';
  end if;
  if p_decision not in ('maintenue', 'revisee', 'annulee') then
    raise exception 'Decision inconnue : %.', p_decision;
  end if;
  if coalesce(trim(p_commentaire), '') = '' then
    raise exception 'Expliquez votre decision a l''agent et au coach.';
  end if;

  if p_decision = 'revisee' then
    select contenu into v_grille from qc_grilles where id = v_ev.grille_id;
    select * into v_calcul from qc_calculer(v_grille, p_reponses, coalesce(p_eliminatoires, '[]'::jsonb));
    update qc_evaluations
       set reponses = p_reponses, eliminatoires = coalesce(p_eliminatoires, '[]'::jsonb),
           note_initiale = v_ev.note, note = v_calcul.note, niveau = v_calcul.niveau
     where id = p_evaluation_id;
  end if;

  update qc_evaluations
     set statut = p_decision, arbitre_id = v_moi, arbitrage_commentaire = trim(p_commentaire), arbitree_le = now()
   where id = p_evaluation_id;
end;
$function$;

revoke execute on function public.qc_arbitrer(uuid, text, text, jsonb, jsonb) from public, anon;
grant execute on function public.qc_arbitrer(uuid, text, text, jsonb, jsonb) to authenticated;


-- ---------------------------------------------------------------------------
-- 9. Suppression d'une evaluation faite par erreur
-- ---------------------------------------------------------------------------
-- Le coach peut retirer la sienne tant que l'agent ne l'a pas lue ; ensuite
-- seul le super admin le peut.
create or replace function public.qc_supprimer(p_evaluation_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_moi uuid := auth.uid();
  v_role text;
  v_n integer;
begin
  select role into v_role from profils where id = v_moi;
  delete from qc_evaluations
   where id = p_evaluation_id
     and (v_role = 'super_admin' or (evaluateur_id = v_moi and statut = 'publiee'));
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'Suppression impossible : evaluation introuvable, ou deja lue par l''agent.';
  end if;
end;
$function$;

revoke execute on function public.qc_supprimer(uuid) from public, anon;
grant execute on function public.qc_supprimer(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 10. Compteurs pour les pastilles du menu
-- ---------------------------------------------------------------------------
-- non_lues : mes evaluations pas encore lues (agent).
-- contestations : contestations de mon perimetre en attente (superviseur,
-- admin).
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
    'non_lues', (select count(*) from qc_evaluations where agent_id = v_moi and statut = 'publiee'),
    'contestations', v_contestations
  );
end;
$function$;

revoke execute on function public.qc_compteurs() from public, anon;
grant execute on function public.qc_compteurs() to authenticated;


-- ---------------------------------------------------------------------------
-- 11. Administration : grille et lien d'enregistrement
-- ---------------------------------------------------------------------------
create or replace function public.qc_publier_grille(p_contenu jsonb)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text;
  v_id uuid;
begin
  select role into v_role from profils where id = auth.uid();
  if v_role is null or v_role not in ('admin', 'super_admin') then
    raise exception 'Seuls les administrateurs modifient la grille.';
  end if;
  perform qc_verifier_grille(p_contenu);

  update qc_grilles set actif = false where actif;
  insert into qc_grilles (version, contenu, actif, created_by)
  values ((select coalesce(max(version), 0) + 1 from qc_grilles), p_contenu, true, auth.uid())
  returning id into v_id;
  return v_id;
end;
$function$;

revoke execute on function public.qc_publier_grille(jsonb) from public, anon;
grant execute on function public.qc_publier_grille(jsonb) to authenticated;

create or replace function public.qc_regler_lien_enregistrement(p_lien text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text;
begin
  select role into v_role from profils where id = auth.uid();
  if v_role is null or v_role not in ('admin', 'super_admin') then
    raise exception 'Seuls les administrateurs reglent le lien d''enregistrement.';
  end if;
  if nullif(trim(p_lien), '') is not null and trim(p_lien) !~* '^https?://' then
    raise exception 'Le lien doit commencer par http:// ou https://.';
  end if;
  update supervision_seuils
     set lien_enregistrement = nullif(trim(p_lien), ''), modifie_le = now(), modifie_par = auth.uid()
   where id = 1;
end;
$function$;

revoke execute on function public.qc_regler_lien_enregistrement(text) from public, anon;
grant execute on function public.qc_regler_lien_enregistrement(text) to authenticated;


-- ---------------------------------------------------------------------------
-- Verification : l'editeur n'affiche que le resultat de la derniere requete.
-- Attendu : 12 fonctions, une grille active en version 1, 0 evaluation.
-- ---------------------------------------------------------------------------
notify pgrst, 'reload schema';

select
  (select count(*) from pg_proc where proname like 'qc\_%') as fonctions_qc,
  (select version from qc_grilles where actif) as version_grille_active,
  (select count(*) from qc_evaluations) as evaluations;

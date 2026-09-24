-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- Volet supervision : mur temps reel, indicateurs du jour et alertes.
--
-- 1. supervision_seuils : les seuils d'alerte reglables (une seule ligne).
-- 2. supervision_direct() : tout le mur en un seul appel, une ligne par agent
--    du perimetre de l'appelant. Les agregats sont faits en base : le
--    navigateur recoit une ligne par agent, pas les milliers de qualifications
--    du jour. L'ecran l'appelle toutes les 30 secondes. Chaque ligne porte
--    l'heure du serveur : les chronometres de l'ecran partent d'elle, et non de
--    l'horloge du poste, qui peut avoir plusieurs minutes d'avance ou de retard.
-- 3. supervision_regler_seuils() : modification des seuils, admins seulement.
--
-- Perimetre : celui de mon_perimetre_agents(), comme les autres rapports. Un
-- coach voit son equipe, un superviseur ses coachs et leurs equipes, un admin
-- ses superviseurs, le super admin tout le monde.
--
-- La journee est celle d'Abidjan, ecrite en toutes lettres : le serveur tourne
-- en UTC aujourd'hui (meme heure qu'Abidjan), mais rien ne garantit qu'il le
-- restera apres la migration vers le serveur de XGS.


-- ---------------------------------------------------------------------------
-- 1. Seuils
-- ---------------------------------------------------------------------------
-- Valeurs par defaut tirees des 7 derniers jours (22 900 qualifications) :
-- duree de traitement mediane 1 min 28, 99 % sous 10 minutes. Au-dela de 10
-- minutes sur une fiche, l'appel sort donc nettement de l'ordinaire.
-- L'inactivite ne se mesure qu'en Production sans fiche ouverte : 5 minutes
-- sans rien prendre, c'est un agent qui ne travaille pas ou qui est bloque.
-- Les pauses gardent leurs propres limites (pause_types.duree_max_minutes et
-- occurrences_max_jour), deja reglees par type.

create table if not exists supervision_seuils (
  id integer primary key default 1 check (id = 1),
  appel_long_minutes integer not null default 10 check (appel_long_minutes between 1 and 240),
  inactivite_minutes integer not null default 5 check (inactivite_minutes between 1 and 240),
  modifie_le timestamptz not null default now(),
  modifie_par uuid references profils(id)
);

insert into supervision_seuils (id) values (1) on conflict (id) do nothing;

alter table supervision_seuils enable row level security;

drop policy if exists supervision_seuils_lecture on supervision_seuils;
create policy supervision_seuils_lecture on supervision_seuils
  for select to authenticated using (true);
-- Aucune policy d'ecriture : on ne modifie que par supervision_regler_seuils().


-- ---------------------------------------------------------------------------
-- 2. Le mur
-- ---------------------------------------------------------------------------
create or replace function public.supervision_direct()
returns table(
  agent_id uuid,
  nom text,
  matricule text,
  role text,
  equipe text,
  statut text,
  statut_depuis timestamptz,
  pause_type_id uuid,
  pause_debut timestamptz,
  fiche_id uuid,
  fiche_numero text,
  fiche_nom text,
  fiche_depuis timestamptz,
  fiches_en_cours integer,
  derniere_qualif_le timestamptz,
  derniere_qualif_categorie text,
  derniere_qualif_motif text,
  fiches_jour integer,
  contacts_jour integer,
  ventes_jour integer,
  duree_moy_secondes integer,
  secondes_prod integer,
  secondes_pause integer,
  pauses_jour jsonb,
  serveur_maintenant timestamptz
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role text;
  v_maintenant timestamptz := now();
  v_debut timestamptz := date_trunc('day', now() at time zone 'Africa/Abidjan') at time zone 'Africa/Abidjan';
begin
  select p.role into v_role from profils p where p.id = auth.uid();
  if v_role is null or v_role not in ('coach', 'superviseur', 'admin', 'super_admin') then
    raise exception 'Acces reserve a l''encadrement.';
  end if;

  return query
  with perimetre as (
    select pa.agent_id as id from mon_perimetre_agents() pa
  ),
  -- Dernier etat connu : la ligne d'historique la plus recente de chaque agent.
  etat as (
    select distinct on (sh.agent_id) sh.agent_id, sh.debut
    from statuts_historique sh
    where sh.agent_id in (select id from perimetre)
    order by sh.agent_id, sh.debut desc
  ),
  -- Temps du jour par statut, borne a la journee et a maintenant : une pause
  -- ouverte compte jusqu'a cet instant, une session commencee hier ne compte
  -- qu'a partir de minuit.
  temps as (
    select sh.agent_id,
      sum(extract(epoch from least(coalesce(sh.fin, v_maintenant), v_maintenant) - greatest(sh.debut, v_debut)))
        filter (where sh.statut = 'en_prod') as prod,
      sum(extract(epoch from least(coalesce(sh.fin, v_maintenant), v_maintenant) - greatest(sh.debut, v_debut)))
        filter (where sh.statut = 'en_pause') as pause
    from statuts_historique sh
    where sh.agent_id in (select id from perimetre)
      and coalesce(sh.fin, v_maintenant) > v_debut
      and sh.debut < v_maintenant
    group by sh.agent_id
  ),
  pause_ouverte as (
    select distinct on (pd.agent_id) pd.agent_id, pd.pause_type_id, pd.debut
    from pause_details pd
    where pd.agent_id in (select id from perimetre) and pd.fin is null
    order by pd.agent_id, pd.debut desc
  ),
  -- Pauses du jour par type : nombre et duree, pour les quotas.
  pauses_par_type as (
    select pd.agent_id, pd.pause_type_id,
      count(*) as n,
      sum(extract(epoch from least(coalesce(pd.fin, v_maintenant), v_maintenant) - greatest(pd.debut, v_debut))) as secondes
    from pause_details pd
    where pd.agent_id in (select id from perimetre)
      and pd.debut >= v_debut
    group by pd.agent_id, pd.pause_type_id
  ),
  pauses as (
    select ppt.agent_id,
      jsonb_agg(jsonb_build_object('type', ppt.pause_type_id, 'n', ppt.n, 'secondes', round(ppt.secondes))) as detail
    from pauses_par_type ppt
    group by ppt.agent_id
  ),
  -- Fiche ouverte : la plus recemment prise. Plusieurs fiches en cours sous un
  -- meme agent signalent des fiches oubliees ; on les compte a part.
  fiches as (
    select c.agent_id, count(*) as n,
      (array_agg(c.id order by c.recuperee_le desc nulls last))[1] as id,
      (array_agg(c.numero_fiche::text order by c.recuperee_le desc nulls last))[1] as numero,
      (array_agg(c.nom order by c.recuperee_le desc nulls last))[1] as nom,
      max(c.recuperee_le) as depuis
    from clients c
    where c.statut = 'en_cours' and c.agent_id in (select id from perimetre)
    group by c.agent_id
  ),
  qj as (
    select q.agent_id, q.created_at, q.duree_secondes, tq.categorie, tq.motif, tq.est_contact, tq.est_vente
    from qualifications q
    join types_qualification tq on tq.id = q.type_qualification_id
    where q.created_at >= v_debut
      and q.agent_id in (select id from perimetre)
  ),
  stats as (
    select qj.agent_id,
      count(*) as fiches,
      count(*) filter (where qj.est_contact) as contacts,
      count(*) filter (where qj.est_vente) as ventes,
      avg(qj.duree_secondes) filter (where qj.duree_secondes is not null) as duree_moy
    from qj
    group by qj.agent_id
  ),
  derniere as (
    select distinct on (qj.agent_id) qj.agent_id, qj.created_at, qj.categorie, qj.motif
    from qj
    order by qj.agent_id, qj.created_at desc
  )
  select
    p.id,
    p.nom::text,
    p.matricule::text,
    p.role::text,
    coalesce(e.nom, ec.nom)::text,
    p.statut::text,
    etat.debut,
    case when p.statut = 'en_pause' then po.pause_type_id end,
    case when p.statut = 'en_pause' then po.debut end,
    f.id,
    f.numero,
    f.nom::text,
    f.depuis,
    coalesce(f.n, 0)::int,
    d.created_at,
    d.categorie::text,
    d.motif::text,
    coalesce(s.fiches, 0)::int,
    coalesce(s.contacts, 0)::int,
    coalesce(s.ventes, 0)::int,
    round(s.duree_moy)::int,
    coalesce(round(t.prod), 0)::int,
    coalesce(round(t.pause), 0)::int,
    coalesce(pa.detail, '[]'::jsonb),
    v_maintenant
  from profils p
  left join equipes e on e.id = p.equipe_id
  left join lateral (select e2.nom from equipes e2 where e2.coach_id = p.id order by e2.nom limit 1) ec on p.role = 'coach'
  left join etat on etat.agent_id = p.id
  left join temps t on t.agent_id = p.id
  left join pause_ouverte po on po.agent_id = p.id
  left join pauses pa on pa.agent_id = p.id
  left join fiches f on f.agent_id = p.id
  left join stats s on s.agent_id = p.id
  left join derniere d on d.agent_id = p.id
  where p.id in (select id from perimetre)
    and p.actif is not false
  order by p.nom;
end;
$function$;

revoke execute on function public.supervision_direct() from public, anon;
grant execute on function public.supervision_direct() to authenticated;


-- ---------------------------------------------------------------------------
-- 3. Reglage des seuils
-- ---------------------------------------------------------------------------
create or replace function public.supervision_regler_seuils(p_appel_long_minutes integer, p_inactivite_minutes integer)
returns supervision_seuils
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text;
  v_ligne supervision_seuils;
begin
  select role into v_role from profils where id = auth.uid();
  if v_role is null or v_role not in ('admin', 'super_admin') then
    raise exception 'Seuls les administrateurs reglent les seuils d''alerte.';
  end if;

  update supervision_seuils
     set appel_long_minutes = p_appel_long_minutes,
         inactivite_minutes = p_inactivite_minutes,
         modifie_le = now(),
         modifie_par = auth.uid()
   where id = 1
  returning * into v_ligne;

  return v_ligne;
end;
$function$;

revoke execute on function public.supervision_regler_seuils(integer, integer) from public, anon;
grant execute on function public.supervision_regler_seuils(integer, integer) to authenticated;


-- ---------------------------------------------------------------------------
-- Verification : l'editeur n'affiche que le resultat de la derniere requete.
-- Deux lignes attendues : supervision_direct et supervision_regler_seuils.
-- ---------------------------------------------------------------------------
notify pgrst, 'reload schema';

select proname from pg_proc where proname like 'supervision%' order by proname;

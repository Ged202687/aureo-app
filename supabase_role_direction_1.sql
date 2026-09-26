-- Role "direction", morceau 1 sur 3 (le role et la lecture d'Horizon) :
-- la direction generale voit les statistiques, sans rien
-- pouvoir modifier.
--
-- Le role est ajoute seulement aux regles de LECTURE :
--   - perimetre (mon_perimetre_agents, mon_perimetre_personnes) : tout le
--     plateau, comme le super admin ;
--   - supervision en direct et tableau de bord par lot ;
--   - assiduite (Horizon), en lecture ;
--   - Zenith : acces direction, et hors effectif (comme admin et super admin).
-- Il n'est ajoute a AUCUNE regle d'ecriture (is_admin, est_super_admin,
-- fonctions admin_*, super_admin_*, qc_*, forcer_statut_agent...). Comme les
-- administrateurs, elle consulte aussi depuis l'exterieur du plateau
-- (acces_plateau_pour) : en lecture seule, faute de tout droit d'ecriture.
--
-- Les fonctions existantes sont modifiees sur place : leur definition en base
-- est relue, un seul fragment y est remplace, et le script s'arrete si ce
-- fragment n'y figure pas exactement une fois (rien n'est alors modifie).
--
-- Enfin, FLAN Nadine (AGT-001, directrice generale) passe au role direction,
-- et la fonction de diagnostic temporaire est supprimee.
--
-- Dans Zenith, la direction LIT ; les saisies (motif, date d'entree, projet
-- declare) restent a l'administration : ces fonctions passent de
-- est_direction() a est_administration().
--
-- Morceaux : 1 (role, Horizon), 2 (les 13 fonctions), 3 (FLAN Nadine).
--
-- Rien ne change encore pour personne : le role existe, mais aucun compte ne
-- l'a avant le morceau 3.
--
-- A executer dans le SQL Editor (Ctrl+A, Suppr, coller, Executer).

-- 0. L'administration (admin, super admin) : seule a pouvoir modifier.
create or replace function public.est_administration()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profils
    where id = auth.uid() and role in ('admin', 'super_admin') and coalesce(actif, true)
  );
$$;
grant execute on function public.est_administration() to authenticated;

-- Le role est accepte par la table des profils : l'ancienne contrainte
-- (quel que soit son nom) est remplacee.
do $$
declare
  def text;
begin
  for def in
    select c.conname from pg_constraint c
    where c.conrelid = 'public.profils'::regclass and c.contype = 'c' and pg_get_constraintdef(c.oid) ilike '%role%'
  loop
    execute format('alter table public.profils drop constraint %I', def);
  end loop;
  alter table public.profils add constraint profils_role_check
    check (role = any (array['super_admin', 'admin', 'superviseur', 'coach', 'agent', 'direction']));

end $$;

-- 4. Assiduite (Horizon) : la direction lit tout, sans pouvoir justifier.
drop policy if exists "select assiduite_statuts_jour" on public.assiduite_statuts_jour;
create policy "select assiduite_statuts_jour" on public.assiduite_statuts_jour
  for select
  using (
    (horizon_my_role() = any (array['admin', 'super_admin', 'direction']))
    or ((horizon_my_role() = any (array['coach', 'superviseur']))
        and (agent_id in (select profils.id from profils where profils.equipe_id in (select horizon_my_team_ids()))))
    or (agent_id = auth.uid())
  );

-- Verification : la contrainte accepte le role direction.
select pg_get_constraintdef(c.oid) as contrainte_role
from pg_constraint c
where c.conrelid = 'public.profils'::regclass and c.contype = 'c' and pg_get_constraintdef(c.oid) ilike '%role%';

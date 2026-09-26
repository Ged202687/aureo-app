-- Role "direction", morceau 3 sur 3 : FLAN Nadine passe au role direction.
--
-- A executer dans le SQL Editor apres les morceaux 1 et 2.

-- 5. FLAN Nadine, directrice generale.
update public.profils
set role = 'direction', equipe_id = null, superviseur_id = null, admin_id = null
where matricule = 'AGT-001';

-- 6. Le diagnostic temporaire n'a plus lieu d'etre.
drop function if exists public.xgs_diag_roles();

-- Verification : le compte de la direction, et le perimetre qu'il verra.
select nom, matricule, role, actif from public.profils where role = 'direction';

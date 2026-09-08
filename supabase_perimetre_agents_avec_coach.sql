-- À exécuter une seule fois dans l'éditeur SQL de Supabase (Dashboard > SQL Editor).
-- Corrige mon_perimetre_agents() : un coach peut traiter des fiches depuis son propre
-- poste de travail (rôle "coach" dans ROLE_DEFAULT_TABS), mais la fonction ne comptait
-- jusqu'ici que les profils de rôle "agent" — les qualifications faites par le coach
-- lui-même étaient donc invisibles dans "Mes résultats", le détail par agent, et tout
-- rapport agrégé (admin, super admin, superviseur) qui s'appuie sur cette fonction.

create or replace function public.mon_perimetre_agents()
returns table(agent_id uuid)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_caller uuid := auth.uid();
  v_role text;
begin
  select role into v_role from profils where id = v_caller;

  if v_role = 'super_admin' then
    return query select id from profils where role in ('agent', 'coach');

  elsif v_role = 'admin' then
    return query
      select p.id from profils p
      join equipes e on e.id = p.equipe_id
      join profils coach on coach.id = e.coach_id
      join profils sup on sup.id = coach.superviseur_id
      where sup.admin_id = v_caller and p.role = 'agent'
      union
      select coach.id from profils coach
      join equipes e on e.coach_id = coach.id
      join profils sup on sup.id = coach.superviseur_id
      where sup.admin_id = v_caller;

  elsif v_role = 'superviseur' then
    return query
      select p.id from profils p
      join equipes e on e.id = p.equipe_id
      join profils coach on coach.id = e.coach_id
      where coach.superviseur_id = v_caller and p.role = 'agent'
      union
      select coach.id from profils coach
      join equipes e on e.coach_id = coach.id
      where coach.superviseur_id = v_caller;

  elsif v_role = 'coach' then
    return query
      select p.id from profils p
      join equipes e on e.id = p.equipe_id
      where e.coach_id = v_caller and p.role = 'agent'
      union
      select v_caller;

  else
    return query select v_caller; -- agent : lui-même uniquement
  end if;
end;
$function$;

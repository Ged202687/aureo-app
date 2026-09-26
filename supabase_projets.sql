-- Projets (MTN, FIDELIS, NSIA...) : regrouper les agents par projet dans Aureo.
--
-- Le projet se rattache a l'AGENT (coachs compris) : une equipe peut melanger
-- deux projets, et un agent prete a un autre projet change de projet sans
-- changer d'equipe. L'ecran Equipes permet aussi d'affecter toute une equipe
-- d'un coup.
--
-- Chaque changement de projet est garde dans projets_historique (date du
-- jour) : Zenith y lit le projet de chaque mois, et voit une migration des
-- le changement dans Aureo, sans attendre le bulletin. Pour les mois
-- d'avant cet historique, Zenith garde le projet des bulletins.
--
-- Reprise : les projets deja connus par les bulletins (et les projets
-- declares dans Zenith) sont crees, et chaque agent recoit le projet de son
-- dernier bulletin.
--
-- En fin de script, une fonction de diagnostic TEMPORAIRE (super admin
-- seulement) decrit les regles d'acces de la base : elle sert a preparer le
-- role "Direction" en lecture seule, et sera supprimee ensuite.
--
-- A executer dans le SQL Editor (Ctrl+A, Suppr, coller, Executer).

-- 1. Les projets.
create table if not exists public.projets (
  id uuid primary key default gen_random_uuid(),
  nom text not null unique check (nullif(trim(nom), '') is not null),
  actif boolean not null default true,
  cree_le timestamptz not null default now()
);
alter table public.projets enable row level security;
revoke all on public.projets from public, anon;
grant select on public.projets to authenticated;
drop policy if exists "projets lisibles" on public.projets;
create policy "projets lisibles" on public.projets for select to authenticated using (true);

-- 2. Le projet de chaque agent, et son historique.
alter table public.profils add column if not exists projet_id uuid references public.projets (id) on delete set null;

create table if not exists public.projets_historique (
  id uuid primary key default gen_random_uuid(),
  profil_id uuid not null references public.profils (id) on delete cascade,
  projet_id uuid references public.projets (id) on delete set null,
  date_debut date not null default current_date,
  cree_le timestamptz not null default now()
);
create index if not exists projets_historique_profil_idx on public.projets_historique (profil_id, date_debut desc);
alter table public.projets_historique enable row level security;
revoke all on public.projets_historique from public, anon;
grant select on public.projets_historique to authenticated;
drop policy if exists "historique des projets lisible par la direction" on public.projets_historique;
create policy "historique des projets lisible par la direction"
  on public.projets_historique for select
  using (public.est_direction());

create or replace function public.suivre_projet_profil()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.projet_id is not null then
      insert into projets_historique (profil_id, projet_id) values (new.id, new.projet_id);
    end if;
  elsif new.projet_id is distinct from old.projet_id then
    insert into projets_historique (profil_id, projet_id) values (new.id, new.projet_id);
  end if;
  return new;
end;
$$;
drop trigger if exists suivre_projet_profil on public.profils;
create trigger suivre_projet_profil
  after insert or update of projet_id on public.profils
  for each row execute function public.suivre_projet_profil();

-- 3. Gestion, reservee au super admin (comme les equipes).
create or replace function public.super_admin_creer_projet(p_nom text)
returns public.projets
language plpgsql
security definer
set search_path = public
as $$
declare
  ligne projets;
begin
  if not est_super_admin() then
    raise insufficient_privilege using message = 'Réservé au super administrateur.';
  end if;
  insert into projets (nom) values (trim(p_nom)) returning * into ligne;
  return ligne;
end;
$$;

create or replace function public.super_admin_modifier_projet(p_projet_id uuid, p_nom text, p_actif boolean)
returns public.projets
language plpgsql
security definer
set search_path = public
as $$
declare
  ligne projets;
begin
  if not est_super_admin() then
    raise insufficient_privilege using message = 'Réservé au super administrateur.';
  end if;
  update projets
  set nom = coalesce(nullif(trim(p_nom), ''), nom), actif = coalesce(p_actif, actif)
  where id = p_projet_id
  returning * into ligne;
  if ligne.id is null then
    raise exception 'Projet introuvable.';
  end if;
  return ligne;
end;
$$;

-- Affecter un projet a une ou plusieurs personnes (toute une equipe d'un
-- coup) ; p_projet_id vide retire le projet.
create or replace function public.super_admin_affecter_projet(p_profil_ids uuid[], p_projet_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if not est_super_admin() then
    raise insufficient_privilege using message = 'Réservé au super administrateur.';
  end if;
  if p_projet_id is not null and not exists (select 1 from projets where id = p_projet_id and actif) then
    raise exception 'Projet introuvable ou désactivé.';
  end if;
  update profils set projet_id = p_projet_id
  where id = any (p_profil_ids) and projet_id is distinct from p_projet_id;
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke execute on function public.super_admin_creer_projet(text) from public, anon;
revoke execute on function public.super_admin_modifier_projet(uuid, text, boolean) from public, anon;
revoke execute on function public.super_admin_affecter_projet(uuid[], uuid) from public, anon;
grant execute on function public.super_admin_creer_projet(text) to authenticated;
grant execute on function public.super_admin_modifier_projet(uuid, text, boolean) to authenticated;
grant execute on function public.super_admin_affecter_projet(uuid[], uuid) to authenticated;

-- 4. Reprise : projets connus, et projet du dernier bulletin (ou declare).
insert into public.projets (nom)
select distinct trim(x.projet)
from (
  select projet from public.bulletins_salaire
  union all
  select projet from public.zenith_projet_declare
) x
where nullif(trim(x.projet), '') is not null
on conflict (nom) do nothing;

update public.profils p
set projet_id = pr.id
from public.projets pr
where p.projet_id is null
  and pr.nom = coalesce(
    (select trim(b.projet) from public.bulletins_salaire b
      where b.profil_id = p.id and nullif(trim(b.projet), '') is not null
      order by b.annee desc, b.mois desc limit 1),
    (select trim(d.projet) from public.zenith_projet_declare d where d.profil_id = p.id)
  );

-- 5. Diagnostic TEMPORAIRE pour le role "Direction" (super admin seulement).
create or replace function public.xgs_diag_roles()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from profils where id = auth.uid() and role::text = 'super_admin') then
    raise insufficient_privilege using message = 'Réservé au super administrateur.';
  end if;
  return jsonb_build_object(
    'type_role', (select format_type(a.atttypid, a.atttypmod) from pg_attribute a
                  where a.attrelid = 'public.profils'::regclass and a.attname = 'role'),
    'valeurs_enum', (select jsonb_agg(e.enumlabel order by e.enumsortorder) from pg_attribute a
                     join pg_enum e on e.enumtypid = a.atttypid
                     where a.attrelid = 'public.profils'::regclass and a.attname = 'role'),
    'contraintes_role', (select jsonb_agg(pg_get_constraintdef(c.oid)) from pg_constraint c
                         where c.conrelid = 'public.profils'::regclass and pg_get_constraintdef(c.oid) ilike '%role%'),
    'fonctions', (select jsonb_agg(jsonb_build_object('nom', p.proname, 'definition', pg_get_functiondef(p.oid)) order by p.proname)
                  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.prokind = 'f'
                    and pg_get_functiondef(p.oid) ~* '(super_admin|''admin''|superviseur|role)'),
    'politiques', (select jsonb_agg(jsonb_build_object('table', tablename, 'nom', policyname, 'commande', cmd,
                                                       'roles', roles, 'condition', qual, 'controle', with_check)
                                    order by tablename, policyname)
                   from pg_policies where schemaname = 'public')
  );
end;
$$;
revoke execute on function public.xgs_diag_roles() from public, anon;
grant execute on function public.xgs_diag_roles() to authenticated;

-- Verification : les projets et leurs effectifs.
select pr.nom, pr.actif, count(p.id) as personnes
from public.projets pr
left join public.profils p on p.projet_id = pr.id
group by pr.nom, pr.actif
order by pr.nom;

-- Securite, niveau 2 : les donnees d'Aureo et d'Horizon ne se lisent que
-- depuis le plateau XGS (ou par un administrateur / super administrateur).
--
-- Le niveau 1 (portail) ferme les pages ; celui-ci ferme les donnees : un
-- identifiant valide ne suffit plus pour interroger l'API Supabase depuis
-- chez soi. Mecanisme : une fonction "pre-request", appelee par PostgREST
-- avant CHAQUE requete de l'API (tables, vues et fonctions rpc), qui refuse
-- ce qui n'est pas autorise hors du plateau.
--
-- Hors du plateau, restent ouverts a tous (liste blanche) :
--   - Meridien : plannings, profils_planning, equipes, demandes_swap,
--     equite_rotation, modeles_horaire, notifications, parametres_pause,
--     pauses, et ses fonctions de shift et d'echange ;
--   - Mon Salaire : bulletins_salaire, profils ;
--   - la connexion au portail : email_from_login, mark_password_changed.
-- Tout le reste (fiches, qualifications, messagerie, supervision, presence,
-- set_my_status, pause_details...) est refuse hors du plateau, sauf aux
-- administrateurs et super administrateurs.
--
-- Adresse de l'appelant : l'en-tete cf-connecting-ip, pose par Cloudflare
-- devant l'API Supabase. Verifie le 26/09 : il porte la vraie adresse, et une
-- requete qui tente de le fournir elle-meme est rejetee par Cloudflare. Les
-- autres en-tetes (x-forwarded-for, true-client-ip...) sont falsifiables et
-- ne sont PAS utilises.
--
-- Tant que la table plateau_ip est vide, rien n'est bloque : on remplit la
-- table (etape 6) quand l'adresse du plateau est connue.
--
-- Pas de temps reel : les abonnements Realtime ne passent pas par PostgREST
-- et gardent leurs regles RLS habituelles.
--
-- A executer dans le SQL Editor (Ctrl+A, Suppr, coller, Executer).

-- 0. Le diagnostic du 26/09 n'a plus lieu d'etre.
drop function if exists public.diag_ip_appelant();

-- 1. Garde-fou : ne pas ecraser un pre-request deja en place.
do $$
declare
  existant text;
begin
  select c into existant
  from pg_roles r, unnest(r.rolconfig) as c
  where r.rolname = 'authenticator' and c like 'pgrst.db_pre_request=%';
  if existant is not null and existant <> 'pgrst.db_pre_request=public.xgs_verifier_requete' then
    raise exception 'Un pre-request est deja configure (%) : script arrete, rien n a ete modifie.', existant;
  end if;
end $$;

-- 2. Adresses du plateau. Illisible par l'API (RLS sans regle, droits
-- retires) : elle se gere ici, dans le SQL Editor.
create table if not exists public.plateau_ip (
  plage cidr primary key,
  libelle text,
  cree_le timestamptz not null default now()
);
alter table public.plateau_ip enable row level security;
revoke all on public.plateau_ip from public, anon, authenticated;

-- 3. Adresse de l'appelant (null hors d'une requete de l'API).
create or replace function public.ip_appelant()
returns inet
language plpgsql
stable
as $$
declare
  valeur text;
begin
  valeur := nullif(current_setting('request.headers', true), '')::jsonb ->> 'cf-connecting-ip';
  return valeur::inet;
exception when others then
  return null;
end;
$$;

-- 4. La regle, testable pour n'importe quelle adresse et personne :
--    select public.acces_plateau_pour('41.202.10.5', null);
create or replace function public.acces_plateau_pour(p_ip inet, p_uid uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  -- Regle pas encore configuree : rien n'est bloque.
  if not exists (select 1 from plateau_ip) then
    return true;
  end if;
  if p_ip is not null and exists (select 1 from plateau_ip where p_ip <<= plage) then
    return true;
  end if;
  -- Exception : administrateurs et super administrateurs actifs.
  if p_uid is not null and exists (
    select 1 from profils
    where id = p_uid and role in ('admin', 'super_admin') and coalesce(actif, true)
  ) then
    return true;
  end if;
  return false;
end;
$$;
revoke execute on function public.acces_plateau_pour(inet, uuid) from public, anon, authenticated;

create or replace function public.acces_plateau()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.acces_plateau_pour(public.ip_appelant(), auth.uid());
$$;

-- 5. Le pre-request. Hors liste blanche et hors du plateau : refus 403.
create or replace function public.xgs_verifier_requete()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ressource text := regexp_replace(coalesce(current_setting('request.path', true), ''), '^/+', '');
begin
  if ressource = any (array[
    -- Meridien
    'plannings', 'profils_planning', 'equipes', 'demandes_swap', 'equite_rotation',
    'modeles_horaire', 'notifications', 'parametres_pause', 'pauses',
    'rpc/valider_shift', 'rpc/devalider_shift', 'rpc/shift_resume',
    'rpc/traiter_demande_swap', 'rpc/rechercher_comptes_aureo_disponibles',
    -- Mon Salaire
    'bulletins_salaire', 'profils',
    -- Connexion au portail
    'rpc/email_from_login', 'rpc/mark_password_changed'
  ]) then
    return;
  end if;
  if public.acces_plateau() then
    return;
  end if;
  raise insufficient_privilege using message = 'Accessible uniquement depuis le plateau XGS.';
end;
$$;
grant execute on function public.xgs_verifier_requete() to anon, authenticated;
grant execute on function public.acces_plateau() to anon, authenticated;

alter role authenticator set pgrst.db_pre_request = 'public.xgs_verifier_requete';
notify pgrst, 'reload config';

-- 6. PLUS TARD (lundi), une fois l'adresse du plateau connue :
--   insert into public.plateau_ip (plage, libelle) values ('41.202.10.5/32', 'Plateau - ligne principale');
-- Retour arriere immediat en cas de souci : delete from public.plateau_ip;

-- Verification : pre-request en place, table vide (donc rien de bloque).
select
  (select c from pg_roles r, unnest(r.rolconfig) as c where r.rolname = 'authenticator' and c like 'pgrst.db_pre_request=%') as pre_request,
  (select count(*) from public.plateau_ip) as adresses_plateau,
  public.acces_plateau_pour('8.8.8.8', null) as regle_vide_laisse_passer;

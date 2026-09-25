-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
-- Peut etre relance sans risque. S'execute d'un bloc : en cas d'erreur, rien
-- n'est modifie.
--
-- Le verrou "Rechargement valide" (30 jours) se verifiait par FICHE. Or une
-- meme box peut exister dans plusieurs fiches (plusieurs lots, ou un doublon
-- d'import) : valider l'une n'empechait pas de valider l'autre, et le meme
-- rechargement etait compte deux fois. Mesure au 25/09/2026 : 12 doublons de
-- ce type, dont 5 le matin meme (lot CONVERTION, box deja validees dans les
-- lots FTTH).
--
-- Le verrou porte desormais sur la BOX, toutes fiches et tous lots confondus :
--   - fin_verrou_rechargement() regarde les validations de toutes les fiches
--     de la meme box ;
--   - le trigger sur qualifications refuse une nouvelle validation d'une box
--     deja validee depuis moins de 30 jours, meme depuis une autre fiche
--     (l'agent choisit alors "A deja recharge"). La regle existante est
--     conservee : sur la fiche validee elle-meme, aucune qualification ;
--   - le trigger sur clients (trg_maintenir_verrou_rechargement, deja en
--     place) s'appuie sur fin_verrou_rechargement() : les autres fiches de la
--     box sont donc elles aussi retirees de la distribution pendant le verrou ;
--   - verrous_rechargement() donne a la recherche agent la date de validation
--     des fiches trouvees, pour afficher "verrouillee" au lieu de proposer de
--     les ouvrir ;
--   - les fiches d'une box verrouillee encore en circulation sont retirees.
-- Une fiche sans numero de box garde le verrou par fiche, comme avant.


-- ---------------------------------------------------------------------------
-- 0. Index sur le numero de box, cree seulement s'il n'en existe aucun.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public' and tablename = 'clients'
      and indexdef ~ '\(numero_box[,)]'
  ) then
    create index clients_numero_box_idx on clients (numero_box);
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 1. Fin du verrou : toutes les fiches de la meme box
-- ---------------------------------------------------------------------------
create or replace function public.fin_verrou_rechargement(p_client_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path to 'public'
as $function$
  select max(q.created_at) + interval '30 days'
  from qualifications q
  join types_qualification tq on tq.id = q.type_qualification_id
  where q.client_id in (
          select p_client_id
          union
          select c2.id
          from clients c1
          join clients c2 on c2.numero_box = c1.numero_box
          where c1.id = p_client_id and nullif(trim(c1.numero_box), '') is not null
        )
    and tq.categorie = 'Positif'
    and tq.motif = 'Rechargement validé'
    and q.created_at > now() - interval '30 days';
$function$;


-- ---------------------------------------------------------------------------
-- 2. Trigger sur qualifications
-- ---------------------------------------------------------------------------
-- security definer : l'agent qui qualifie ne voit pas forcement les
-- qualifications posees par ses collegues sur les autres fiches de la box.
create or replace function public.bloquer_requalification_rechargement_valide()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_validation_fiche timestamptz;
  v_fin_box timestamptz;
begin
  -- Regle d'origine : la fiche validee elle-meme ne recoit plus aucune
  -- qualification pendant 30 jours.
  select q.created_at into v_validation_fiche
  from qualifications q
  join types_qualification tq on tq.id = q.type_qualification_id
  where q.client_id = new.client_id
    and tq.categorie = 'Positif'
    and tq.motif = 'Rechargement validé'
  order by q.created_at desc
  limit 1;

  if v_validation_fiche is not null and v_validation_fiche > now() - interval '30 days' then
    raise exception 'Cette fiche a été validée (rechargement) le % — verrouillée 30 jours, aucune nouvelle qualification n''est autorisée.',
      to_char(v_validation_fiche at time zone 'Africa/Abidjan', 'DD/MM/YYYY');
  end if;

  -- Nouvelle regle : une box deja validee sur une AUTRE fiche ne peut pas
  -- etre validee une seconde fois pendant le verrou. Les autres
  -- qualifications restent possibles (c'est "A deja recharge" qui convient).
  if exists (select 1 from types_qualification tq
             where tq.id = new.type_qualification_id
               and tq.categorie = 'Positif' and tq.motif = 'Rechargement validé') then
    v_fin_box := fin_verrou_rechargement(new.client_id);
    if v_fin_box is not null and v_fin_box > now() then
      raise exception 'Cette box a déjà été validée (rechargement) le % sur une autre fiche : choisissez « A déjà rechargé ».',
        to_char((v_fin_box - interval '30 days') at time zone 'Africa/Abidjan', 'DD/MM/YYYY');
    end if;
  end if;

  return new;
end;
$function$;

revoke execute on function public.bloquer_requalification_rechargement_valide() from public, anon, authenticated;

drop trigger if exists trg_bloquer_requalification_rechargement_valide on qualifications;
create trigger trg_bloquer_requalification_rechargement_valide
  before insert on qualifications
  for each row execute function public.bloquer_requalification_rechargement_valide();


-- ---------------------------------------------------------------------------
-- 3. Date de validation des fiches, pour la recherche agent
-- ---------------------------------------------------------------------------
create or replace function public.verrous_rechargement(p_client_ids uuid[])
returns table(client_id uuid, validee_le timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select x.id, f.fin - interval '30 days'
  from unnest(p_client_ids) as x(id)
  cross join lateral (select fin_verrou_rechargement(x.id) as fin) f
  where f.fin > now();
$function$;

revoke execute on function public.verrous_rechargement(uuid[]) from public, anon;
grant execute on function public.verrous_rechargement(uuid[]) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. Fiches d'une box verrouillee encore en circulation : retirees
-- ---------------------------------------------------------------------------
create temp table bilan_verrou_box on commit drop as
with fins as (
  select c.numero_box, max(q.created_at) + interval '30 days' as fin
  from qualifications q
  join types_qualification tq on tq.id = q.type_qualification_id
  join clients c on c.id = q.client_id
  where tq.categorie = 'Positif' and tq.motif = 'Rechargement validé'
    and q.created_at > now() - interval '30 days'
    and nullif(trim(c.numero_box), '') is not null
  group by c.numero_box
)
select c.id, c.statut as statut_avant, f.fin
from clients c
join fins f on f.numero_box = c.numero_box
where c.statut in ('disponible', 'en_cours')
   or (c.statut = 'planifie' and (c.visible_apres is null or c.visible_apres < f.fin));

update clients c
   set statut = 'planifie', visible_apres = b.fin, agent_id = null
  from bilan_verrou_box b
 where c.id = b.id;


-- ---------------------------------------------------------------------------
-- Verification : l'editeur n'affiche que le resultat de la derniere requete.
-- Attendu : trigger_en_place = 1, verrous_rechargement = 1.
-- ---------------------------------------------------------------------------
notify pgrst, 'reload schema';

select
  (select count(*) from bilan_verrou_box) as fiches_retirees,
  (select count(*) from bilan_verrou_box where statut_avant = 'en_cours') as dont_en_cours,
  (select count(*) from bilan_verrou_box where statut_avant = 'disponible') as dont_disponibles,
  (select count(*) from pg_trigger where tgname = 'trg_bloquer_requalification_rechargement_valide') as trigger_en_place,
  (select count(*) from pg_proc where proname = 'verrous_rechargement') as verrous_rechargement;

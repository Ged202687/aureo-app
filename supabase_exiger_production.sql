-- A executer une seule fois dans l'editeur SQL de Supabase (Dashboard > SQL Editor).
--
-- Seul get_next_fiche verifiait que l'agent est en Production. Trois autres
-- chemins passent une fiche en_cours sans aucun controle :
--   - ouvrir une fiche depuis la recherche agent (PATCH direct sur clients) ;
--   - creer un client en appel entrant (INSERT direct avec statut en_cours) ;
--   - tout futur chemin qui ferait de meme.
--
-- Un garde-fou cote interface ne suffit pas : ces ecritures partent du
-- navigateur et la RLS les autorise. La regle est donc posee en base, par un
-- trigger, ce qui la rend non contournable quel que soit le chemin.
--
-- Portee volontairement etroite : on ne bloque que la PRISE d'une fiche par un
-- agent pour lui-meme. Ne sont donc pas concernes :
--   - un admin qui reaffecte, libere ou recycle une fiche (il n'est pas
--     l'agent assigne) ;
--   - la qualification d'une fiche deja en main : l'agent qui passe en pause
--     apres son appel doit pouvoir la cloturer, sinon elle resterait coincee
--     en_cours et alimenterait les fiches bloquees ;
--   - toute autre modification d'une fiche deja en_cours.

create or replace function public.exiger_production_pour_prise_fiche()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_statut text;
begin
  -- On ne regarde que la transition vers en_cours au profit de l'appelant :
  -- une fiche deja en_cours chez le meme agent n'est pas recontrolee.
  if new.statut = 'en_cours'
     and new.agent_id is not null
     and new.agent_id = auth.uid()
     and ( tg_op = 'INSERT'
        or old.statut is distinct from 'en_cours'
        or old.agent_id is distinct from new.agent_id )
  then
    select statut into v_statut from profils where id = auth.uid();

    if v_statut is distinct from 'en_prod' then
      raise exception 'Passe en statut Production pour prendre une fiche.';
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_exiger_production_prise_fiche on clients;

create trigger trg_exiger_production_prise_fiche before insert or update on clients for each row execute function public.exiger_production_pour_prise_fiche();

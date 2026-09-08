-- À exécuter une seule fois dans l'éditeur SQL de Supabase (Dashboard > SQL Editor).
-- Ajoute un champ texte libre par campagne : le script d'aide à la prise en charge,
-- affiché à l'agent quand une fiche de cette campagne lui est présentée.

alter table public.campagnes
  add column if not exists script_prise_en_charge text;

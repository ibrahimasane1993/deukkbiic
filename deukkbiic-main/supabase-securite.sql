-- =====================================================================
-- DEUK BI — Sécurisation Supabase (connexion anonyme + RLS)
-- À coller dans Supabase > SQL Editor > New query, puis "Run".
--
-- AVANT de lancer ce script :
--   Supabase > Authentication > Sign In / Providers
--   > activer "Allow anonymous sign-ins".
--
-- APRÈS ce script :
--   1. Mettre en ligne les nouveaux fichiers sur Netlify.
--   2. Ouvrir l'appli, aller sur la page Admin : ton identifiant s'affiche.
--      Puis lancer (en remplaçant l'identifiant) :
--        insert into public.admins (user_id) values ('TON-IDENTIFIANT');
--
-- Le script peut être relancé sans danger.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Lier chaque joueur à un compte Supabase Auth
-- ---------------------------------------------------------------------
alter table public.players
  add column if not exists user_id uuid references auth.users(id) on delete set null;

create unique index if not exists players_user_id_key on public.players (user_id);

-- Pseudo unique (sans tenir compte des majuscules) — seulement s'il n'y a
-- pas déjà de doublons. Sinon un message s'affiche : fusionne ou renomme
-- les doublons, puis relance le script.
do $$
begin
  if exists (
    select 1 from public.players group by lower(name) having count(*) > 1
  ) then
    raise notice 'Doublons de pseudo trouvés : index unique NON créé. Liste : select lower(name), count(*) from players group by 1 having count(*) > 1;';
  else
    execute 'create unique index if not exists players_name_lower_key on public.players (lower(name))';
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 2. Administrateurs (remplace le code admin écrit dans la page)
-- ---------------------------------------------------------------------
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.admins enable row level security;
-- Aucune règle : la table est invisible depuis l'appli.

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public.my_player_name()
returns text
language sql stable security definer set search_path = public
as $$
  select name from public.players where user_id = auth.uid() limit 1;
$$;


-- ---------------------------------------------------------------------
-- 3. Garde-fous sur les écritures des joueurs
--    (un joueur ne peut ni se débannir, ni changer de propriétaire,
--     ni s'ajouter des centaines de km d'un coup)
-- ---------------------------------------------------------------------
create or replace function public.players_guard()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  -- Tableau de bord Supabase / clé service, ou admin : pas de restriction
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.user_id := auth.uid();
    new.banned  := false;
    new.km      := 0;
    new.level   := 1;
    new.pin     := null;
    return new;
  end if;

  -- UPDATE
  if old.banned then
    raise exception 'banni';
  end if;

  -- Propriétaire : ne change que lors de la récupération d'un ancien profil
  if old.user_id is distinct from new.user_id
     and not (old.user_id is null and new.user_id = auth.uid()) then
    raise exception 'interdit';
  end if;

  new.banned := old.banned;
  new.name   := old.name;
  new.pin    := old.pin;
  -- km : jamais en baisse, +150 km max par mise à jour
  new.km := greatest(coalesce(old.km, 0),
                     least(coalesce(new.km, 0), coalesce(old.km, 0) + 150));
  return new;
end;
$$;

drop trigger if exists players_guard on public.players;
create trigger players_guard
  before insert or update on public.players
  for each row execute function public.players_guard();


-- ---------------------------------------------------------------------
-- 4. Règles d'accès (RLS) sur players
-- ---------------------------------------------------------------------
alter table public.players enable row level security;

drop policy if exists "players lecture publique" on public.players;
drop policy if exists "players creer son profil" on public.players;
drop policy if exists "players modifier son profil" on public.players;
drop policy if exists "players supprimer son profil" on public.players;

create policy "players lecture publique" on public.players
  for select using (true);

create policy "players creer son profil" on public.players
  for insert to authenticated
  with check (user_id = auth.uid());

create policy "players modifier son profil" on public.players
  for update to authenticated
  using (user_id = auth.uid() or public.is_admin())
  with check (user_id = auth.uid() or public.is_admin());

create policy "players supprimer son profil" on public.players
  for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- Le PIN n'est plus lisible depuis l'appli (lecture colonne par colonne)
revoke select on public.players from anon, authenticated;
grant select (id, user_id, name, region, avatar, color, km, level, badges,
              streak, photo, banned, created_at, last_active)
  on public.players to anon, authenticated;
grant insert, update, delete on public.players to authenticated;


-- ---------------------------------------------------------------------
-- 5. Récupérer un ancien profil (période de transition)
--    Appelé automatiquement par l'appli pour les joueurs déjà connectés
--    sur leur téléphone, ou quand on tape son pseudo.
--    Après la date limite, plus aucune récupération : les cas restants
--    se règlent à la main depuis le tableau de bord.
-- ---------------------------------------------------------------------
create or replace function public.claim_player(p_name text, p_pin text default null)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  p   public.players%rowtype;
begin
  if uid is null then
    raise exception 'non_connecte';
  end if;

  -- Ce téléphone a déjà un profil : on le renvoie
  select * into p from public.players where user_id = uid limit 1;
  if found then
    if p.banned then raise exception 'banni'; end if;
    return json_build_object('id', p.id, 'name', p.name, 'region', p.region,
      'avatar', p.avatar, 'color', p.color, 'km', p.km, 'level', p.level,
      'badges', p.badges, 'streak', p.streak, 'photo', p.photo,
      'created_at', p.created_at);
  end if;

  select * into p from public.players
   where lower(name) = lower(trim(p_name))
   order by (user_id is null) desc, km desc
   limit 1;

  if not found then
    return null;  -- pseudo libre : l'appli crée le profil
  end if;

  if p.user_id is not null then
    raise exception 'pseudo_pris';
  end if;
  if p.banned then
    raise exception 'banni';
  end if;
  if now() > timestamptz '2026-12-31 23:59:59+00' then
    raise exception 'migration_terminee';
  end if;
  if p.pin is not null and p.pin <> '' and (p_pin is null or p_pin <> p.pin) then
    raise exception 'pin_requis';
  end if;

  update public.players set user_id = uid where id = p.id;

  return json_build_object('id', p.id, 'name', p.name, 'region', p.region,
    'avatar', p.avatar, 'color', p.color, 'km', p.km, 'level', p.level,
    'badges', p.badges, 'streak', p.streak, 'photo', p.photo,
    'created_at', p.created_at);
end;
$$;

revoke all on function public.claim_player(text, text) from public, anon;
grant execute on function public.claim_player(text, text) to authenticated;


-- ---------------------------------------------------------------------
-- 6. Supprimer son compte depuis l'appli (exigence Google Play)
-- ---------------------------------------------------------------------
create or replace function public.delete_my_account()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'non_connecte';
  end if;
  delete from public.players where user_id = uid;
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
grant execute on function public.is_admin() to authenticated;


-- ---------------------------------------------------------------------
-- 7. Défis : seuls les joueurs connectés, chacun en son nom
-- ---------------------------------------------------------------------
alter table public.defis enable row level security;

drop policy if exists "defis lecture" on public.defis;
drop policy if exists "defis creer" on public.defis;
drop policy if exists "defis rejoindre" on public.defis;

create policy "defis lecture" on public.defis
  for select to authenticated using (true);

create policy "defis creer" on public.defis
  for insert to authenticated
  with check (challenger = public.my_player_name());

create policy "defis rejoindre" on public.defis
  for update to authenticated
  using (status = 'actif'
         or challenger = public.my_player_name()
         or target = public.my_player_name())
  with check (challenger = public.my_player_name()
              or target = public.my_player_name());

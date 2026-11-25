-- =====================================================================
-- 클래스 빌리지 · Supabase schema
-- All tables are closed to the public API (RLS on, no policies).
-- The web app only calls the functions at the bottom (api_*), which
-- check a session token and enforce prices, coins and ownership.
-- =====================================================================
create extension if not exists pgcrypto with schema extensions;

-- ---------- tables ----------
create table if not exists public.classes(
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text not null unique,
  pw_hash text not null,
  notice text not null default '',
  settings jsonb not null default '{"start":"08:30","end":"16:00","limit":30,"free":true,"fast":false,"locked":false,"live":true}',
  phrases jsonb not null default '["안녕!","좋은 아침!","고마워!","같이 가자!","멋지다!","최고야!","미안해!","또 보자!"]',
  fails int not null default 0,
  lock_until timestamptz,
  created_at timestamptz not null default now());

create table if not exists public.students(
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  no int not null,
  name text not null,
  pin text not null,
  created boolean not null default false,
  nick text not null default '',
  nick_ok boolean not null default false,
  coins int not null default 0 check (coins >= 0),
  av jsonb not null default '{"skin":0,"hs":0,"hc":0}',
  wear jsonb not null default '{"hat":null,"top":"top_red"}',
  inv jsonb not null default '{}',
  house jsonb not null default '{"size":1,"wall":"wall_cream","floor":"floor_wood","placed":[]}',
  farm jsonb not null default '[{"crop":null,"stage":0,"water":false,"at":0},{"crop":null,"stage":0,"water":false,"at":0},{"crop":null,"stage":0,"water":false,"at":0},{"crop":null,"stage":0,"water":false,"at":0},{"crop":null,"stage":0,"water":false,"at":0},{"crop":null,"stage":0,"water":false,"at":0}]',
  pet jsonb,
  dex jsonb not null default '{}',
  col jsonb not null default '{"d":"","got":[]}',
  usage jsonb not null default '{"d":"","ms":0}',
  notes jsonb not null default '[]',
  last_seen date,
  fails int not null default 0,
  lock_until timestamptz,
  unique(class_id, no));

alter table public.students add column if not exists fish jsonb not null default '{"d":"","n":0,"t":0}';

create table if not exists public.sessions(
  token uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade,
  role text not null check (role in ('teacher','student')),
  expires_at timestamptz not null);

create table if not exists public.praise(
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  name text not null, coins int not null check (coins > 0),
  created_at timestamptz not null default clock_timestamp());

create table if not exists public.missions(
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  title text not null, descr text not null default '', due date,
  reward int not null default 0 check (reward >= 0),
  mode text not null default 'check' check (mode in ('check','text')),
  rep text not null default 'none' check (rep in ('none','daily')),
  created_at timestamptz not null default clock_timestamp());

create table if not exists public.subs(
  id uuid primary key default gen_random_uuid(),
  mission_id uuid not null references public.missions(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  text text not null default '', photos jsonb not null default '[]',
  status text not null default 'pending' check (status in ('pending','ok','retry')),
  fb text not null default '', day date not null,
  at timestamptz not null default now());

create table if not exists public.posts(
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  title text not null, tag text not null default '계기교육', body text not null, link text not null default '',
  d_from date, d_to date, reward int not null default 0 check (reward >= 0),
  created_at timestamptz not null default clock_timestamp());

create table if not exists public.refl(
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  text text not null, feat boolean not null default false,
  at timestamptz not null default now(),
  unique(post_id, student_id));

create table if not exists public.coupons(
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  name text not null, price int not null check (price > 0), stock int not null check (stock >= 0),
  lim int not null default 1 check (lim > 0), sold int not null default 0,
  created_at timestamptz not null default clock_timestamp());

create table if not exists public.scoupons(
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  coupon_id uuid references public.coupons(id) on delete set null,
  name text not null, status text not null default 'wait' check (status in ('wait','used')),
  at timestamptz not null default now());

create table if not exists public.ledger(
  id bigserial primary key,
  student_id uuid not null references public.students(id) on delete cascade,
  n int not null, why text not null, at timestamptz not null default clock_timestamp());

create table if not exists public.items(
  id text primary key, name text not null, cat text not null,
  price int not null default 0, sell int not null default 0, crop text, w int not null default 0);

create index if not exists students_class on public.students(class_id);
create index if not exists subs_mission on public.subs(mission_id);
create index if not exists subs_student on public.subs(student_id);
create index if not exists ledger_student on public.ledger(student_id, at);
create index if not exists sessions_exp on public.sessions(expires_at);

-- lock every table: no direct API access, only through the functions below
do $$ declare t text; begin
  foreach t in array array['classes','students','sessions','praise','missions','subs','posts','refl','coupons','scoupons','ledger','items'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public', t);
    if exists (select 1 from pg_roles where rolname='anon') then execute format('revoke all on public.%I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname='authenticated') then execute format('revoke all on public.%I from authenticated', t); end if;
  end loop; end $$;

-- ---------- item catalog (prices live on the server) ----------
insert into public.items(id,name,cat,price,sell,crop,w) values
 ('bed','포근한 침대','furn',120,0,null,0),('table','나무 탁자','furn',80,0,null,0),('chair','나무 의자','furn',40,0,null,0),
 ('lamp','스탠드 조명','furn',50,0,null,0),('plant','초록 화분','furn',30,0,null,0),('shelf','책장','furn',100,0,null,0),
 ('sofa','빨간 소파','furn',150,0,null,0),('rug','보라 러그','furn',60,0,null,0),('clock','괘종시계','furn',70,0,null,0),('fishbowl','금붕어 어항','furn',90,0,null,0),
 ('wall_cream','크림 벽지','wall',0,0,null,0),('wall_mint','민트 벽지','wall',60,0,null,0),('wall_pink','딸기 벽지','wall',60,0,null,0),('wall_wood','통나무 벽','wall',80,0,null,0),
 ('floor_wood','나무 바닥','floor',0,0,null,0),('floor_tile','체크 타일','floor',60,0,null,0),('floor_grass','잔디 카펫','floor',80,0,null,0),('floor_star','밤하늘 바닥','floor',120,0,null,0),
 ('hat_cap','야구 모자','hat',50,0,null,0),('hat_ribbon','분홍 리본','hat',50,0,null,0),('hat_beanie','초록 털모자','hat',60,0,null,0),('hat_flower','하얀 꽃핀','hat',40,0,null,0),('hat_crown','반짝 왕관','hat',300,0,null,0),
 ('top_red','빨간 티셔츠','top',40,0,null,0),('top_blue','파란 티셔츠','top',40,0,null,0),('top_yellow','노란 티셔츠','top',40,0,null,0),
 ('top_green','초록 티셔츠','top',40,0,null,0),('top_purple','보라 티셔츠','top',40,0,null,0),('top_white','하얀 티셔츠','top',40,0,null,0),
 ('seed_tomato','토마토 씨앗','seed',10,0,'tomato',0),('seed_carrot','당근 씨앗','seed',10,0,'carrot',0),('seed_straw','딸기 씨앗','seed',15,0,'straw',0),
 ('crop_tomato','토마토','crop',0,25,null,0),('crop_carrot','당근','crop',0,22,null,0),('crop_straw','딸기','crop',0,35,null,0),
 ('petfood','펫 간식','pfood',5,0,null,0),
 ('col_acorn','도토리','col',0,3,null,35),('col_pine','솔방울','col',0,4,null,28),('col_shell','분홍 조개','col',0,8,null,16),
 ('col_feather','파랑 깃털','col',0,10,null,12),('col_clover','네잎클로버','col',0,30,null,6),('col_star','별조각','col',0,50,null,3),
 ('fish_minnow','송사리','fish',0,4,null,34),('fish_carp','붕어','fish',0,7,null,28),('fish_catfish','메기','fish',0,15,null,16),
 ('fish_trout','무지개송어','fish',0,22,null,12),('fish_koi','비단잉어','fish',0,40,null,7),('fish_gold','황금 물고기','fish',0,100,null,3)
on conflict (id) do update set name=excluded.name,cat=excluded.cat,price=excluded.price,sell=excluded.sell,crop=excluded.crop,w=excluded.w;

-- ---------- helpers ----------
create or replace function public.cv_now_ms() returns bigint language sql stable as
$$ select (extract(epoch from clock_timestamp())*1000)::bigint $$;
create or replace function public.cv_today() returns date language sql stable as
$$ select (now() at time zone 'Asia/Seoul')::date $$;
create or replace function public.cv_d(d date) returns text language sql immutable as
$$ select case when d is null then '' else to_char(d,'YYYY-MM-DD') end $$;
create or replace function public.cv_ms(t timestamptz) returns bigint language sql immutable as
$$ select (extract(epoch from t)*1000)::bigint $$;
create or replace function public.cv_cnt(inv jsonb, k text) returns int language sql immutable as
$$ select coalesce((inv->>k)::int,0) $$;
create or replace function public.cv_inv(inv jsonb, k text, n int) returns jsonb language sql immutable as
$$ select case when coalesce((inv->>k)::int,0)+n <= 0 then inv - k else jsonb_set(inv, array[k], to_jsonb(coalesce((inv->>k)::int,0)+n)) end $$;
create or replace function public.cv_err(msg text) returns void language plpgsql as
$$ begin raise exception using message = msg, errcode = 'P0001'; end $$;
create or replace function public.cv_bad_word(t text) returns boolean language sql immutable as
$$ select t ~ '(바보|멍청|꺼져|죽어|병신|시발|씨발|ㅅㅂ|개새)' $$;

-- coins + ledger (+ optional note shown to the student by 토리)
create or replace function public.cv_coins(p_sid uuid, p_n int, p_why text, p_notify boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_cur int; v_n int;
begin
  select coins into v_cur from students where id=p_sid for update;
  v_n := greatest(p_n, -v_cur);
  if v_n = 0 then return; end if;
  update students set coins = coins + v_n,
    notes = case when p_notify and v_n > 0 then notes || to_jsonb(p_why || '! 코인 ' || v_n || '개를 받았어.') else notes end
  where id = p_sid;
  insert into ledger(student_id, n, why) values (p_sid, v_n, left(p_why,80));
end $$;

-- advance crops one stage when watered and enough time has passed
create or replace function public.cv_grow(p_farm jsonb, p_fast boolean) returns jsonb language plpgsql stable as $$
declare res jsonb := '[]'; p jsonb; tt bigint := case when p_fast then 30000 else 43200000 end; nowm bigint := cv_now_ms();
begin
  for p in select value from jsonb_array_elements(p_farm) loop
    if p->>'crop' is not null and (p->>'stage')::int < 2 and (p->>'water')::boolean and nowm - (p->>'at')::bigint >= tt then
      p := jsonb_build_object('crop',p->>'crop','stage',(p->>'stage')::int+1,'water',false,'at',nowm);
    end if;
    res := res || jsonb_build_array(p);
  end loop;
  return res;
end $$;

create or replace function public.cv_session(p_token uuid, p_role text) returns public.sessions
language plpgsql security definer set search_path = public, extensions as $$
declare s sessions;
begin
  select * into s from sessions where token = p_token and role = p_role and expires_at > now();
  if not found then perform cv_err('AUTH'); end if;
  return s;
end $$;

-- ---------- JSON views ----------
create or replace function public.cv_stu(s public.students, p_full boolean, p_teacher boolean, p_fast boolean) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare j jsonb;
begin
  j := jsonb_build_object('no',s.no,'created',s.created,'nick',case when p_full or s.nick_ok then s.nick else '' end,
    'nickOk',s.nick_ok,'av',s.av,'wear',s.wear,'house',s.house,'farm',cv_grow(s.farm,p_fast),'pet',s.pet);
  if p_full then
    j := j || jsonb_build_object('coins',s.coins,'inv',s.inv,'dex',s.dex,'col',s.col,'fish',s.fish,'usage',s.usage,'notes',s.notes,
      'lastSeen',cv_d(s.last_seen),
      'coupons',(select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'cid',q.coupon_id,'name',q.name,'status',q.status,'at',cv_ms(q.at)) order by q.at),'[]') from scoupons q where q.student_id=s.id));
  end if;
  if p_teacher then j := j || jsonb_build_object('name',s.name,'pin',s.pin); end if;
  return j;
end $$;

create or replace function public.cv_mis(m public.missions) returns jsonb language sql stable as
$$ select jsonb_build_object('id',m.id,'title',m.title,'desc',m.descr,'due',cv_d(m.due),'reward',m.reward,'mode',m.mode,'repeat',case when m.rep='daily' then 'daily' else 'none' end) $$;

create or replace function public.cv_view(p_class uuid, p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare c classes; fast boolean; t date := cv_today(); me_no int; teacher boolean := p_student is null;
begin
  select * into c from classes where id=p_class;
  fast := coalesce((c.settings->>'fast')::boolean,false);
  if not teacher then select no into me_no from students where id=p_student; end if;
  return jsonb_build_object(
    'role', case when teacher then 'teacher' else 'student' end,
    'me', me_no, 'today', cv_d(t),
    'cls', jsonb_build_object('id',c.id,'name',c.name,'code',c.code,'notice',c.notice,'set',c.settings,'phrases',c.phrases),
    'students', (select coalesce(jsonb_agg(cv_stu(x, teacher or x.id=p_student, teacher, fast) order by x.no),'[]') from students x where x.class_id=c.id),
    'praise', case when teacher then (select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'coins',p.coins) order by p.created_at),'[]') from praise p where p.class_id=c.id) else '[]'::jsonb end,
    'missions', (select coalesce(jsonb_agg(cv_mis(m) order by m.created_at),'[]') from missions m where m.class_id=c.id),
    'subs', (select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'mid',s.mission_id,'no',st.no,'text',s.text,'nphotos',jsonb_array_length(s.photos),'photos','[]'::jsonb,'status',s.status,'fb',s.fb,'day',cv_d(s.day),'at',cv_ms(s.at)) order by s.at),'[]')
             from subs s join students st on st.id=s.student_id join missions m on m.id=s.mission_id
             where m.class_id=c.id and (teacher or s.student_id=p_student) and (teacher or m.rep<>'daily' or s.day=t)),
    'posts', (select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'title',p.title,'tag',p.tag,'body',p.body,'link',p.link,'from',cv_d(p.d_from),'to',cv_d(p.d_to),'reward',p.reward) order by p.created_at),'[]')
             from posts p where p.class_id=c.id and (teacher or ((p.d_from is null or p.d_from<=t) and (p.d_to is null or p.d_to>=t)))),
    'refl', (select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'pid',r.post_id,'no',st.no,'text',r.text,'feat',r.feat,'at',cv_ms(r.at)) order by r.at),'[]')
             from refl r join students st on st.id=r.student_id join posts p on p.id=r.post_id
             where p.class_id=c.id and (teacher or r.student_id=p_student or r.feat)),
    'coupons', (select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'name',q.name,'price',q.price,'stock',q.stock,'limit',q.lim,'sold',q.sold) order by q.created_at),'[]') from coupons q where q.class_id=c.id),
    'ledger', (select coalesce(jsonb_agg(jsonb_build_object('no',x.no,'n',x.n,'why',x.why,'at',x.ms) order by x.ms),'[]') from (
               select st.no, l.n, l.why, cv_ms(l.at) ms from ledger l join students st on st.id=l.student_id
               where st.class_id=c.id and (teacher or l.student_id=p_student) order by l.at desc limit case when teacher then 3000 else 40 end) x)
  );
end $$;

-- ---------- public entry points ----------
create or replace function public.api_status() returns jsonb
language sql stable security definer set search_path = public, extensions as
$$ select jsonb_build_object('hasClass', exists(select 1 from classes)) $$;

create or replace function public.api_setup(p_name text, p_code text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c uuid; tok uuid; code text := upper(trim(p_code));
begin
  perform pg_advisory_xact_lock(4242);
  if exists(select 1 from classes) then perform cv_err('이미 학급이 만들어져 있어요. 선생님 로그인을 이용해 주세요.'); end if;
  if length(trim(coalesce(p_name,''))) < 2 then perform cv_err('학급 이름을 적어 주세요.'); end if;
  if code !~ '^[A-Z0-9]{4,10}$' then perform cv_err('학급 코드는 영어 대문자와 숫자 4~10자예요.'); end if;
  if length(coalesce(p_pw,'')) < 6 then perform cv_err('비밀번호는 6자 이상이에요.'); end if;
  insert into classes(name,code,pw_hash) values (left(trim(p_name),30), code, crypt(p_pw, gen_salt('bf'))) returning id into c;
  insert into praise(class_id,name,coins) values (c,'발표를 잘했어요',10),(c,'친구를 도왔어요',15),(c,'정리 정돈 최고',5),(c,'바른 자세로 집중',5);
  insert into missions(class_id,title,descr,reward,mode,rep) values (c,'매일 독서 10분','좋아하는 책을 10분 동안 읽고 [했어요]를 눌러요.',10,'check','daily');
  insert into coupons(class_id,name,price,stock,lim) values (c,'자리 바꾸기권',200,3,1),(c,'급식 먼저 먹기권',150,5,2);
  insert into sessions(class_id,role,expires_at) values (c,'teacher',now()+interval '30 days') returning token into tok;
  return jsonb_build_object('token',tok,'view',cv_view(c,null));
end $$;

create or replace function public.api_login_teacher(p_code text, p_pw text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c classes; tok uuid;
begin
  delete from sessions where expires_at < now();
  select * into c from classes where code = upper(trim(p_code)) for update;
  if not found then perform cv_err('학급 코드를 다시 확인해 주세요.'); end if;
  if c.lock_until is not null and c.lock_until > now() then perform cv_err('비밀번호를 여러 번 틀려서 잠시 잠겼어요. 5분 뒤에 다시 해 주세요.'); end if;
  if c.pw_hash <> crypt(coalesce(p_pw,''), c.pw_hash) then
    update classes set fails = case when fails+1>=5 then 0 else fails+1 end,
      lock_until = case when fails+1>=5 then now()+interval '5 minutes' else lock_until end where id=c.id;
    return jsonb_build_object('error','비밀번호가 맞지 않아요.');
  end if;
  update classes set fails=0, lock_until=null where id=c.id;
  insert into sessions(class_id,role,expires_at) values (c.id,'teacher',now()+interval '30 days') returning token into tok;
  return jsonb_build_object('token',tok,'view',cv_view(c.id,null));
end $$;

create or replace function public.api_login_student(p_code text, p_no int, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c classes; s students; tok uuid;
begin
  delete from sessions where expires_at < now();
  select * into c from classes where code = upper(trim(p_code));
  if not found then perform cv_err('학급 코드를 다시 확인해 주세요.'); end if;
  select * into s from students where class_id=c.id and no=p_no for update;
  if not found then perform cv_err('그 번호의 주민이 없어요.'); end if;
  if s.lock_until is not null and s.lock_until > now() then perform cv_err('핀을 여러 번 틀려서 5분 동안 잠겼어요. 선생님께 말씀드려요.'); end if;
  if s.pin <> coalesce(trim(p_pin),'') then
    update students set fails = case when fails+1>=5 then 0 else fails+1 end,
      lock_until = case when fails+1>=5 then now()+interval '5 minutes' else lock_until end where id=s.id;
    return jsonb_build_object('error', case when s.fails+1>=5 then '5번 틀려서 5분 동안 잠겼어요.' else '핀이 맞지 않아요. ('||(s.fails+1)||'/5)' end);
  end if;
  update students set fails=0, lock_until=null, last_seen=cv_today() where id=s.id;
  insert into sessions(class_id,student_id,role,expires_at) values (c.id,s.id,'student',now()+interval '10 hours') returning token into tok;
  return jsonb_build_object('token',tok,'view',cv_view(c.id,s.id));
end $$;

create or replace function public.api_logout(p_token uuid) returns void
language sql security definer set search_path = public, extensions as
$$ delete from sessions where token = p_token $$;

-- ---------- student actions ----------
create or replace function public.api_student(p_token uuid, p_act text, p_args jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  ss sessions; st students; c classes; it items; m missions; po posts; cp coupons;
  fast boolean; tx text := cv_d(cv_today()); nowm bigint := cv_now_ms();
  k text; n int; i int; p jsonb; v_farm jsonb; v_pet jsonb; picked text := null; v jsonb; v_cost int; tw int; r float; x int; y int;
  dims int[]; cnts jsonb := '{}'; seen jsonb := '{}'; v_nick text; txt text; ph jsonb; sub subs;
begin
  ss := cv_session(p_token,'student');
  select * into st from students where id=ss.student_id for update;
  select * into c from classes where id=st.class_id;
  fast := coalesce((c.settings->>'fast')::boolean,false);
  if p_act not in ('view','create','usage','notes_clear') and not st.created then perform cv_err('먼저 캐릭터를 만들어 주세요.'); end if;

  if p_act = 'view' then
    update students set last_seen=cv_today() where id=st.id and (last_seen is null or last_seen<>cv_today());

  elsif p_act = 'usage' then
    n := least(greatest(coalesce((p_args->>'ms')::int,0),0),120000);
    update students set usage = case when usage->>'d' = tx then jsonb_build_object('d',tx,'ms',coalesce((usage->>'ms')::bigint,0)+n) else jsonb_build_object('d',tx,'ms',n) end where id=st.id;
    return jsonb_build_object('ok',true);

  elsif p_act = 'notes_clear' then
    update students set notes='[]' where id=st.id;
    return jsonb_build_object('ok',true);

  elsif p_act in ('create','look') then
    if p_act='create' and st.created then perform cv_err('이미 캐릭터가 있어요.'); end if;
    if p_args ? 'av' then
      if coalesce((p_args#>>'{av,skin}')::int,-1) not between 0 and 2 or coalesce((p_args#>>'{av,hs}')::int,-1) not between 0 and 7 or coalesce((p_args#>>'{av,hc}')::int,-1) not between 0 and 4 or coalesce((p_args#>>'{av,os}')::int,0) not between 0 and 7 then perform cv_err('외모 값이 올바르지 않아요.'); end if;
      update students set av = jsonb_build_object('skin',(p_args#>>'{av,skin}')::int,'hs',(p_args#>>'{av,hs}')::int,'hc',(p_args#>>'{av,hc}')::int,'os',coalesce((p_args#>>'{av,os}')::int,0)) where id=st.id;
    end if;
    if p_args ? 'nick' then
      v_nick := trim(p_args->>'nick');
      if char_length(v_nick) not between 2 and 8 then perform cv_err('별명은 2~8자로 지어 주세요.'); end if;
      if cv_bad_word(v_nick) then perform cv_err('친구가 들으면 속상할 수 있는 말이 들어 있어요.'); end if;
      if v_nick <> st.nick then update students set nick=v_nick, nick_ok=false where id=st.id; end if;
    elsif p_act='create' then perform cv_err('별명을 지어 주세요.');
    end if;
    if p_act='create' then
      k := p_args->>'top';
      if not exists(select 1 from items where id=k and cat='top') then perform cv_err('옷을 골라 주세요.'); end if;
      update students set created=true, wear=jsonb_build_object('hat',null,'top',k),
        inv=jsonb_build_object(k,1,'bed',1,'chair',1,'seed_tomato',2,'petfood',2),
        house='{"size":1,"wall":"wall_cream","floor":"floor_wood","placed":[{"id":"bed","x":0,"y":0}]}' where id=st.id;
      perform cv_coins(st.id,100,'마을 입주 축하금',false);
    end if;
    select * into st from students where id=st.id;
    if p_args ? 'wear' then
      k := p_args#>>'{wear,hat}';
      if k is not null and (not exists(select 1 from items where id=k and cat='hat') or cv_cnt(st.inv,k)<1) then perform cv_err('가지고 있지 않은 모자예요.'); end if;
      if p_args#>>'{wear,top}' is null or not exists(select 1 from items where id=p_args#>>'{wear,top}' and cat='top') or cv_cnt(st.inv,p_args#>>'{wear,top}')<1 then perform cv_err('가지고 있지 않은 옷이에요.'); end if;
      update students set wear=jsonb_build_object('hat',k,'top',p_args#>>'{wear,top}') where id=st.id;
    end if;
    if p_args ? 'house' then
      k := p_args#>>'{house,wall}';
      if not exists(select 1 from items where id=k and cat='wall') or (k<>'wall_cream' and cv_cnt(st.inv,k)<1) then perform cv_err('가지고 있지 않은 벽지예요.'); end if;
      txt := p_args#>>'{house,floor}';
      if not exists(select 1 from items where id=txt and cat='floor') or (txt<>'floor_wood' and cv_cnt(st.inv,txt)<1) then perform cv_err('가지고 있지 않은 바닥이에요.'); end if;
      dims := case (st.house->>'size')::int when 2 then array[8,5] when 3 then array[10,6] else array[6,4] end;
      if jsonb_typeof(p_args#>'{house,placed}') <> 'array' then perform cv_err('가구 배치가 올바르지 않아요.'); end if;
      for p in select value from jsonb_array_elements(p_args#>'{house,placed}') loop
        x := (p->>'x')::int; y := (p->>'y')::int;
        if x is null or y is null or x<0 or y<0 or x>=dims[1] or y>=dims[2] then perform cv_err('방 밖에는 놓을 수 없어요.'); end if;
        if seen ? (x||','||y) then perform cv_err('한 칸에는 가구 하나만 놓아요.'); end if;
        seen := seen || jsonb_build_object(x||','||y, true);
        if not exists(select 1 from items where id=p->>'id' and cat='furn') then perform cv_err('알 수 없는 가구예요.'); end if;
        cnts := cv_inv(cnts, p->>'id', 1);
        if cv_cnt(cnts,p->>'id') > cv_cnt(st.inv,p->>'id') then perform cv_err('가진 개수보다 많이 놓을 수 없어요.'); end if;
      end loop;
      update students set house = jsonb_build_object('size',(st.house->>'size')::int,'wall',k,'floor',txt,
        'placed',(select coalesce(jsonb_agg(jsonb_build_object('id',e->>'id','x',(e->>'x')::int,'y',(e->>'y')::int)),'[]') from jsonb_array_elements(p_args#>'{house,placed}') e)) where id=st.id;
    end if;

  elsif p_act = 'buy' then
    select * into it from items where id=p_args->>'id' and price>0 and cat in ('furn','wall','floor','hat','top','seed','pfood');
    if not found then perform cv_err('팔지 않는 물건이에요.'); end if;
    if it.cat in ('wall','floor','hat','top') and cv_cnt(st.inv,it.id)>0 then perform cv_err('이미 가지고 있어요.'); end if;
    if st.coins < it.price then perform cv_err('코인이 부족해요.'); end if;
    perform cv_coins(st.id,-it.price,'구매: '||it.name,false);
    update students set inv=cv_inv(inv,it.id,1) where id=st.id;

  elsif p_act = 'sell' then
    select * into it from items where id=p_args->>'id' and cat in ('crop','col','fish');
    if not found then perform cv_err('팔 수 없는 물건이에요.'); end if;
    n := case when p_args->>'n'='all' then cv_cnt(st.inv,it.id) else 1 end;
    if n<1 or n>cv_cnt(st.inv,it.id) then perform cv_err('가진 개수가 부족해요.'); end if;
    update students set inv=cv_inv(inv,it.id,-n) where id=st.id;
    perform cv_coins(st.id,it.sell*n,'팔기: '||it.name||' '||n||'개',false);

  elsif p_act = 'fish' then
    v := case when st.fish->>'d' = tx then st.fish else jsonb_build_object('d',tx,'n',0,'t',0) end;
    if (v->>'n')::int >= 15 then perform cv_err('오늘은 물고기를 충분히 잡았어요. 내일 또 낚시해요!'); end if;
    if nowm - (v->>'t')::bigint < 4000 then perform cv_err('조금만 쉬었다가 다시 던져 봐요.'); end if;
    select sum(items.w) into tw from items where cat='fish';
    r := random()*tw;
    for it in select * from items where cat='fish' order by w desc loop
      r := r - it.w; picked := it.id;
      exit when r <= 0;
    end loop;
    update students set fish=jsonb_build_object('d',tx,'n',(v->>'n')::int+1,'t',nowm), inv=cv_inv(inv,picked,1), dex=dex||jsonb_build_object(picked,1) where id=st.id;

  elsif p_act = 'collect' then
    k := p_args->>'cid';
    if k is null or k !~ '^c[0-5]$' then perform cv_err('찾을 수 없는 보물이에요.'); end if;
    v := case when st.col->>'d' = tx then st.col else jsonb_build_object('d',tx,'got','[]'::jsonb) end;
    if (v->'got') ? k or jsonb_array_length(v->'got')>=6 then perform cv_err('이미 주운 보물이에요.'); end if;
    select sum(items.w) into tw from items where cat='col';
    r := random()*tw;
    for it in select * from items where cat='col' order by w desc loop
      r := r - it.w; picked := it.id;
      exit when r <= 0;
    end loop;
    update students set col=jsonb_build_object('d',tx,'got',(v->'got')||to_jsonb(k)), inv=cv_inv(inv,picked,1), dex=dex||jsonb_build_object(picked,1) where id=st.id;

  elsif p_act in ('plant','water','harvest') then
    i := (p_args->>'i')::int;
    if i is null or i not between 0 and 5 then perform cv_err('밭을 골라 주세요.'); end if;
    v_farm := cv_grow(st.farm, fast); p := v_farm->i;
    if p_act='plant' then
      if p->>'crop' is not null then perform cv_err('이미 무언가 자라고 있어요.'); end if;
      select * into it from items where id=p_args->>'seed' and cat='seed';
      if not found or cv_cnt(st.inv,it.id)<1 then perform cv_err('씨앗이 없어요.'); end if;
      v_farm := jsonb_set(v_farm, array[i::text], jsonb_build_object('crop',it.crop,'stage',0,'water',false,'at',nowm));
      update students set farm=v_farm, inv=cv_inv(inv,it.id,-1) where id=st.id;
    elsif p_act='water' then
      if p->>'crop' is null or (p->>'stage')::int>=2 then perform cv_err('물을 줄 작물이 없어요.'); end if;
      v_farm := jsonb_set(v_farm, array[i::text], jsonb_build_object('crop',p->>'crop','stage',(p->>'stage')::int,'water',true,'at',nowm));
      update students set farm=v_farm where id=st.id;
    else
      if p->>'crop' is null or (p->>'stage')::int<2 then perform cv_err('아직 다 자라지 않았어요.'); end if;
      k := 'crop_'||(p->>'crop');
      v_farm := jsonb_set(v_farm, array[i::text], '{"crop":null,"stage":0,"water":false,"at":0}'::jsonb);
      update students set farm=v_farm, inv=cv_inv(inv,k,2), dex=dex||jsonb_build_object(k,1) where id=st.id;
    end if;

  elsif p_act = 'adopt' then
    if st.pet is not null then perform cv_err('이미 펫이 있어요.'); end if;
    k := p_args->>'type'; v_nick := trim(coalesce(p_args->>'name',''));
    if k not in ('cat','dog','rabbit') then perform cv_err('펫을 골라 주세요.'); end if;
    if char_length(v_nick) not between 2 and 6 or cv_bad_word(v_nick) then perform cv_err('펫 이름을 2~6자로 지어 주세요.'); end if;
    if st.coins < 150 then perform cv_err('코인이 부족해요.'); end if;
    perform cv_coins(st.id,-150,'펫 입양: '||case k when 'cat' then '고양이' when 'dog' then '강아지' else '토끼' end,false);
    update students set pet=jsonb_build_object('type',k,'name',v_nick,'aff',1,'fed',tx,'pat','','walk',true) where id=st.id;

  elsif p_act in ('feed','pat','petwalk') then
    v_pet := st.pet;
    if v_pet is null then perform cv_err('펫이 없어요.'); end if;
    if p_act='feed' then
      if cv_cnt(st.inv,'petfood')<1 then perform cv_err('펫 간식이 없어요.'); end if;
      if v_pet->>'fed' <> tx then v_pet := jsonb_set(v_pet,'{aff}',to_jsonb(least(10,(v_pet->>'aff')::int+1))); end if;
      v_pet := jsonb_set(v_pet,'{fed}',to_jsonb(tx));
      update students set pet=v_pet, inv=cv_inv(inv,'petfood',-1) where id=st.id;
    elsif p_act='pat' then
      if v_pet->>'pat' = tx then perform cv_err('오늘은 이미 쓰다듬었어요.'); end if;
      v_pet := jsonb_set(jsonb_set(v_pet,'{pat}',to_jsonb(tx)),'{aff}',to_jsonb(least(10,(v_pet->>'aff')::int+1)));
      update students set pet=v_pet where id=st.id;
    else
      update students set pet=jsonb_set(v_pet,'{walk}',to_jsonb(not coalesce((pet->>'walk')::boolean,true))) where id=st.id;
    end if;

  elsif p_act = 'expand' then
    n := (st.house->>'size')::int;
    if n>=3 then perform cv_err('더 넓힐 수 없어요.'); end if;
    v_cost := case n when 1 then 300 else 600 end;
    if st.coins < v_cost then perform cv_err('코인이 부족해요.'); end if;
    perform cv_coins(st.id,-v_cost,'집 넓히기: '||case n when 1 then '중간 방' else '큰 방' end,false);
    update students set house=jsonb_set(house,'{size}',to_jsonb(n+1)) where id=st.id;

  elsif p_act = 'buycp' then
    select * into cp from coupons where id=(p_args->>'cid')::uuid and class_id=c.id for update;
    if not found then perform cv_err('없는 쿠폰이에요.'); end if;
    if cp.sold >= cp.stock then perform cv_err('다 팔렸어요.'); end if;
    if (select count(*) from scoupons where student_id=st.id and coupon_id=cp.id) >= cp.lim then perform cv_err('한 사람당 '||cp.lim||'장까지예요.'); end if;
    if st.coins < cp.price then perform cv_err('코인이 부족해요.'); end if;
    perform cv_coins(st.id,-cp.price,'구매: '||cp.name,false);
    update coupons set sold=sold+1 where id=cp.id;
    insert into scoupons(student_id,coupon_id,name) values (st.id,cp.id,cp.name);

  elsif p_act = 'submit' then
    select * into m from missions where id=(p_args->>'mid')::uuid and class_id=c.id;
    if not found then perform cv_err('없는 미션이에요.'); end if;
    if m.rep<>'daily' and m.due is not null and m.due < cv_today() then perform cv_err('마감된 미션이에요.'); end if;
    txt := left(coalesce(trim(p_args->>'text'),''),600);
    ph := coalesce(p_args->'photos','[]'::jsonb);
    if jsonb_typeof(ph)<>'array' or jsonb_array_length(ph)>3 then perform cv_err('사진은 3장까지예요.'); end if;
    if exists(select 1 from jsonb_array_elements_text(ph) u where u !~ '^data:image/(jpeg|png|webp);base64,' or length(u)>300000) then perform cv_err('사진 파일이 너무 커요.'); end if;
    if m.mode='text' and char_length(txt)<5 and jsonb_array_length(ph)=0 then perform cv_err('다섯 글자 이상 쓰거나 사진을 골라 주세요.'); end if;
    select * into sub from subs where mission_id=m.id and student_id=st.id and (m.rep<>'daily' or day=cv_today()) order by at desc limit 1;
    if found and sub.status<>'retry' then perform cv_err('이미 제출했어요.'); end if;
    if found then update subs set text=txt, photos=ph, status='pending', at=now() where id=sub.id;
    else insert into subs(mission_id,student_id,text,photos,day) values (m.id,st.id,txt,ph,cv_today()); end if;

  elsif p_act = 'reflect' then
    select * into po from posts where id=(p_args->>'pid')::uuid and class_id=c.id;
    if not found then perform cv_err('없는 자료예요.'); end if;
    txt := trim(coalesce(p_args->>'text',''));
    if char_length(txt) < 5 then perform cv_err('다섯 글자 이상 써 주세요.'); end if;
    if exists(select 1 from refl where post_id=po.id and student_id=st.id) then perform cv_err('이미 소감을 보냈어요.'); end if;
    insert into refl(post_id,student_id,text) values (po.id,st.id,left(txt,400));
    if po.reward>0 then perform cv_coins(st.id,po.reward,'소감: '||po.title,false); end if;

  else perform cv_err('알 수 없는 동작이에요.');
  end if;

  v := cv_view(c.id, st.id);
  if picked is not null then v := v || jsonb_build_object('picked',picked); end if;
  return v;
end $$;

-- ---------- teacher actions ----------
create or replace function public.api_teacher(p_token uuid, p_act text, p_args jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ss sessions; c classes; st students; pr praise; m missions; sub subs; n int; k text; amt int; why text; cnt int := 0; s jsonb;
begin
  ss := cv_session(p_token,'teacher');
  select * into c from classes where id=ss.class_id for update;

  if p_act = 'view' then null;

  elsif p_act = 'photos' then
    return jsonb_build_object('photos',(select coalesce(jsonb_object_agg(x.id,x.photos),'{}') from subs x join missions mm on mm.id=x.mission_id where mm.class_id=c.id and x.mission_id=(p_args->>'mid')::uuid));

  elsif p_act = 'praise' then
    select * into pr from praise where id=(p_args->>'pid')::uuid and class_id=c.id;
    if not found then perform cv_err('없는 칭찬 항목이에요.'); end if;
    for st in select * from students where class_id=c.id and no in (select (jsonb_array_elements_text(p_args->'nos'))::int) loop
      perform cv_coins(st.id,pr.coins,'칭찬: '||pr.name,true);
    end loop;

  elsif p_act = 'coins' then
    amt := abs(coalesce((p_args->>'amount')::int,0));
    if amt<1 or amt>10000 then perform cv_err('코인 수를 적어 주세요.'); end if;
    why := left(coalesce(nullif(trim(p_args->>'why'),''), case when (p_args->>'sign')='1' then '선생님 보상' else '선생님 조정' end),60);
    for st in select * from students where class_id=c.id and no in (select (jsonb_array_elements_text(p_args->'nos'))::int) loop
      if (p_args->>'sign')='1' then perform cv_coins(st.id,amt,why,true); else perform cv_coins(st.id,-amt,'차감: '||why,false); end if;
    end loop;

  elsif p_act = 'nick' then
    if (p_args->>'ok')::boolean then
      update students set nick_ok=true, notes=notes||to_jsonb('별명 '''||nick||'''이 승인됐어. 이제 친구들에게 보여!') where class_id=c.id and no=(p_args->>'no')::int;
    else
      update students set nick='주민'||no, nick_ok=true, notes=notes||'"별명을 다시 지어 줄래? 수첩 > 옷장 > 외모·별명 바꾸기에서 바꿀 수 있어."'::jsonb where class_id=c.id and no=(p_args->>'no')::int;
    end if;

  elsif p_act = 'pin' then
    update students set pin=lpad((floor(random()*9000)+1000)::int::text,4,'0'), fails=0, lock_until=null where class_id=c.id and no=(p_args->>'no')::int;
    delete from sessions where student_id in (select id from students where class_id=c.id and no=(p_args->>'no')::int);

  elsif p_act = 'add_student' then
    n := (p_args->>'no')::int; k := left(trim(coalesce(p_args->>'name','')),20);
    if n is null or n not between 1 and 99 or k = '' then perform cv_err('번호와 이름을 적어 주세요.'); end if;
    if exists(select 1 from students where class_id=c.id and no=n) then perform cv_err('이미 있는 번호예요.'); end if;
    if (select count(*) from students where class_id=c.id) >= 40 then perform cv_err('한 학급은 40명까지예요.'); end if;
    insert into students(class_id,no,name,pin) values (c.id,n,k,(floor(random()*9000)+1000)::int::text);

  elsif p_act = 'del_student' then
    delete from students where class_id=c.id and no=(p_args->>'no')::int;

  elsif p_act = 'add_praise' then
    if trim(coalesce(p_args->>'name',''))='' or coalesce((p_args->>'coins')::int,0)<1 then perform cv_err('이름과 코인을 적어 주세요.'); end if;
    insert into praise(class_id,name,coins) values (c.id,left(trim(p_args->>'name'),30),least((p_args->>'coins')::int,10000));
  elsif p_act = 'del_praise' then
    delete from praise where class_id=c.id and id=(p_args->>'id')::uuid;

  elsif p_act = 'add_mission' then
    if trim(coalesce(p_args->>'title',''))='' then perform cv_err('미션 제목을 적어 주세요.'); end if;
    insert into missions(class_id,title,descr,due,reward,mode,rep) values (c.id,left(trim(p_args->>'title'),40),left(coalesce(p_args->>'desc',''),300),
      case when p_args->>'repeat'='daily' or coalesce(p_args->>'due','')='' then null else (p_args->>'due')::date end,
      greatest(0,least(coalesce((p_args->>'reward')::int,0),10000)), case when p_args->>'mode'='text' then 'text' else 'check' end, case when p_args->>'repeat'='daily' then 'daily' else 'none' end);
  elsif p_act = 'del_mission' then
    delete from missions where class_id=c.id and id=(p_args->>'id')::uuid;

  elsif p_act in ('review','review_all') then
    for sub in select x.* from subs x join missions mm on mm.id=x.mission_id where mm.class_id=c.id and x.status='pending'
        and ((p_act='review' and x.id=(p_args->>'sid')::uuid) or (p_act='review_all' and x.mission_id=(p_args->>'mid')::uuid and (mm.rep<>'daily' or x.day=cv_today()))) loop
      select * into m from missions where id=sub.mission_id;
      if p_act='review_all' or (p_args->>'ok')::boolean then
        update subs set status='ok', fb=left(coalesce(p_args->>'fb',''),100) where id=sub.id;
        perform cv_coins(sub.student_id,m.reward,'미션 완료: '||m.title,true);
        if coalesce(trim(p_args->>'fb'),'')<>'' then update students set notes=notes||to_jsonb('선생님 한마디: '||left(trim(p_args->>'fb'),100)) where id=sub.student_id; end if;
      else
        update subs set status='retry', fb=left(coalesce(nullif(trim(p_args->>'fb'),''),'조금만 더 해 볼까요?'),100) where id=sub.id;
        update students set notes=notes||to_jsonb(''''||m.title||''' 미션을 한 번 더 해 볼까? 미션 게시판에서 선생님 말씀을 확인해 봐.') where id=sub.student_id;
      end if;
      cnt := cnt+1;
    end loop;

  elsif p_act = 'add_post' then
    if trim(coalesce(p_args->>'title',''))='' or trim(coalesce(p_args->>'body',''))='' then perform cv_err('제목과 내용을 적어 주세요.'); end if;
    if coalesce(p_args->>'link','')<>'' and p_args->>'link' !~ '^https?://' then perform cv_err('링크는 http로 시작해야 해요.'); end if;
    insert into posts(class_id,title,tag,body,link,d_from,d_to,reward) values (c.id,left(trim(p_args->>'title'),40),left(coalesce(nullif(trim(p_args->>'tag'),''),'계기교육'),20),
      left(p_args->>'body',3000),coalesce(p_args->>'link',''),nullif(p_args->>'from','')::date,nullif(p_args->>'to','')::date,greatest(0,least(coalesce((p_args->>'reward')::int,0),10000)));
  elsif p_act = 'del_post' then
    delete from posts where class_id=c.id and id=(p_args->>'id')::uuid;
  elsif p_act = 'feat' then
    update refl set feat = not feat where id=(p_args->>'id')::uuid and post_id in (select id from posts where class_id=c.id);

  elsif p_act = 'add_coupon' then
    if trim(coalesce(p_args->>'name',''))='' then perform cv_err('쿠폰 이름을 적어 주세요.'); end if;
    insert into coupons(class_id,name,price,stock,lim) values (c.id,left(trim(p_args->>'name'),20),greatest(1,coalesce((p_args->>'price')::int,1)),greatest(1,coalesce((p_args->>'stock')::int,1)),greatest(1,coalesce((p_args->>'limit')::int,1)));
  elsif p_act = 'del_coupon' then
    delete from coupons where class_id=c.id and id=(p_args->>'id')::uuid;
  elsif p_act = 'stock' then
    update coupons set stock=stock+5 where class_id=c.id and id=(p_args->>'id')::uuid;
  elsif p_act = 'use_coupon' then
    update scoupons set status='used' where id=(p_args->>'id')::uuid and student_id in (select id from students where class_id=c.id);

  elsif p_act = 'lock' then
    update classes set settings=jsonb_set(settings,'{locked}',to_jsonb(coalesce((p_args->>'locked')::boolean,false))) where id=c.id;

  elsif p_act = 'settings' then
    k := upper(trim(coalesce(p_args->>'code','')));
    if k !~ '^[A-Z0-9]{4,10}$' then perform cv_err('학급 코드는 영어 대문자와 숫자 4~10자예요.'); end if;
    if exists(select 1 from classes where code=k and id<>c.id) then perform cv_err('이미 쓰는 학급 코드예요.'); end if;
    if coalesce(p_args->>'pw','')<>'' then
      if length(p_args->>'pw')<6 then perform cv_err('비밀번호는 6자 이상이에요.'); end if;
      update classes set pw_hash=crypt(p_args->>'pw',gen_salt('bf')) where id=c.id;
    end if;
    s := c.settings || jsonb_build_object(
      'start',coalesce(p_args#>>'{set,start}',c.settings->>'start'),'end',coalesce(p_args#>>'{set,end}',c.settings->>'end'),
      'limit',least(240,greatest(5,coalesce((p_args#>>'{set,limit}')::int,30))),
      'free',coalesce((p_args#>>'{set,free}')::boolean,false),'fast',coalesce((p_args#>>'{set,fast}')::boolean,false),
      'live',coalesce((p_args#>>'{set,live}')::boolean,true),
      'tname',left(coalesce(nullif(trim(p_args#>>'{set,tname}'),''),c.settings->>'tname','선생님'),10),
      'tav',jsonb_build_object('skin',least(2,greatest(0,coalesce((p_args#>>'{set,tav,skin}')::int,0))),'hs',least(7,greatest(0,coalesce((p_args#>>'{set,tav,hs}')::int,0))),'os',least(7,greatest(0,coalesce((p_args#>>'{set,tav,os}')::int,0))),
        'hc',least(4,greatest(0,coalesce((p_args#>>'{set,tav,hc}')::int,0))),
        'top',case when p_args#>>'{set,tav,top}' in ('top_red','top_blue','top_yellow','top_green','top_purple','top_white') then p_args#>>'{set,tav,top}' else 'top_green' end,
        'gl',coalesce((p_args#>>'{set,tav,gl}')::boolean,true)));
    update classes set name=left(coalesce(nullif(trim(p_args->>'name'),''),name),30), code=k, notice=left(coalesce(p_args->>'notice',''),500), settings=s,
      phrases=case when jsonb_typeof(p_args->'phrases')='array' and jsonb_array_length(p_args->'phrases')>0 then
        (select jsonb_agg(left(x,20)) from (select x from jsonb_array_elements_text(p_args->'phrases') x limit 16) q) else phrases end
    where id=c.id;

  elsif p_act = 'year_reset' then
    if coalesce(p_args->>'confirm','') <> '새 학년도' then perform cv_err('''새 학년도''라고 정확히 적어 주세요.'); end if;
    delete from students where class_id=c.id;
    update coupons set sold=0 where class_id=c.id;

  else perform cv_err('알 수 없는 동작이에요.');
  end if;

  return cv_view(c.id, null) || jsonb_build_object('count',cnt);
end $$;

-- ---------- permissions: only the api_* functions are callable from the web ----------
do $$ declare f record; begin
  for f in select p.oid::regprocedure sig, p.proname from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
           where ns.nspname='public' and (p.proname like 'cv\_%' or p.proname like 'api\_%') loop
    execute format('revoke all on function %s from public', f.sig);
    if exists (select 1 from pg_roles where rolname='anon') then execute format('revoke all on function %s from anon, authenticated', f.sig); end if;
    if f.proname like 'api\_%' and exists (select 1 from pg_roles where rolname='anon') then
      execute format('grant execute on function %s to anon, authenticated', f.sig);
    end if;
  end loop; end $$;

# 9.1 — the ledger: schema design

Designed 2026-09-15 in conversation (not closed-book: this is design,
not recall). The user's brief answered four questions; this document
records the decisions, the pushes that turned "in spirit" into choices,
the review against industry practice (five gaps, all folded in), and
the v1 DDL that becomes Hasura migration 1.

The domain, in one sentence: a personal-finance transaction register —
one row per money movement, the model Mint/YNAB/Actual converged on
because it mirrors a bank statement.


================================================================
DECISIONS
================================================================

D1  Single-entry with paired transfers. Double-entry (books /
    journal_entries / book_entries, Square-style) was considered and
    rejected as overkill for a personal ledger. A transfer is TWO
    transactions rows sharing a transfer_id: -500 in checking, +500 in
    savings, category NULL on both. Register per account stays honest;
    category aggregates exclude transfers for free; "the pair sums to
    zero" is a trigger.

D2  Mutable rows in v1. Append-only "in spirit" had to become a
    choice: rows can be UPDATEd/DELETEd, with created_at/updated_at.
    Typo-fixing by reversal entry is a daily UX tax; Hasura makes an
    edit a one-line mutation. Ledger discipline can arrive later as a
    `cleared` flag that freezes rows. Deliberate, not drift.

D3  Money = integer cents, `integer` not `bigint`. Never float.
    Hasura serializes Postgres bigint as a STRING in GraphQL (JSON has
    no safe 64-bit int) — a gotcha to hit on purpose in 9.2. `integer`
    cents is ±$21M per amount and stays a real GraphQL Int. One
    currency per account (char(3) on accounts).

D4  Multi-user from day one. Every domain table carries user_id;
    every Hasura permission for role `user` filters
    {"user_id": {"_eq": "X-Hasura-User-Id"}}. No auth provider yet:
    9.1 designs permissions, 9.2 TESTS them with the admin secret +
    X-Hasura-Role / X-Hasura-User-Id headers (Hasura evaluates them
    exactly as it would a JWT), a real JWT issuer is a 9.3 add-on.

D5  Categories nest exactly two levels (category -> subcategory) via
    parent_id, capped by a trigger. Without the cap "subcategory"
    quietly becomes a tree and every aggregate grows a recursive CTE.
    Two levels is what every mainstream tool actually offers.

D6  Budgets are rows: budgets(category_id, month, amount_cents),
    YNAB-style monthly envelopes. Budget-vs-actual is then a join of
    budgets against SUM(transactions) grouped by category and month.

D7  Write hotspot = transactions (the only table that grows daily).
    Read shapes: (a) the register — WHERE account_id ORDER BY date
    DESC LIMIT n, (b) monthly category aggregates, (c) budget vs
    actual. FOR 9.4: (a) stays on the PRIMARY (a just-posted row must
    not vanish behind replication lag); (b) and (c) go to the
    READ REPLICA. Indexes that make this real: (account_id, date DESC)
    and (category_id, date).

D8  IDs are uuid — Hasura-friendly, safe to expose to a client, no
    sequence to fight in a future replica/merge story. gen_random_uuid()
    (v4) on the slow tables, uuidv7() on transactions (see D13).
    Posted date is `date` (a statement date has no time zone);
    created_at/updated_at are timestamptz.

D9  Payee is free text in v1. A payees table (and payee -> default
    category) is the obvious v2 once real data shows the duplicates.

--- from the review against industry practice (2026-09-15) ---

D10 Uncategorized transactions are allowed. The first CHECK forced a
    category on every non-transfer row; every real tracker treats
    "uncategorized" as the natural state of an imported or hasty row,
    and categorizing later is the core workflow. The rule is now one-
    directional: a transfer leg has NO category. Normal rows may be
    NULL until you get to them.

D11 external_id for import idempotency. The most common regret in
    this domain: import a bank CSV twice, get duplicates, have no key.
    external_id text + UNIQUE (account_id, external_id); NULL allowed,
    so hand-entered rows are unaffected. One line now, miserable
    later.

D12 Transfers require both accounts to share a currency (v1). Currency
    lives on the account; a USD->EUR transfer cannot sum to zero in
    minor units and would trip the balance trigger with a confusing
    error. Forbidden explicitly in the trigger. FX transfers with a
    stored rate are a v2 feature, not a silent hole.

D13 Time-ordered UUIDs (v7) for transactions. gen_random_uuid() is v4
    — random — so each insert lands at a random point in the primary
    key B-tree and fragments the hottest index as the table grows.
    Postgres 18 ships uuidv7() natively (verified on pg-lab: 18.4).
    Used for transactions; the slow-changing tables keep
    gen_random_uuid() — either is fine at their size.

D14 Soft delete + history on transactions. Production finance systems
    never lose history. v1: deleted_at timestamptz (soft delete) —
    Hasura's permission filter adds deleted_at IS NULL so the app never
    sees deleted rows, but PITR and reports can. Plus a
    transactions_history table filled by trigger with the row image
    BEFORE every update/delete: a real audit trail for the cost of one
    trigger, and a richer target for the 9.3 restore drill.

Left as-is, knowingly: amount_cents naming (USD-only v1; would be
amount_minor with a currency exponent in a multi-currency v2); Hasura
permissions as the ONLY authorization layer (standard for Hasura shops
— an admin-secret leak is total, so 9.2's secret handling is a security
control); `kind text CHECK` rather than Hasura enum tables (cosmetic:
a typed GraphQL enum can come when a client wants one).


================================================================
THE TABLES (v1)
================================================================

users          who owns the rows. Minimal: id, email, created_at.
               Authentication is NOT here — Hasura's session variable
               X-Hasura-User-Id IS the login; this table exists so
               foreign keys have something to point at and so a future
               JWT issuer has a row to mint claims from.

accounts       checking, savings, credit card, cash. Carries currency.
               `kind` is an enum-ish text with a CHECK.

categories     two-level tree via parent_id (D5). `kind` = expense |
               income, so aggregates can split them without inference.

transactions   the register (D1, D2, D3, D7, D10-D14). amount_cents
               signed: negative = money out. A transfer leg has no
               category (CHECK); a normal row may be uncategorized.
               external_id for imports; deleted_at for soft delete;
               id is uuidv7 (time-ordered).

transactions_history
               the row image BEFORE every UPDATE or DELETE on
               transactions, written by trigger (D14). Append-only;
               never exposed through Hasura to the `user` role.

budgets        monthly envelope per category (D6). UNIQUE on
               (user_id, category_id, month); month stored as the
               first day of the month, enforced by CHECK.


================================================================
DDL — migration 1
================================================================

-- extensions
create extension if not exists pgcrypto;   -- gen_random_uuid

-- updated_at maintenance, one function for all tables
create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

create table users (
  id          uuid primary key default gen_random_uuid(),
  email       text not null unique,
  created_at  timestamptz not null default now()
);

create table accounts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users(id) on delete cascade,
  name        text not null,
  kind        text not null
              check (kind in ('checking','savings','credit','cash','other')),
  currency    char(3) not null default 'USD',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (user_id, name)
);
create trigger accounts_updated_at before update on accounts
  for each row execute function set_updated_at();

create table categories (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users(id) on delete cascade,
  parent_id   uuid references categories(id) on delete restrict,
  name        text not null,
  kind        text not null check (kind in ('expense','income')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (user_id, parent_id, name)
);
create trigger categories_updated_at before update on categories
  for each row execute function set_updated_at();

-- D5: two levels max. A category whose parent already has a parent
-- is rejected.
create or replace function categories_two_levels() returns trigger
language plpgsql as $$
begin
  if new.parent_id is not null and exists (
       select 1 from categories p
       where p.id = new.parent_id and p.parent_id is not null)
  then
    raise exception 'categories nest at most two levels';
  end if;
  return new;
end $$;
create trigger categories_two_levels before insert or update on categories
  for each row execute function categories_two_levels();

create table transactions (
  id            uuid primary key default uuidv7(),   -- D13
  user_id       uuid not null references users(id) on delete cascade,
  account_id    uuid not null references accounts(id) on delete restrict,
  category_id   uuid references categories(id) on delete restrict,
  transfer_id   uuid,                 -- D1: pairs the two legs
  date          date not null,
  amount_cents  integer not null,     -- D3: signed, negative = out
  payee         text,
  notes         text,
  external_id   text,                 -- D11: the bank's id, for imports
  deleted_at    timestamptz,          -- D14: soft delete
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- D10: a transfer leg has no category; anything else may or may not
  check (transfer_id is null or category_id is null),
  -- D11: the same bank row can land in an account only once
  unique (account_id, external_id)
);
create trigger transactions_updated_at before update on transactions
  for each row execute function set_updated_at();

-- D7: the two indexes that make the read shapes real. Partial on live
-- rows: the app never reads deleted ones (D14), so the index needn't
-- carry them.
create index transactions_register
  on transactions (account_id, date desc) where deleted_at is null;
create index transactions_by_category
  on transactions (category_id, date) where deleted_at is null;
-- and the one the permission filter needs on every table
create index transactions_user on transactions (user_id);
create index accounts_user     on accounts (user_id);
create index categories_user   on categories (user_id);

create table budgets (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references users(id) on delete cascade,
  category_id   uuid not null references categories(id) on delete cascade,
  month         date not null check (month = date_trunc('month', month)),
  amount_cents  integer not null check (amount_cents >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (user_id, category_id, month)
);
create trigger budgets_updated_at before update on budgets
  for each row execute function set_updated_at();
create index budgets_user on budgets (user_id);

-- D1 + D12: both legs of a transfer must exist, sum to zero, and sit
-- in accounts of the same currency. Deferred so the two inserts can
-- happen in one transaction in either order.
create or replace function transfers_balance() returns trigger
language plpgsql as $$
declare total bigint; legs int; currencies int;
begin
  if new.transfer_id is null then return new; end if;
  select coalesce(sum(t.amount_cents),0), count(*), count(distinct a.currency)
    into total, legs, currencies
    from transactions t join accounts a on a.id = t.account_id
   where t.transfer_id = new.transfer_id;
  if legs <> 2 or total <> 0 then
    raise exception
      'transfer % must have exactly 2 legs summing to 0 (has %, sum %)',
      new.transfer_id, legs, total;
  end if;
  if currencies <> 1 then
    raise exception
      'transfer % crosses currencies — not supported in v1 (D12)',
      new.transfer_id;
  end if;
  return new;
end $$;
create constraint trigger transfers_balance
  after insert or update on transactions
  deferrable initially deferred
  for each row execute function transfers_balance();

-- D14: history. The row as it was BEFORE the change, plus what
-- happened. Append-only by construction: nothing grants UPDATE/DELETE
-- on it, and Hasura never tracks it for the `user` role.
create table transactions_history (
  id            bigint generated always as identity primary key,
  transaction_id uuid not null,
  user_id       uuid not null,
  op            text not null check (op in ('UPDATE','DELETE')),
  changed_at    timestamptz not null default now(),
  row_before    jsonb not null
);
create index transactions_history_tx on transactions_history (transaction_id);

create or replace function transactions_audit() returns trigger
language plpgsql as $$
begin
  insert into transactions_history (transaction_id, user_id, op, row_before)
  values (old.id, old.user_id, tg_op, to_jsonb(old));
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger transactions_audit
  after update or delete on transactions
  for each row execute function transactions_audit();


================================================================
HASURA — what 9.2 will track and permit
================================================================

Track the five domain tables — NOT transactions_history (D14: it is
an audit trail, read by an admin or a restore drill, never by the
app). Relationships Hasura infers from the FKs:
  accounts.transactions, categories.transactions, categories.parent /
  children, budgets.category, transactions.account / category.

Role `user`, every table, every operation:
  select/update/delete filter:  {"user_id": {"_eq": "X-Hasura-User-Id"}}
  insert check:                 same, with user_id as a COLUMN PRESET
                                from X-Hasura-User-Id (the client never
                                sends user_id; Hasura fills it)
  transactions, additionally:   select filter AND {"deleted_at":
                                {"_is_null": true}} (D14); the `user`
                                role gets UPDATE on deleted_at (soft
                                delete) and NO hard DELETE permission.
                                The audit trigger still records both.

Two views to expose as tracked SQL, both replica-eligible in 9.4:
  monthly_category_totals  (user_id, category_id, month, sum)
  budget_vs_actual         budgets LEFT JOIN monthly_category_totals


================================================================
THE TERMINAL PART OF 9.1 (short — the design was the work)
================================================================

1. A CNPG Cluster `ledger` in namespace `ledger`: instances 1 (-> 3 in
   9.3), storage 10Gi (default class), plugin barman-cloud against the
   existing ObjectStore — which means the ObjectStore (or a copy) in
   the `ledger` namespace, serverName `ledger-20260915`. Bootstrap
   creates database `ledger` owned by role `ledger`.
   `make pg-backup-secret NS=ledger` for the credential.

2. Hasura CLI project at apps/ledger/hasura/: `hasura init`, the DDL
   above as migrations/default/<ts>_init/up.sql (down.sql drops in
   reverse). Metadata (tracked tables, relationships, permissions) is
   also files in git — the app-layer twin of the CNPG restore story.

3. Apply migration 1 against `ledger` via a port-forward to the -rw
   service; verify with \dt, then break each rule on purpose: a
   three-level category, an unbalanced transfer, a cross-currency
   transfer, a duplicate external_id, and an UPDATE that should leave a
   row in transactions_history.

4. Seed: one user (you), three accounts, a dozen categories in two
   levels, a month of transactions including one transfer, budgets
   for the month. Enough for 9.2's first GraphQL query to be
   interesting.

Then 9.2: Hasura on the cluster, the prepared-statements landmine, the
header-tested permissions.

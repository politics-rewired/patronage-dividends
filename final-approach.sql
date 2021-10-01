create table constants (
  name text primary key,
  value integer
);

insert into constants (
  'WORK_DISCOUNT', 1
  'QUARTERS_PER_DISCOUNT', 2
  'QUARTERS_BACK_LIMIT', 16
);

create or replace function get_constant(name text) returns integer as $$
  select value from constants where constants.name = get_constant.name
$$ language sql;

create table members (
  id integer primary key,
  name text
);

create table quarters (
  quarter date primary key
);

create table hours_worked (
  quarter date references quarters (quarter),
  member_id integer references members (id),
  hours_worked integer,
  primary key (member_id, quarter)
);

create table profits (
  quarter date primary key references quarters (quarter)
  amount integer
);

create table credits_as_of_quarter (
  quarter date references quarters (quarter),
  member_id integer references members (id),
  amount integer,
  primary key (quarter, member_id)
);

create table payouts (
  quarter date primary key references quarters (quarter)
  amount integer
);

create table member_payouts (
  quarter date references quarters (quarter),
  member_id integer references members (id),
  amount decimal,
  primary key (member_id, quarter)
);

create or replace function count_quarters_apart(quarter_a_start date, quarter_b_start date) returns integer as $$
  select extract(epoch from quarter_a_start - quarter_b_start) / extract(epoch from interval '3 months')
$$ language sql immutable;

create or replace function get_cumulative_hours_worked_as_of_quarter(quarter date, member_id integer) returns decimal as $$ 
  select 
    sum(
      case 
        when count_quarters_apart(quarters.quarter, hours_worked.quarter) > get_constant('QUARTERS_BACK_LIMIT') then 0
        else hours_worked / (1 + floor( count_quarters_apart(quarters.quarter, hours_worked.quarter) / get_constant('QUARTERS_PER_DISCOUNT') ) * get_constant('WORK_DISCOUNT'))
      end
    )
  from hours_worked
  where member_id = members.id
    and quarters.quarter <= hours_worked.quarter
$$ language sql stable;

create view cumulative_hours_worked as 
  select 
    members.name,
    members.id as member_id,
    quarters.quarter,
    get_cumulative_hours_worked_as_of_quarter(quarters.quarter, members.id) as count_cumulative_hours,
  from quarters
  cross join members;

create or replace function total_cumulative_hours_in_quarter(quarter date) returns decimal as $$
  select sum(count_cumulative_hours)
  from cumulative_hours_worked
  where cumulative_hours_worker.quarter = total_cumulative_hours_in_quarter.quarter
$$ language sql stable;

create view share_of_cumulative_hours_worked_in_quarter as
  select 
    name,
    member_id,
    quarter,
    count_cumulative_hours / total_cumulative_hours_in_quarter(quarter) as quarterly_cumulative_hour_share
  from cumulative_hours_worked;

create view share_of_credits_as_of_quarter as
  select
    quarter,
    member_id,
    amount / ( select sum(amount) from credits_as_of_quarter all_credits where all_credits.quarter = credits_as_of_quarter.quarter ) as share
  from credits_as_of_quarter;

create or replace function process_profit(quarter date, profit decimal, payout decimal default null) returns void as $$ 
begin
  insert into profits (quarter, amount)
  values (quarter, profit);

  insert into credits_as_of_quarter (quarter, member_id, quarterly_cumulative_hour_share)
  select quarter, member_id, quarterly_cumulative_hour_share * profit
  from share_of_cumulative_hours_worked_in_quarter
  where share_of_cumulative_hours_worked_in_quarter.quarter = process_quarter.quarter;
end;
$$ language plpgsql;

create or replace function process_profit(quarter date, profit decimal, payout decimal default null) returns void as $$ 
begin
  insert into payouts (quarter, amount)
  values (quarter, payout);

  insert into member_payouts (quarter, member_id, amount)
  select quarter, member_id, share * payout
  from share_of_credits_as_of_quarter;

  update credits_as_of_quarter credits
  set amount = credits.amount - member_payouts.amount
  where member_payouts.quarter = credits.quarter
    and member_payouts.member_id = credits.member_id;
end;
$$ language plpgsql;

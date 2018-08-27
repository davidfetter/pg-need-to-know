
-- Proof of Concept

-- login as the superuser
-- construct a membership view, grant access to it
create role authenticator;
grant authenticator to tsd_backend_utv_user;
\du

------------
-- functions
------------

create or replace view group_memberships as
select _group, _role from
    (select * from
        (select rolname as _group, oid from pg_authid)a join
        (select roleid, member from pg_auth_members)b on a.oid = b.member)c
    join (select rolname as _role, oid from pg_authid)d on c.roleid = d.oid;
-- give the db owner ownership of this view
alter view group_memberships owner to authenticator;
grant select on pg_authid to authenticator, tsd_backend_utv_user;
grant select on group_memberships to authenticator, tsd_backend_utv_user;
\d

set role tsd_backend_utv_user;

create or replace function roles_have_common_group(_current_role text, _current_row_owner text)
    returns boolean as $$
    declare _res boolean;
    begin
    select (
        select count(_group) from (
            select _group from group_memberships where _role = _current_role
            intersect
            select _group from group_memberships where _role = _current_row_owner)a
        where _group != 'authenticator')
    != 0 into _res;
    return _res;
    end;
$$ language plpgsql;

drop function if exists table_create(json, text, int);
create or replace function table_create(definition json, type text, form_id int default 0)
    returns text as $$
    declare _res text;
    begin
        if type = 'mac' then
            select parse_mac_table_def(definition) into _res;
            return _res;
        elsif type = 'generic' then
            select parse_generic_table_def(definition) into _res;
            return _res;
        else
            raise exception using message = 'Unrecognised table definition type.';
        end if;
    end;
$$ language plpgsql;

drop function if exists parse_mac_table_def(json);
create or replace function parse_mac_table_def(definition json)
    returns text as $$
    declare _table_name text;
    declare _columns json;
    declare _colname text;
    declare _dtype text;
    declare _i json;
    declare _pk boolean;
    declare _nn boolean;
    begin
        _columns := definition->'columns';
        _table_name := definition->>'table_name';
        execute 'create table if not exists ' || _table_name || '(row_owner text default current_user)';
        for _i in select * from json_array_elements(_columns) loop
            select sql_type_from_generic_type(_i->>'type') into _dtype;
            select _i->>'name' into _colname;
            begin
                -- can use if not exists when postgres 9.6 is running in tsd
                execute 'alter table ' || _table_name || ' add column ' || _colname || ' ' || _dtype;
            exception
                when duplicate_column then raise notice 'column % already exists', _colname;
            end;
            begin
                select _i->'constraints'->'primary_key' into _pk;
                if _pk is not null then
                    begin
                        execute 'alter table ' || _table_name || ' add primary key ' || '(' || _colname || ')';
                    exception
                        when invalid_table_definition then raise notice 'primary key already exists';
                    end;
                end if;
            end;
            begin
                select _i->'constraints'->'not_null' into _nn;
                if _nn is not null then
                    execute 'alter table ' || _table_name || ' alter column ' || _colname || ' set not null';
                end if;
            end;
        end loop;
        execute 'alter table ' || _table_name || ' owner to authenticator';
        execute 'alter table ' || _table_name || ' enable row level security';
        -- eventually move the select grant up and grant it on all user defined rows only
        execute 'grant insert, select, update, delete on ' || _table_name || ' to public';
        execute 'grant execute on function roles_have_common_group(text, text) to public';
        execute 'create policy row_ownership_insert_policy on ' || _table_name || ' for insert with check (true)';
        execute 'create policy row_ownership_select_policy on ' || _table_name || ' for select using (row_owner = current_user)';
        execute 'create policy row_ownership_delete_policy on ' || _table_name || ' for delete using (row_owner = current_user)';
        execute 'create policy row_ownership_select_group_policy on ' || _table_name || ' for select using (roles_have_common_group(current_user::text, row_owner))';
        execute 'create policy row_owbership_update_policy on ' || _table_name || ' for update using (row_owner = current_user) with check (row_owner = current_user)';
        return 'Success';
    end;
$$ language plpgsql;


drop function if exists parse_generic_table_def(json);
create or replace function parse_generic_table_def(definition json)
    returns text as $$
    declare _table_name text;
    declare _columns json;
    declare _colname text;
    declare _dtype text;
    declare _i json;
    declare _pk boolean;
    declare _nn boolean;
    begin
        _columns := definition->'columns';
        _table_name := definition->>'table_name';
        execute 'create table if not exists ' || _table_name || '()';
        for _i in select * from json_array_elements(_columns) loop
            select sql_type_from_generic_type(_i->>'type') into _dtype;
            select _i->>'name' into _colname;
            begin
                -- can use if not exists when postgres 9.6 is running in tsd
                execute 'alter table ' || _table_name || ' add column ' || _colname || ' ' || _dtype;
            exception
                when duplicate_column then raise notice 'column % already exists', _colname;
            end;
            begin
                select _i->'constraints'->'primary_key' into _pk;
                if _pk is not null then
                    begin
                        execute 'alter table ' || _table_name || ' add primary key ' || '(' || _colname || ')';
                    exception
                        when invalid_table_definition then raise notice 'primary key already exists';
                    end;
                end if;
            end;
            begin
                select _i->'constraints'->'not_null' into _nn;
                if _nn is not null then
                    execute 'alter table ' || _table_name || ' alter column ' || _colname || ' set not null';
                end if;
            end;
        end loop;
        execute 'alter table ' || _table_name || ' owner to import_user';
        return 'Success';
    end;
$$ language plpgsql;

-- do hashing here or in the app?
drop function if exists user_create(text);
create or replace function user_create(_id text)
    returns text as $$
    begin
        execute 'create role ' || _id;
        execute 'grant ' || _id || ' to authenticator';
        execute 'grant select on group_memberships to ' || _id;
        execute 'grant execute on function roles_have_common_group(text, text) to ' || _id;
        return 'created user ' || _id;
    end;
$$ language plpgsql;

drop function if exists group_create(text);
create or replace function group_create(group_name text)
    returns text as $$
    begin
        execute 'create role ' || group_name;
        return 'created group ' || group_name;
    end;
$$ language plpgsql;

-- '{"memberships": [{"user":"role1", "group":"group4"}, {"user":"role2", "group":"group4"}]}'::json
drop function if exists group_add_members(json);
create or replace function group_add_members(members json)
    returns text as $$
    declare _i json;
    declare _user text;
    declare _group text;
    begin
        for _i in select * from json_array_elements(members->'memberships') loop
            select _i->>'user' into _user;
            select _i->>'group' into _group;
            execute 'grant ' || _user || ' to ' || _group;
        end loop;
    return 'added members to groups';
    end;
$$ language plpgsql;

-- '{"memberships": [{"user":"role1", "group":"group4"}]}'::json
drop function if exists group_remove_members(json);
create or replace function group_remove_members(members json)
    returns text as $$
    declare _i json;
    declare _user text;
    declare _group text;
    begin
        for _i in select * from json_array_elements(members->'memberships') loop
            select _i->>'user' into _user;
            select _i->>'group' into _group;
            execute 'revoke ' || _user || ' from ' || _group;
        end loop;
    return 'removed members from groups';
    end;
$$ language plpgsql;

drop function if exists user_delete_data();
create or replace function user_delete_data()
    returns text as $$
    begin
        -- for all tables
            -- delete from table
            -- update autdit table
    end;
$$ language plpgsql;

-- TODO
-- user delete (revoke select on group_memberships, revoke all privileges on <table> from role)
-- group delete (should have no members, then revoke all privileges on <table> from role))

----------------
-- Use the model
----------------

-- need to create the roles before inserting data
-- add a register request /rpc/user_register -> hash(id, salt), create role
create role role1;
grant role1 to authenticator;
grant select on group_memberships to role1;

create role role2;
grant role2 to authenticator;
grant select on group_memberships to role2;

create role role3;
grant role3 to authenticator;
grant select on group_memberships to role2;

set role role1;
insert into t1 (x) values (1);
set role authenticator;

set role role2;
insert into t1 (x) values (2);
set role authenticator;

set role role3;
insert into t1 (x) values (3);
set role authenticator;

-- only owners can operate on their own tables
set role authenticator;
table t1;

set role role1;
table t1;

-- reset
set role authenticator;
set role tsd_backend_utv_user;

-- testing groups
create role group1;
create role group2;

-- use a function
grant role3 to group2;
grant role1 to group1;
grant role2 to group1;

set role authenticator;
set role role1;
table t1;

-- test remaining policies
update t1 set x = 0;
table t1;

delete from t1;
table t1;

-- logout, login as superuser
-- cleanup
drop table t1;
drop view group_memberships;
revoke select on pg_authid from authenticator ;

drop role group1;
drop role group2;

drop role role1;
drop role role2;
drop role role3;

revoke authenticator from tsd_backend_utv_user;
drop role authenticator;

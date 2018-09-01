
set role tsd_backend_utv_user; -- dbowner

create or replace function test_table_create()
    returns boolean as $$
    declare _ans text;
    begin
        set role authenticator;
        set role admin_user;
        select table_create('{"table_name": "people", "columns": [ {"name": "name", "type": "text"}, {"name": "age", "type": "int"} ]}'::json, 'mac') into _ans;
        assert (select count(1) from people) = 0, 'problem with table creation';
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_user_create()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        select user_create('gustav', 'data_owner') into _ans;
        assert (select _user_type from user_types where _user_name = 'gustav') = 'data_owner',
            'problem with user creation';
        select user_create('hannah', 'data_owner') into _ans;
        assert (select _user_type from user_types where _user_name = 'hannah') = 'data_owner',
            'problem with user creation';
        select user_create('faye', 'data_owner') into _ans;
        assert (select _user_type from user_types where _user_name = 'faye') = 'data_owner',
            'problem with user creation';
        select user_create('project_user', 'data_user') into _ans;
        assert (select _user_type from user_types where _user_name = 'project_user') = 'data_user',
            'problem with user creation';
        assert (select count(1) from user_types where _user_name in ('gustav', 'hannah', 'faye', 'project_user')) = 4,
            'not all newly created users are recorded in the user_types table';
        -- test that the rolse actually exist
        set role gustav;
        set role authenticator;
        set role hannah;
        set role authenticator;
        set role faye;
        set role authenticator;
        set role project_user;
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_create()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        select group_create('project_group') into _ans;
        assert (select count(1) from user_defined_groups where group_name = 'project_group') = 1,
            'problem recording user defined group creation in accounting table';
        -- check role exists
        set role authenticator;
        set role tsd_backend_utv_user; -- db owner, get from variable
        set role project_group;
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_defult_data_owner_policies()
    returns boolean as $$
    begin
        set role gustav;
        insert into people (name, age) values ('Gustav de la Croix', 1);
        set role authenticator;
        set role hannah;
        insert into people (name, age) values ('Hannah le Roux', 29);
        set role authenticator;
        set role faye;
        insert into people (name, age) values ('Faye Thompson', 58);
        set role authenticator;
        set role gustav;
        assert (select count(1) from people) = 1, 'gustav has unauthorized data access';
        set role authenticator;
        set role hannah;
        assert (select count(1) from people) = 1, 'hannah has unauthorized data access';
        set role authenticator;
        set role project_user;
        assert (select count(1) from people) = 0, 'project_user has unauthorized data access';
        set role authenticator;
        set role admin_user; -- make sure RLS is forced on table owner too
        assert (select count(1) from people) = 0, 'admin_user has unauthorized data access';
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_add_members()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        select group_add_members('{"memberships": [{"user":"gustav", "group":"project_group"}, {"user":"hannah", "group":"project_group"}, {"user":"project_user", "group":"project_group"}]}'::json) into _ans;
        set role authenticator;
        assert (select count(1) from user_defined_groups where group_name = 'project_group') = 1,
            'group creation accounting is broken';
        assert (select count(member) from user_defined_groups_memberships where group_name = 'project_group') = 3,
            'adding members to groups is broken';
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_membership_data_access_policies()
    returns boolean as $$
    begin
        set role gustav;
        assert (select count(1) from people) = 1, 'data owner, gustav, has unauthorized data access';
        set role authenticator;
        set role hannah;
        assert (select count(1) from people) = 1, 'data owner, hannah, has unauthorized data access';
        set role authenticator;
        set role project_user;
        assert (select count(1) from people) = 2, 'RLS policy for data user, project_user, is broken';
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_list()
    returns boolean as $$
    begin
        set role admin_user;
        assert (select '(project_group)' in (select group_list()::text)), 'group list does not work';
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_list_members()
    returns boolean as $$
    begin
        set role admin_user;
        assert 'gustav' in (select group_list_members('project_group')), 'listing group members does not work';
        assert 'hannah' in (select group_list_members('project_group')), 'listing group members does not work';
        assert 'project_user' in (select group_list_members('project_group')), 'listing group members does not work';
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_remove_members()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        select group_remove_members('{"memberships": [{"user":"gustav", "group":"project_group"}]}'::json) into _ans;
        set role authenticator;
        set role project_user;
        -- now only data owner in the group is hannah
        assert (select count(1) from people) = 1,
            'project_user has unauthorized data access to people, something went wrong then removing gustav from project_group';
        assert (select count(1) from user_defined_groups_memberships where member = 'gustav' and group_name = 'project_group') = 0,
            'gustav is still recorded as being a member of project_group in the accounting view';
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_user_delete_data()
    returns boolean as $$
    declare _ans text;
    begin
        -- create another table to check for deletes across multiple tables
        set role authenticator;
        set role admin_user;
        select table_create('{"table_name": "people2", "columns": [ {"name": "name", "type": "text"}, {"name": "age", "type": "int"} ]}'::json, 'mac') into _ans;
        set role authenticator;
        -- insert some data
        set role gustav;
        insert into people2 (name, age) values ('Gustav de la Croix', 10);
        -- delete the data
        select user_delete_data() into _ans;
        assert (select count(1) from people) = 0, 'data for gustav not deleted from table people';
        assert (select count(1) from people2) = 0, 'data for gustav not deleted from table people2';
        set role authenticator;
        assert (select count(1) from user_data_deletion_requests where user_name = 'gustav') >= 1,
            'problem recording the data deletion request from gustav';
        return true;
    end;
$$ language plpgsql;


create or replace function test_user_delete()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        begin
            select user_delete('hannah') into _ans; -- should fail, because data still present
        exception
            when others then raise notice 'existing data check in order, when deleting a user';
        end;
        set role authenticator;
        -- if the above worked, wrongly so, then the next part will fail
        -- because it will be impossible to set the role to hannah
        set role hannah;
        select user_delete_data() into _ans;
        set role authenticator;
        set role admin_user;
        select user_delete('hannah') into _ans;
        assert (select count(1) from user_types where _user_name = 'hannah') = 0,
            'user deletion did not update user_types accounting table correctly';
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_delete()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
            -- test that fails if has members
            begin
                select group_delete('project_group') into _ans;
            exception
                when others then raise notice 'non-empty group deletion prevention works as expected';
            end;
        set role authenticator;
        -- now remove members
        select user_delete('project_user') into _ans;
        set role admin_user;
        select group_delete('project_group') into _ans;
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function teardown()
    returns boolean as $$
    declare _ans text;
    begin
        -- delete gustav
        set role authenticator;
        set role admin_user;
        select user_delete('gustav') into _ans;
        set role authenticator;
        -- delete faye
        set role faye;
        select user_delete_data() into _ans;
        set role authenticator;
        set role admin_user;
        select user_delete('faye') into _ans;
        set role authenticator;
        -- drop tables
        set role admin_user;
        execute 'drop table people';
        execute 'drop table people2';
        set role authenticator;
        -- clear out accounting table
        set role admin_user;
        execute 'delete from user_data_deletion_requests';
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function run_tests()
    returns boolean as $$
    begin
        assert (select test_table_create()), 'ERROR: test_table_create';
        assert (select test_user_create()), 'ERROR: test_user_create';
        assert (select test_group_create()), 'ERROR: test_group_create';
        assert (select test_defult_data_owner_policies()), 'ERROR: test_defult_data_owner_policies';
        assert (select test_group_add_members()), 'ERROR: test_group_add_members';
        assert (select test_group_membership_data_access_policies()), 'ERROR: test_group_membership_data_access_policies';
        assert (select test_group_list()), 'ERROR: test_group_list';
        assert (select test_group_list_members()), 'ERROR: test_group_list_members';
        assert (select test_group_remove_members()), 'ERROR: test_group_remove_members';
        assert (select test_user_delete_data()), 'ERROR: test_user_delete_data';
        assert (select test_user_delete()), 'ERROR: test_user_delete';
        assert (select test_group_delete()), 'ERROR: test_group_delete';
        assert (select teardown()), 'ERROR: teardown';
        raise notice 'GOOD NEWS: All tests pass :)';
        return true;
    end;
$$ language plpgsql;

\echo
\echo 'DB state before testing'
\d
\du
select run_tests();
-- remove all test functions
set role tsd_backend_utv_user; -- db owner
drop function test_table_create();
drop function test_user_create();
drop function test_group_create();
drop function test_defult_data_owner_policies();
drop function test_group_add_members();
drop function test_group_membership_data_access_policies();
drop function test_group_list();
drop function test_group_list_members();
drop function test_group_remove_members();
drop function test_user_delete_data();
drop function test_user_delete();
drop function test_group_delete();
drop function teardown();
\echo
\echo 'DB state after testing'
\d
\du

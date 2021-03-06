
\set db_owner `echo "$DBOWNER"`

set role :db_owner;

create or replace function test_table_create()
    returns boolean as $$
    declare _ans text;
    begin
        set role authenticator;
        set role admin_user;
        select table_create('{"table_name": "people",
                              "columns": [
                                    {"name": "name",
                                     "type": "text",
                                     "description": "First name"},
                                    {"name": "age",
                                     "type": "int",
                                     "description": "Age in years"} ],
                              "description": "a collection of data on people"}'::json,
                            'mac') into _ans;
        -- this must be idempotent
        -- so API users can add new columns
        -- by simply updating their table definitions
        select table_create('{"table_name": "people",
                              "columns": [
                                    {"name": "name",
                                     "type": "text",
                                     "description": "First name"},
                                    {"name": "age",
                                     "type": "int",
                                     "description": "Age in years"} ],
                              "description": "a collection of data on people"}'::json,
                            'mac') into _ans;
        assert (select count(1) from people) = 0, 'problem with table creation';
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_table_metadata_features()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        assert (select 'a collection of data on people' in (select table_description from table_overview)),
            'table description not set correctly during initial table creation or table_overview does not work';
        assert (select '(name,"First name")' in (select table_metadata('people')::text)),
            'column description not set correctly during initial table creation';
        select table_describe('people', 'a new description') into _ans;
        select table_describe_columns('people', '[{"name":"name","description":"Surname of the person"}]'::json) into _ans;
        assert (select 'a new description' in (select table_description from table_overview)),
            'table description not set correctly using table_describe';
        assert (select '(name,"Surname of the person")' in (select table_metadata('people')::text)),
            'column description not set correctly using table_describe_columns';
        return true;
    end;
$$ language plpgsql;


create or replace function test_user_create()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        select ntk.user_create('gustav', 'owner_gustav', 'data_owner', '{"institution":"A"}'::json) into _ans;
        assert (select _user_type from ntk.registered_users where _user_name = 'owner_gustav') = 'data_owner',
            'problem with user creation';
        select ntk.user_create('hannah', 'owner_hannah', 'data_owner', '{"institution":"A"}'::json) into _ans;
        assert (select _user_type from ntk.registered_users where _user_name = 'owner_hannah') = 'data_owner',
            'problem with user creation';
        select ntk.user_create('faye', 'owner_faye', 'data_owner', '{"institution":"B"}'::json) into _ans;
        assert (select _user_type from ntk.registered_users where _user_name = 'owner_faye') = 'data_owner',
            'problem with user creation';
        set role authenticator;
        set role anon;
        -- make sure the public method also works
        select user_register('project_user', 'data_user', '{"institution":"A"}'::json) into _ans;
        set role authenticator;
        set role admin_user;
        assert (select _user_type from ntk.registered_users where _user_name = 'user_project_user') = 'data_user',
            'problem with user creation';
        assert (select count(1) from ntk.registered_users where _user_name in
                    ('owner_gustav', 'owner_hannah', 'owner_faye', 'user_project_user')) = 4,
            'not all newly created users are recorded in the ntk.registered_users table';
        -- check that the constraints on the public method are correctly enforced
        set role anon;
        begin
            select user_register('1234', 'data_person', '{}'::json) into _ans;
            assert false;
        exception when assert_failure then raise notice
            'user type check works - as expected';
        end;
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_create()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        select group_create('project_group', '{"consent_reference": 1234}'::json) into _ans;
        assert (select count(1) from ntk.user_defined_groups where group_name = 'project_group') = 1,
            'problem recording user defined group creation in accounting table';
        -- check role exists
        set role authenticator;
        set role project_group; -- look up in system catalogues instead (when authenticator is no longer a member of db owner, which it should not be)
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_table_group_access_management()
    returns boolean as $$
    declare _ans text;
    declare _num int;
    begin
        set role admin_user;
        select table_create('{"table_name": "people3",
                              "columns": [
                                    {"name": "name",
                                     "type": "text",
                                     "description": "First name"},
                                    {"name": "age",
                                     "type": "int",
                                     "description": "Age in years"} ],
                              "description": "a collection of data on people number 3"}'::json,
                            'mac') into _ans;
        select group_create('test_group', '{"description": "my test group"}'::json) into _ans;
        set role anon;
        select user_register('1', 'data_owner', '{}'::json) into _ans;
        set role authenticator;
        set role data_owner;
        set session "request.jwt.claim.user" = 'owner_1';
        insert into people3 (name,age) values ('niel', 9);
        -- ensure default group access works for data owners
        assert (select count(1) from people3) = 1,
            'default select does not work for owner_1 on people3 - data_owners_group permission is not working';
        set role authenticator;
        set role anon;
        select user_register('1', 'data_user', '{}'::json) into _ans;
        set role admin_user;
        select group_add_members('test_group',
            '{"memberships": {"data_owners": ["1"], "data_users": ["1"]}}'::json)
                into _ans;
        -- ensure group membership does not work before table access is granted
        set role data_user;
        set session "request.jwt.claim.user" = 'user_1';
        begin
            select count(1) from people3 into _num;
            assert false;
        exception
            when insufficient_privilege then raise notice
                'data users do not have access to tables before group table grant - as expected';
        end;
        set role authenticator;
        set role admin_user;
        set session "request.jwt.claim.user" = '';
        -- ensure select access grant works for data users
        select table_group_access_grant('people3', 'test_group', 'select') into _ans;
        set role data_user;
        set session "request.jwt.claim.user" = 'user_1';
        assert (select count(1) from people3) = 1,
            'group table grant is not working';
        -- ensure granting access on people3 does not propagate to any other tables
        begin
            set role authenticator;
            set role admin_user;
            set session "request.jwt.claim.user" = '';
            select group_create('dummy_group', '{}'::json) into _ans;
            select table_group_access_grant('people3', 'dummy_group', 'select') into _ans;
            select group_add_members('dummy_group',
            '{"memberships": {"data_owners": ["1"], "data_users": ["1"]}}'::json)
                into _ans;
            set role data_user;
            set session "request.jwt.claim.user" = 'user_1';
            select count(1) from people into _num;
            assert false, 'problem with table access grant: they are inherited across tables';
        exception
            when insufficient_privilege then
            raise notice 'table grants do no apply to other tables - as expected';
        end;
        set role authenticator;
        set role admin_user;
        set session "request.jwt.claim.user" = '';
        -- ensure revoking table access works
        select table_group_access_revoke('people3', 'test_group', 'select') into _ans;
        set role data_user;
        set session "request.jwt.claim.user" = 'user_1';
        begin
            select count(1) from people3 into _num;
            assert false;
        exception
            when insufficient_privilege then raise notice
                'revoking table grant works - as expected';
        end;
        -- cleanup state
        set role authenticator;
        set role data_owner;
        set session "request.jwt.claim.user" = 'owner_1';
        select user_delete_data() into _ans;
        set role authenticator;
        set role admin_user;
        select group_remove_members('test_group',
            '{"memberships": {"data_owners": ["1"], "data_users": ["1"]}}'::json) into _ans;
        select user_delete('1', 'data_owner') into _ans;
        select user_delete('1', 'data_user') into _ans;
        select group_delete('test_group') into _ans;
        drop table people3;
        return true;
    end;
$$ language plpgsql;


create or replace function test_default_data_owner_and_user_policies()
    returns boolean as $$
    declare _num int;
    begin
        set role data_owner;
        set session "request.jwt.claim.user" = 'owner_gustav';
        -- first try to insert row_originator explicitly
        -- with a value different from the session variable
        -- this should fail due to the column check constraint
        begin
            insert into people (row_originator, name, age)
            values ('bla', 'Gustav de la Croix', 1);
            assert false;
        exception
            when check_violation then
            raise notice 'row_originator check constraint works - as expected';
        end;
        insert into people (name, age) values ('Gustav de la Croix', 1);
        set session "request.jwt.claim.user" = 'owner_hannah';
        insert into people (name, age) values ('Hannah le Roux', 29);
        set session "request.jwt.claim.user" = 'owner_faye';
        insert into people (name, age) values ('Faye Thompson', 58);
        set session "request.jwt.claim.user" = 'owner_gustav';
        assert (select count(1) from people) = 1, 'owner_gustav has unauthorized data access';
        set session "request.jwt.claim.user" = 'owner_hannah';
        assert (select count(1) from people) = 1, 'owner_hannah has unauthorized data access';
        set session "request.jwt.claim.user" = '';
        set role authenticator;
        set role admin_user; -- make sure RLS is forced on table owner too
        assert (select count(1) from people) = 0, 'admin_user has unauthorized data access';
        set role data_user;
        begin
            select count(1) from people into _num;
            assert false;
        exception
            when insufficient_privilege then raise notice
                'data user does not have access to the table before a group grant has been issued - as expected';
        end;
        begin
            insert into people (name, age) values ('Steve', 90);
            assert false;
        exception
            when insufficient_privilege then raise notice
                'data user cannot insert data - as expected';
        end;
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_add_and_remove_members()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        -- need to use user_id instead of user_names
        select group_add_members('project_group',
            '{"memberships": {"data_owners": ["gustav", "hannah"], "data_users": ["project_user"]}}'::json)
            into _ans;
        assert (select count(user_name) from groups.group_memberships
                where group_name = 'project_group') = 3,
            'adding members to groups individually is broken';
        select group_remove_members('project_group',
            '{"memberships": {"data_owners": ["gustav", "hannah"], "data_users": ["project_user"]}}'::json)
            into _ans;
        select group_add_members('project_group', null, '{"key": "institution", "value": "A"}', null) into _ans;
        assert (select count(user_name) from groups.group_memberships
                where group_name = 'project_group') = 3,
            'adding members to groups using metadata is broken';
        select group_remove_members('project_group', null, '{"key": "institution", "value": "A"}', null) into _ans;
        raise notice 'trying group add all';
        select group_add_members('project_group', null, null, true) into _ans;
        assert (select count(user_name) from groups.group_memberships
                where group_name = 'project_group') = 4,
            'adding members to groups using all = true, is broken';
        select group_remove_members('project_group', null, null, true) into _ans;
        select group_add_members('project_group', null, null, null, true, null) into _ans;
        assert (select count(user_name) from groups.group_memberships
                where group_name = 'project_group') = 3,
            'adding members to groups using add_all_owners = true, is broken';
        select group_remove_members('project_group', null, null, true) into _ans;
        select group_add_members('project_group', null, null, null, null, true) into _ans;
        assert (select count(user_name) from groups.group_memberships
                where group_name = 'project_group') = 1,
            'adding members to groups using add_all_users = true, is broken';
        select group_remove_members('project_group', null, null, true) into _ans;
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_membership_data_access_policies()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        select group_add_members('project_group', '{"memberships":
                {"data_owners": ["gustav", "hannah"], "data_users": ["project_user"]}}'::json) into _ans;
        set role authenticator;
        set role data_owner;
        set session "request.jwt.claim.user" = 'owner_gustav';
        assert (select count(1) from people) = 1,
            'data owner, owner_gustav, has unauthorized data access';
        set role authenticator;
        set role data_owner;
        set session "request.jwt.claim.user" = 'owner_hannah';
        assert (select count(1) from people) = 1,
            'data owner, owner_hannah, has unauthorized data access';
        set role authenticator;
        -- SELECT policy grant
        set role data_user;
        -- make sure the data user cannot select from the table
        -- before the grant has actually been issued
        set session "request.jwt.claim.user" = 'user_project_user';
        begin
            select * from people;
            assert false;
        exception
            when insufficient_privilege
            then raise notice
            'data_user cannot select from table before select grant is issued';
        end;
        set role authenticator;
        set role admin_user;
        -- the two data owners above are in the same group as the data user below
        select table_group_access_grant('people', 'project_group', 'select') into _ans;
        set role data_user;
        set session "request.jwt.claim.user" = 'user_project_user';
        assert (select count(1) from people) = 2,
            'RLS policy for data user, project_user, is broken';
        set role authenticator;
        set role admin_user;
        set session "request.jwt.claim.user" = '';
        select group_remove_members('project_group', '{"memberships":
                {"data_owners": ["gustav", "hannah"], "data_users": ["project_user"]}}'::json) into _ans;
        select table_group_access_revoke('people', 'project_group', 'select') into _ans;
        -- INSERT policy grant
        select group_add_members('project_group', '{"memberships":
                {"data_owners": ["gustav", "hannah"], "data_users": ["project_user"]}}'::json) into _ans;
        select table_group_access_grant('people', 'project_group', 'insert') into _ans;
        set role data_user;
        set session "request.jwt.claim.user" = 'user_project_user';
        insert into people(name, age) values ('Gordon', 40);
        set role admin_user;
        set session "request.jwt.claim.user" = '';
        select table_group_access_revoke('people', 'project_group', 'insert') into _ans;
        begin
            set role data_user;
            set session "request.jwt.claim.user" = 'user_project_user';
            insert into people(name, age) values ('Still Gordon', 41);
            assert false;
        exception
            when insufficient_privilege
            then raise notice
            'revoking insert from data users works - as expected';
        end;
        set role admin_user;
        set session "request.jwt.claim.user" = '';
        -- UPDATE policy grant
        set role data_user;
        set session "request.jwt.claim.user" = 'user_project_user';
        begin
            update people set age = 8
                where row_originator = 'user_project_user';
            assert false;
        exception
            when insufficient_privilege
            then raise notice
            'data user cannot update before grant is issued - as expected';
        end;
        set role admin_user;
        set session "request.jwt.claim.user" = '';
        select table_group_access_grant('people', 'project_group', 'update') into _ans;
        set role data_user;
        set session "request.jwt.claim.user" = 'user_project_user';
        update people set name = 'Otho'
                where row_originator = 'user_project_user';
        begin
            update people set row_owner = 'owner_gustav'
                where row_originator = 'user_project_user';
            assert false;
        exception
            when others
            then raise notice 'cannot alter row_owner - as expected';
        end;
        set role admin_user;
        set session "request.jwt.claim.user" = '';
        -- test removal of only update right if select grant is present
        select table_group_access_grant('people', 'project_group', 'select') into _ans;
        select table_group_access_revoke('people', 'project_group', 'update') into _ans;
        set role data_user;
        set session "request.jwt.claim.user" = 'user_project_user';
        select count(1)::text from people into _ans;
        set role admin_user;
        set session "request.jwt.claim.user" = '';
        select group_remove_members('project_group', '{"memberships":
                {"data_owners": ["gustav", "hannah"], "data_users": ["project_user"]}}'::json) into _ans;
        select table_group_access_revoke('people', 'project_group', 'select') into _ans;
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_list()
    returns boolean as $$
    begin
        set role admin_user;
        assert (select count(1) from groups where group_name = 'project_group') = 1,
            'group list does not work';
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_list_members()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        -- use user_id instead of names
        select group_add_members('project_group',
            '{"memberships": {"data_owners": ["gustav", "hannah"], "data_users": ["project_user"]}}'::json) into _ans;
        assert 'gustav' in (select group_list_members('project_group')),
            'listing group members does not work';
        assert 'hannah' in (select group_list_members('project_group')),
            'listing group members does not work';
        assert 'project_user' in (select group_list_members('project_group')),
            'listing group members does not work';
        select group_remove_members('project_group',
            '{"memberships": {"data_owners": ["gustav", "hannah"], "data_users": ["project_user"]}}'::json) into _ans;
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_user_groups()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        select group_add_members('project_group', '{"memberships": {"data_owners": ["gustav"]}}'::json) into _ans;
        assert '(project_group,"{""consent_reference"": 1234}")' in (select user_groups('gustav', 'data_owner')::text),
            'user_groups function does not list all groups';
        begin
            select user_groups('authenticator', 'data_owner') into _ans;
            assert false;
        exception
            when assert_failure then raise notice
                'cannot access internal role groups - as expected';
        end;
        set role authenticator;
        set role data_owner;
        set session "request.jwt.claim.user" = 'owner_gustav';
        assert '(project_group,"{""consent_reference"": 1234}")' in (select user_groups()::text),
            'user_groups function does not list all groups';
        set session "request.jwt.claim.user" = '';
        set role authenticator;
        set role admin_user;
        select group_remove_members('project_group', '{"memberships": {"data_owners": ["gustav"]}}'::json) into _ans;
        return true;
    end;
$$ language plpgsql;


create or replace function test_user_list()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        assert (select count(1) from user_registrations
                where user_name = 'owner_gustav') = 1,
            'registered_users accounting view does not work';
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_user_group_remove()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        select group_add_members('project_group',
            '{"memberships": ["faye"]}'::json, null, null) into _ans;
        set role authenticator;
        set role data_owner;
        set session "request.jwt.claim.user" = 'owner_faye';
        select user_group_remove('project_group') into _ans;
        set session "request.jwt.claim.user" = '';
        set role authenticator;
        set role admin_user;
        assert 'project_group' in (select group_name from ntk.user_initiated_group_removals
                where user_name = 'owner_faye'),
            'group removal accounting does not work';
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_remove_members()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        select group_remove_members('project_group', '{"memberships":
            ["owner_gustav"]}'::json, null, null) into _ans;
        set role authenticator;
        set role project_user;
        -- now only data owner in the group is owner_hannah
        assert (select count(1) from people) = 1,
            'project_user has unauthorized data access to people, something went wrong then removing owner_gustav from project_group';
        assert (select count(1) from ntk.user_defined_groups_memberships
                where member = 'owner_gustav' and group_name = 'project_group') = 0,
            'owner_gustav is still recorded as being a member of project_group in the accounting view';
        set role authenticator;
        set role admin_user;
        grant project_group to owner_gustav;
        -- now members are: owner_gustav, owner_hannah, and project_user
        -- all of them have metadata attr: institution: A
        select group_remove_members('project_group', null, '{"key": "institution", "value": "A"}', null) into _ans;
        assert (select count(member) from ntk.user_defined_groups_memberships
                where group_name = 'project_group') = 0,
            'removing group members using metadata values does not work';
        grant project_group to owner_hannah;
        grant project_group to project_user;
        -- now remove all
        select group_remove_members('project_group', null, null, true) into _ans;
        assert (select count(member) from ntk.user_defined_groups_memberships
                where group_name = 'project_group') = 0,
            'removing group members using metadata values does not work';
        grant project_group to owner_hannah;
        grant project_group to project_user;
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
        -- issue group access grant
        set role authenticator;
        -- insert some data
        set role data_owner;
        set session "request.jwt.claim.user" = 'owner_gustav';
        insert into people2 (name, age) values ('owner_Gustav de la Croix', 10);
        -- delete the data
        select user_delete_data() into _ans;
        assert (select count(1) from people) = 0,
            'data for owner_gustav not deleted from table people';
        assert (select count(1) from people2) = 0,
            'data for owner_gustav not deleted from table people2';
        set role authenticator;
        set role admin_user;
        assert (select count(1) from event_log_user_data_deletions where user_name = 'owner_gustav') >= 1,
            'problem recording the data deletion request from owner_gustav';
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_user_delete()
    returns boolean as $$
    declare _ans text;
    begin
        set role admin_user;
        begin
            select user_delete('hannah', 'data_owner') into _ans; -- should fail, because data still present
            assert false;
        exception
            when others then raise notice 'existing data check in order, when deleting a user';
        end;
        set role authenticator;
        -- if the above worked, wrongly so, then the next part will fail
        -- because it will be impossible to set the role to owner_hannah
        set role data_owner;
        set session "request.jwt.claim.user" = 'owner_hannah';
        select user_delete_data() into _ans;
        set role authenticator;
        set role admin_user;
        select user_delete('hannah', 'data_owner') into _ans;
        assert (select count(1) from ntk.registered_users where _user_name = 'owner_hannah') = 0,
            'user deletion did not update ntk.registered_users accounting table correctly';
        assert (select count(1) from ntk.data_owners where user_name = 'owner_hannah') = 0,
            'user deletion did not update ntk.data_owners accounting table correctly';
        begin
            select user_delete('authenticator', 'data_owner') into _ans;
            assert false;
        exception
            when assert_failure then raise notice
                'cannot delete internal role via user_delete - as expected.';
        end;
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_group_delete()
    returns boolean as $$
    declare _ans text;
    begin

        set role admin_user;
        select group_add_members('project_group', '{"memberships":
                {"data_owners": ["gustav"], "data_users": ["project_user"]}}'::json) into _ans;
        select table_group_access_grant('people', 'project_group', 'select') into _ans;
        begin
            select group_delete('project_group') into _ans;
            assert false;
        exception
            when others then raise notice
                'non-empty group deletion prevention works - as expected';
        end;
        select group_remove_members('project_group', '{"memberships":
                {"data_owners": ["gustav"], "data_users": ["project_user"]}}'::json) into _ans;
        begin
            select group_delete('project_group') into _ans;
            assert false;
        exception
            when others then raise notice
                'cannot delete a group if it still has select grant on a table - as expected';
        end;
        begin
            -- possible attack vector, since groups are just roles
            select group_delete('authenticator') into _ans;
            assert false;
        exception
            when assert_failure then raise notice
                'cannot delete internal role via group_delete - as expected.';
        end;
        select table_group_access_revoke('people', 'project_group', 'select') into _ans;
        select group_delete('project_group') into _ans;
        set role authenticator;
        return true;
    end;
$$ language plpgsql;


create or replace function test_event_log_data_access()
    returns boolean as $$
    begin
        set role admin_user;
        assert (select count(1) from event_log_data_access
                where data_owner in ('owner_1', 'owner_gustav', 'owner_hannah')) >= 3,
            'audit logging not working';
        set role authenticator;
        set role data_owner;
        set session "request.jwt.claim.user" = 'owner_gustav';
        assert 'owner_hannah' not in (select data_owner from event_log_data_access),
            'owner_gustav has access to audit logs belonging to owner_hannah';
        set session "request.jwt.claim.user" = '';
        set role admin_user;
        begin
            delete from event_log_data_access;
            assert false;
        exception
            when insufficient_privilege then raise notice
                'admin_user cannot delete event_log_data_access - as expected';
        end;
        return true;
    end;
$$ language plpgsql;


create or replace function test_event_log_access_control()
    returns boolean as $$
    declare i text;
    begin
        -- use the group used in test_table_group_access_management
        -- this goes through the whole life-cycle in a simple way
        set role admin_user;
        for i in select unnest(array['group_create', --'group_delete',
                        'group_member_add', 'group_member_remove',
                        'table_grant_add_select', 'table_grant_add_insert',
                        'table_grant_revoke_select', 'table_grant_revoke_insert',
                        'table_grant_add_update', 'table_grant_revoke_update'])
            loop
            assert i in (select event_type from event_log_access_control
                         where group_name = 'project_group'),
                'event not found in test_event_log_access_control';
        end loop;
        return true;
    end;
$$ language plpgsql;


create or replace function test_event_log_data_updates()
    returns boolean as $$
    begin
        assert (select column_name from event_log_data_updates
                where updated_by = 'user_project_user' limit 1)
            = 'name';
        assert (select old_data from event_log_data_updates
                where updated_by = 'user_project_user' limit 1)
            = 'Gordon';
        assert (select new_data from event_log_data_updates
                where updated_by = 'user_project_user' limit 1)
            = 'Otho';
        return true;
    end;
$$ language plpgsql;


create or replace function test_function_privileges()
    returns boolean as $$
    declare _ans text;
    declare i text;
    begin
        -- ensure unauthenticated requests cannot use sql api
        set role anon;
        begin
            select table_create('{}'::json, 'mac') into _ans;
            return false;
        exception
            when others then raise notice
            'table_create only callable by admin_user - as expected';
        end;
        begin
            select ntk.user_create('', '') into _ans;
            return false;
        exception
            when others then raise notice
            'ntk.user_create only callable by admin_user - as expected';
        end;
        begin
            select group_create('') into _ans;
            return false;
        exception
            when others then raise notice
            'group_create only callable by admin_user - as expected';
        end;
        begin
            select group_add_members(''::json) into _ans;
            return false;
        exception
            when others then raise notice
            'group_add_members only callable by admin_user - as expected';
        end;
        begin
            select group_list_members('') into _ans;
            return false;
        exception
            when others then raise notice
            'group_list_members only callable by admin_user - as expected';
        end;
        begin
            select user_groups('', '') into _ans;
            return false;
        exception
            when others then raise notice
            'user_groups only callable by admin_user - as expected';
        end;
        begin
            select user_group_remove() into _ans;
            return false;
        exception
            when others then raise notice
            'user_list only callable by admin_user - as expected';
        end;
        begin
            select group_remove_members(''::json) into _ans;
            return false;
        exception
            when others then raise notice
            'group_remove_members only callable by admin_user - as expected';
        end;
        begin
            select user_delete('', '') into _ans;
            return false;
        exception
            when others then raise notice
            'user_delete only callable by admin_user - as expected';
        end;
        begin
            select group_delete('') into _ans;
            return false;
        exception
            when others then raise notice
            'group_delete only callable by admin_user - as expected';
        end;
        set role authenticator;
        for i in select unnest(array['table_overview', 'user_registrations', 'groups',
                  'event_log_user_group_removals', 'event_log_user_data_deletions',
                  'event_log_data_access', 'event_log_access_control',
                  'event_log_data_updates']) loop
            begin
                execute format('select * from %I', i);
            exception
                when insufficient_privilege then raise notice
                    'anon user cannot select from %  - as expected', i;
            end;
        end loop;
        return true;
    end;
$$ language plpgsql;


create or replace function teardown()
    returns boolean as $$
    declare _ans text;
    begin
        set session "request.jwt.claim.user" = 'owner_gustav';
        set role admin_user;
        select user_delete('gustav', 'data_owner') into _ans;
        set role authenticator;
        set role data_owner;
        set session "request.jwt.claim.user" = 'owner_faye';
        select user_delete_data() into _ans;
        set role authenticator;
        set role admin_user;
        -- drop tables
        execute 'drop table people cascade';
        execute 'drop table people2 cascade';
        select user_delete('faye', 'data_owner') into _ans;
        select user_delete('project_user', 'data_user') into _ans;
        -- clear out accounting table
        set role admin_user;
        execute 'delete from event_log_user_data_deletions';
        execute 'delete from ntk.user_initiated_group_removals';
        return true;
    end;
$$ language plpgsql;


create or replace function run_tests()
    returns boolean as $$
    begin
        -- tables, groups, and users are re-used across tests
        assert (select test_table_create()), 'ERROR: test_table_create';
        assert (select test_table_metadata_features()), 'ERROR: test_table_metadata_features';
        assert (select test_user_create()), 'ERROR: test_ntk.user_create';
        assert (select test_group_create()), 'ERROR: test_group_create';
        assert (select test_default_data_owner_and_user_policies()), 'ERROR: test_default_data_owner_and_user_policies';
        assert (select test_group_add_and_remove_members()), 'ERROR: test_group_add_and_remove_members';
        assert (select test_user_group_remove()), 'ERROR: test_user_group_remove';
        assert (select test_group_list()), 'ERROR: test_group_list';
        assert (select test_group_list_members()), 'ERROR: test_group_list_members';
        assert (select test_user_groups()), 'ERROR: test_user_groups';
        assert (select test_user_list()), 'ERROR: test_user_list';
        assert (select test_table_group_access_management()), 'ERROR: test_table_group_access_management';
        assert (select test_group_membership_data_access_policies()), 'ERROR: test_group_membership_data_access_policies';
        assert (select test_user_delete_data()), 'ERROR: test_user_delete_data';
        assert (select test_user_delete()), 'ERROR: test_user_delete';
        assert (select test_group_delete()), 'ERROR: test_group_delete';
        assert (select test_function_privileges()), 'ERROR: test_function_privileges';
        assert (select test_event_log_data_access()), 'ERROR: test_event_log_data_access';
        assert (select test_event_log_access_control()), 'ERROR: test_event_log_access_control';
        assert (select test_event_log_data_updates()), 'ERROR: test_event_log_data_updates';
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

set role :db_owner;
--delete from event_log_data_access where data_owner in ('owner_1', 'owner_gustav', 'owner_hannah');
drop function test_table_create();
drop function test_table_metadata_features();
drop function test_user_create();
drop function test_group_create();
drop function test_table_group_access_management();
drop function test_default_data_owner_and_user_policies();
drop function test_group_add_and_remove_members();
drop function test_group_membership_data_access_policies();
drop function test_group_list();
drop function test_group_list_members();
drop function test_user_groups();
drop function test_user_list();
drop function test_group_remove_members();
drop function test_user_delete_data();
drop function test_user_delete();
drop function test_group_delete();
drop function test_function_privileges();
drop function test_event_log_data_access();
drop function test_event_log_access_control();
drop function test_event_log_data_updates();
drop function teardown();

\echo
\echo 'DB state after testing'
\d
\du

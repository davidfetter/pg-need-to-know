
## Function overview

```sql
table_create(definition json, type text)
user_create(user_name text)
group_create(group_name text)
group_add_members(members json)
group_list()
group_list_members(user_name text)
user_list()
group_remove_members(members json)
group_delete(group_name text)
user_groups(user_name text)
user_delete_data()
user_delete(user_name text)
```

For details of usage see `testing.sql`.
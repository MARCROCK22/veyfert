module cache

import time
import veyfert.discord

fn test_both_adapters_pass_the_conformance_suite() ! {
	mut memory := &MemoryAdapter{}
	check_adapter(mut memory)!
	mut limited := new_limited_adapter({})
	check_adapter(mut limited)!
}

fn sorted(keys []string) []string {
	mut out := keys.clone()
	out.sort()
	return out
}

fn test_the_limited_adapter_drops_the_oldest_written_keys() {
	mut a := new_limited_adapter({
		'member': Limit{
			max: 2
		}
	})
	a.set('member:1:1', 'a')
	a.set('member:1:2', 'b')
	a.set('member:1:3', 'c') // past the limit: member 1 goes
	assert sorted(a.scan('member:')) == ['member:1:2', 'member:1:3']
	a.set('member:1:2', 'b2') // written again, so it is now the newest
	a.set('member:1:4', 'd') // member 3 is the oldest written now
	assert sorted(a.scan('member:')) == ['member:1:2', 'member:1:4']
	assert (a.get('member:1:2') or { '' }) == 'b2'
	// Other resources have no limit.
	for i in 0 .. 10 {
		a.set('user:${i}', '{}')
	}
	assert a.scan('user:').len == 10
	// Rewriting keys under the limit many times keeps the queue small.
	for _ in 0 .. 1000 {
		a.set('member:1:2', 'again')
	}
	assert (a.order['member'] or { [] }).len < 100
}

fn test_the_limited_adapter_expires_keys() {
	mut a := &LimitedMemoryAdapter{
		limits:        {
			'presence': Limit{
				expire: 30 * time.millisecond
			}
		}
		default_limit: Limit{
			max: 100
		}
	}
	a.set('presence:1:7', 'online')
	a.set('guild:1', '{}')
	assert (a.get('presence:1:7') or { '' }) == 'online'
	time.sleep(60 * time.millisecond)
	assert a.get('presence:1:7') == none
	assert a.scan('presence:').len == 0
	assert (a.get('guild:1') or { '' }) == '{}' // the default limit has no expiry
}

const guild_json = '{"id":"30","name":"Shared","owner_id":"1","roles":[{"id":"50","name":"mod","permissions":"8"}],"channels":[{"id":"40","type":0,"name":"general"}],"members":[{"user":{"id":"7","username":"ana"},"roles":["50"]}]}'

fn test_caches_that_share_an_adapter_read_each_others_resources() {
	mut store := &MemoryAdapter{}
	mut first := new(adapter: store)
	mut second := new(adapter: store)
	first.apply('RAW_GUILD_CREATE', guild_json)
	first.store_ban(discord.Snowflake{30}, discord.Snowflake{9}, true)
	assert sorted(store.scan('')) == ['ban:30:9', 'channel:40', 'guild:30', 'member:30:7', 'role:30:50',
		'user:7']

	// The second cache never saw the guild; its memory is empty, so it reads the adapter.
	assert (second.guild(discord.Snowflake{30}) or { discord.Guild{} }).name == 'Shared'
	assert (second.user(discord.Snowflake{7}) or { discord.User{} }).username == 'ana'
	member := second.member(discord.Snowflake{30}, discord.Snowflake{7}) or { discord.Member{} }
	assert member.roles == [discord.Snowflake{50}]
	assert second.members(discord.Snowflake{30}).len == 1
	assert second.roles(discord.Snowflake{30}).map(it.name) == ['mod']
	assert second.channels(discord.Snowflake{30}).map(it.id) == [discord.Snowflake{40}]
	assert (second.channel(discord.Snowflake{40}) or { discord.Channel{} }).name or { '' } == 'general'

	// What the first one forgets, the second one stops finding.
	first.apply('GUILD_MEMBER_REMOVE', '{"guild_id":"30","user":{"id":"7","username":"ana"}}')
	assert second.member(discord.Snowflake{30}, discord.Snowflake{7}) == none
	first.apply('GUILD_DELETE', '{"id":"30"}')
	assert second.guild(discord.Snowflake{30}) == none
	assert sorted(store.scan('')) == ['user:7']
}

fn test_a_cache_without_an_adapter_keeps_working_as_before() {
	mut c := new()
	c.apply('RAW_GUILD_CREATE', guild_json)
	assert c.members(discord.Snowflake{30}).len == 1
	assert c.member(discord.Snowflake{30}, discord.Snowflake{8}) == none
	assert c.members(discord.Snowflake{31}).len == 0
}
